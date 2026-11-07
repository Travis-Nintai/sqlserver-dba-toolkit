/* ============================================================================
   agent_job_health.sql -- SQL Server Agent job health check

   Purpose:
     Report the health of SQL Server Agent jobs from msdb: jobs that failed
     recently, jobs with no successful run in the threshold window, jobs
     running right now and jobs running longer than expected, jobs with no
     schedule, disabled jobs, jobs whose owner login no longer resolves,
     and jobs with no failure notification configured.

     Why job health and not just job history: a job can be enabled, have a
     schedule, and still never succeed, or fail quietly for weeks because
     nobody reads its history. This script surfaces the jobs that need a
     DBA's attention, with the last outcome and the message that explains
     it, so the follow-up starts from the failing step instead of from
     a vague "the job did not run".

   Usage (sqlcmd):
     sqlcmd -S <server> -E -i agent_job_health.sql

   Thresholds (DECLARE variables below):
     @FailedJobHours     Look back this far for failed jobs. Default 24.
     @NoSuccessDays      Flag enabled jobs with no successful run in this
                         many days (includes jobs that never succeeded).
                         Default 7.
     @LongRunningMinutes Flag a currently running job that has been
                         running longer than this. Default 60.

   Compatibility:
     SQL Server 2016 or later. Reviewed against the documented msdb
     schema (sysjobs, sysjobhistory, sysjobactivity, sysjobschedules,
     sysjobsteps, sysoperators, syscategories) and sys.dm_server_services.
     Not executed against a live SQL Server instance during development;
     see the README testing status.

   Requires:
     Read access to the msdb job tables (SQLAgentReaderRole or sysadmin)
     and VIEW SERVER STATE for the Agent service status section. The
     service status section is guarded: if the login cannot read
     sys.dm_server_services, that section reports the gap and the rest
     of the script still runs.

   Notes:
     - Job history is only as deep as Agent retention allows. By default
       Agent keeps 1,000 total history rows and 100 per job; a job that
       fails every hour can push older history out. If a job shows
       "NO HISTORY ON RECORD", check the retention settings before
       concluding it never ran.
     - On RDS SQL Server, Agent runs but only T-SQL job steps are
       supported and operators, alerts, and Database Mail notifications
       do not run, so the notification section is expected to be empty
       there. See docs/aws-hosted-sql-server.md.
     - run_status values: 0 failed, 1 succeeded, 2 retry, 3 canceled,
       4 in progress. The outcome row for a job run is step_id 0.

   Safety:
     Read-only.
   ============================================================================ */

SET NOCOUNT ON;

DECLARE @FailedJobHours     int = 24;
DECLARE @NoSuccessDays      int = 7;
DECLARE @LongRunningMinutes int = 60;
DECLARE @Now datetime = GETDATE();

PRINT '================================================================';
PRINT ' SQL Server Agent job health';
PRINT ' Server        : ' + @@SERVERNAME;
PRINT ' Failed jobs   : last ' + CAST(@FailedJobHours AS nvarchar(10))
      + ' hours';
PRINT ' No success    : enabled jobs with no successful run in '
      + CAST(@NoSuccessDays AS nvarchar(10)) + ' days';
PRINT ' Long running  : currently running jobs over '
      + CAST(@LongRunningMinutes AS nvarchar(10)) + ' minutes';
PRINT '================================================================';
PRINT '';

/* ----------------------------------------------------------------------
   1. Agent service status and job counts
   ---------------------------------------------------------------------- */
PRINT '-- Agent service and job counts ----------------------------------';

BEGIN TRY
    SELECT  service_name,
            status_desc AS service_status,
            startup_type_desc AS startup_type
    FROM sys.dm_server_services
    WHERE service_name LIKE 'SQL Server Agent%';

    IF @@ROWCOUNT = 0
        PRINT 'No SQL Server Agent service row visible from this login.';
END TRY
BEGIN CATCH
    PRINT 'Agent service status not readable from this login ('
          + ERROR_MESSAGE() + '). The job sections below still run.';
END CATCH;

SELECT  COUNT(*) AS total_jobs,
        SUM(CASE WHEN enabled = 1 THEN 1 ELSE 0 END) AS enabled_jobs,
        SUM(CASE WHEN enabled = 0 THEN 1 ELSE 0 END) AS disabled_jobs
FROM msdb.dbo.sysjobs;

PRINT '';
PRINT 'Counts cover every job in msdb. Disabled jobs are listed in';
PRINT 'section 6; they are not judged as failures.';

/* ----------------------------------------------------------------------
   2. Jobs that failed in the look-back window
   ---------------------------------------------------------------------- */
PRINT '';
PRINT '-- Jobs failed in the last ' + CAST(@FailedJobHours AS nvarchar(10))
      + ' hours ------------------------------------------------';

;WITH latest_outcome AS
(
    SELECT  h.job_id,
            h.run_status,
            msdb.dbo.agent_datetime(h.run_date, h.run_time) AS run_time,
            (h.run_duration / 10000) * 3600
              + ((h.run_duration / 100) % 100) * 60
              + (h.run_duration % 100) AS run_duration_seconds,
            h.message,
            ROW_NUMBER() OVER (PARTITION BY h.job_id
                               ORDER BY h.instance_id DESC) AS rn
    FROM msdb.dbo.sysjobhistory AS h
    WHERE h.step_id = 0
)
SELECT  j.name AS job_name,
        c.name AS category,
        lo.run_time AS last_run,
        lo.run_duration_seconds / 60.0 AS last_run_minutes,
        LEFT(lo.message, 200) AS last_message
FROM latest_outcome AS lo
JOIN msdb.dbo.sysjobs AS j
  ON j.job_id = lo.job_id
LEFT JOIN msdb.dbo.syscategories AS c
  ON c.category_id = j.category_id
WHERE lo.rn = 1
  AND lo.run_status = 0
  AND lo.run_time >= DATEADD(HOUR, -@FailedJobHours, @Now)
ORDER BY lo.run_time DESC;

PRINT '';
PRINT 'Outcome is the job-level history row (step_id 0). Open the job';
PRINT 'history for the failed step to see which step failed and why.';

/* ----------------------------------------------------------------------
   3. Enabled jobs with no successful run in the window
   ---------------------------------------------------------------------- */
PRINT '';
PRINT '-- Enabled jobs with no successful run in '
      + CAST(@NoSuccessDays AS nvarchar(10)) + ' days -------------------';

;WITH last_success AS
(
    SELECT  h.job_id,
            MAX(msdb.dbo.agent_datetime(h.run_date, h.run_time)) AS last_success
    FROM msdb.dbo.sysjobhistory AS h
    WHERE h.step_id = 0
      AND h.run_status = 1
    GROUP BY h.job_id
),
last_outcome AS
(
    SELECT  h.job_id,
            h.run_status,
            msdb.dbo.agent_datetime(h.run_date, h.run_time) AS run_time,
            ROW_NUMBER() OVER (PARTITION BY h.job_id
                               ORDER BY h.instance_id DESC) AS rn
    FROM msdb.dbo.sysjobhistory AS h
    WHERE h.step_id = 0
)
SELECT  j.name AS job_name,
        c.name AS category,
        ls.last_success,
        CASE WHEN ls.last_success IS NULL THEN NULL
             ELSE DATEDIFF(DAY, ls.last_success, @Now) END
            AS days_since_success,
        CASE lo.run_status
            WHEN 0 THEN 'FAILED'
            WHEN 1 THEN 'SUCCEEDED'
            WHEN 2 THEN 'RETRY'
            WHEN 3 THEN 'CANCELED'
            WHEN 4 THEN 'IN PROGRESS'
            ELSE 'NO HISTORY ON RECORD'
        END AS last_outcome,
        lo.run_time AS last_run
FROM msdb.dbo.sysjobs AS j
LEFT JOIN last_success AS ls
  ON ls.job_id = j.job_id
LEFT JOIN last_outcome AS lo
  ON lo.job_id = j.job_id
 AND lo.rn = 1
LEFT JOIN msdb.dbo.syscategories AS c
  ON c.category_id = j.category_id
WHERE j.enabled = 1
  AND (ls.last_success IS NULL
       OR ls.last_success < DATEADD(DAY, -@NoSuccessDays, @Now))
ORDER BY ls.last_success ASC;

PRINT '';
PRINT 'A job that never succeeded shows NULL for last success. A job with';
PRINT 'NO HISTORY ON RECORD may have had its history aged out by Agent';
PRINT 'retention; check the retention settings before concluding it';
PRINT 'never ran.';

/* ----------------------------------------------------------------------
   4. Currently running jobs
   ---------------------------------------------------------------------- */
PRINT '';
PRINT '-- Currently running jobs ----------------------------------------';

SELECT  j.name AS job_name,
        c.name AS category,
        ja.start_execution_date AS started,
        DATEDIFF(MINUTE, ja.start_execution_date, @Now) AS running_minutes,
        CASE WHEN DATEDIFF(MINUTE, ja.start_execution_date, @Now)
                  > @LongRunningMinutes
             THEN 'LONG RUNNING'
             ELSE 'RUNNING'
        END AS status
FROM msdb.dbo.sysjobactivity AS ja
JOIN msdb.dbo.sysjobs AS j
  ON j.job_id = ja.job_id
LEFT JOIN msdb.dbo.syscategories AS c
  ON c.category_id = j.category_id
WHERE ja.session_id = (SELECT MAX(session_id)
                       FROM msdb.dbo.syssessions)
  AND ja.start_execution_date IS NOT NULL
  AND ja.stop_execution_date IS NULL
ORDER BY ja.start_execution_date ASC;

PRINT '';
PRINT 'A job that runs past its usual duration is worth a look, but';
PRINT 'long is not the same as stuck. Compare against the job history';
PRINT 'for the same job before stopping it.';

/* ----------------------------------------------------------------------
   5. Enabled jobs with no schedule
   ---------------------------------------------------------------------- */
PRINT '';
PRINT '-- Enabled jobs with no schedule ---------------------------------';

SELECT  j.name AS job_name,
        c.name AS category,
        SUSER_SNAME(j.owner_sid) AS owner_login,
        j.description
FROM msdb.dbo.sysjobs AS j
LEFT JOIN msdb.dbo.syscategories AS c
  ON c.category_id = j.category_id
WHERE j.enabled = 1
  AND NOT EXISTS (SELECT 1
                  FROM msdb.dbo.sysjobschedules AS js
                  WHERE js.job_id = j.job_id)
ORDER BY j.name;

PRINT '';
PRINT 'A scheduled job with no schedule only runs when started manually.';
PRINT 'That is fine for an on-demand job; it is a gap for a job that was';
PRINT 'meant to run on a schedule.';

/* ----------------------------------------------------------------------
   6. Disabled jobs
   ---------------------------------------------------------------------- */
PRINT '';
PRINT '-- Disabled jobs ---------------------------------------------------';

SELECT  j.name AS job_name,
        c.name AS category,
        SUSER_SNAME(j.owner_sid) AS owner_login
FROM msdb.dbo.sysjobs AS j
LEFT JOIN msdb.dbo.syscategories AS c
  ON c.category_id = j.category_id
WHERE j.enabled = 0
ORDER BY j.name;

PRINT '';
PRINT 'Disabled is a state, not a failure. A job disabled during an';
PRINT 'incident and never re-enabled is the usual thing to look for here.';

/* ----------------------------------------------------------------------
   7. Jobs whose owner login no longer resolves
   ---------------------------------------------------------------------- */
PRINT '';
PRINT '-- Jobs with an unresolvable owner login -------------------------';

SELECT  j.name AS job_name,
        c.name AS category,
        j.owner_sid AS owner_sid
FROM msdb.dbo.sysjobs AS j
LEFT JOIN msdb.dbo.syscategories AS c
  ON c.category_id = j.category_id
WHERE SUSER_SNAME(j.owner_sid) IS NULL
ORDER BY j.name;

PRINT '';
PRINT 'A job owned by a login that no longer exists can still run, but';
PRINT 'its execution context is no longer what the owner intended. Point';
PRINT 'these jobs at a service account or a current DBA login.';

/* ----------------------------------------------------------------------
   8. Enabled jobs with no failure notification
   ---------------------------------------------------------------------- */
PRINT '';
PRINT '-- Enabled jobs with no failure notification ---------------------';

SELECT  j.name AS job_name,
        c.name AS category,
        j.notify_level_email AS notify_on_email,
        j.notify_level_page AS notify_on_page,
        j.notify_level_eventlog AS notify_on_eventlog,
        o.name AS notify_operator
FROM msdb.dbo.sysjobs AS j
LEFT JOIN msdb.dbo.syscategories AS c
  ON c.category_id = j.category_id
LEFT JOIN msdb.dbo.sysoperators AS o
  ON o.id = j.notify_email_operator_id
WHERE j.enabled = 1
  AND j.notify_level_email = 0
  AND j.notify_level_page = 0
ORDER BY j.name;

PRINT '';
PRINT 'notify_on_email 2 means notify on failure; 3 means notify on';
PRINT 'success or failure. A job with no notification fails quietly,';
PRINT 'which is how a backup job can be broken for a week before anyone';
PRINT 'notices. On RDS SQL Server this section is expected to be empty,';
PRINT 'because operators and Database Mail notifications do not run there.';
