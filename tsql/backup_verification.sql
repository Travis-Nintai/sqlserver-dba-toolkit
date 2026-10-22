/* ============================================================================
   backup_verification.sql -- backup currency check from msdb history

   Purpose:
     For every database, show the last successful full, differential, and
     log backup from msdb backup history, how old each one is, and whether
     it is older than the thresholds at the top of this script.

     Why history and not job status: a backup job can report success while
     an individual database was skipped, in a state that prevented backup,
     or written to a device that later failed. msdb.dbo.backupset records
     what actually completed. Verify what completed.

   Usage (sqlcmd):
     sqlcmd -S <server> -E -i backup_verification.sql

   Thresholds (DECLARE variables below):
     @MaxFullHours   Flag when the last full backup is older. Default 24.
     @MaxDiffHours   Flag when the last differential is older. Default 48.
     @MaxLogHours    Flag when the last log backup is older. Default 1.
                     Only judged for databases in FULL or BULK_LOGGED
                     recovery; SIMPLE recovery databases show N/A.

   Compatibility:
     SQL Server 2016 or later. Reviewed against the documented msdb schema.
     Not executed against a live SQL Server instance during development;
     see the README testing status.

   Requires:
     Read access to msdb.dbo.backupset and sys.databases.

   Safety:
     Read-only.
   ============================================================================ */

SET NOCOUNT ON;

DECLARE @MaxFullHours int = 24;
DECLARE @MaxDiffHours int = 48;
DECLARE @MaxLogHours  int = 1;
DECLARE @Now datetime = GETDATE();

PRINT '================================================================';
PRINT ' Backup verification (from msdb.dbo.backupset)';
PRINT ' Server        : ' + @@SERVERNAME;
PRINT ' Full > ' + CAST(@MaxFullHours AS nvarchar(10)) + 'h, Diff > '
      + CAST(@MaxDiffHours AS nvarchar(10)) + 'h, Log > '
      + CAST(@MaxLogHours AS nvarchar(10)) + 'h are flagged';
PRINT '================================================================';

;WITH last_backups AS
(
    SELECT  bs.database_name,
            MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END) AS last_full,
            MAX(CASE WHEN bs.type = 'I' THEN bs.backup_finish_date END) AS last_diff,
            MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END) AS last_log
    FROM msdb.dbo.backupset AS bs
    GROUP BY bs.database_name
)
SELECT  d.name                                       AS database_name,
        d.recovery_model_desc                        AS recovery_model,
        lb.last_full,
        DATEDIFF(HOUR, lb.last_full, @Now)           AS full_age_hours,
        lb.last_diff,
        DATEDIFF(HOUR, lb.last_diff, @Now)           AS diff_age_hours,
        lb.last_log,
        CASE WHEN d.recovery_model_desc = 'SIMPLE'
             THEN NULL
             ELSE DATEDIFF(MINUTE, lb.last_log, @Now) / 60.0
        END                                          AS log_age_hours,
        CASE
            WHEN lb.last_full IS NULL
                THEN 'NO FULL BACKUP ON RECORD'
            WHEN DATEDIFF(HOUR, lb.last_full, @Now) > @MaxFullHours
                THEN 'FULL BACKUP STALE'
            WHEN d.recovery_model_desc <> 'SIMPLE' AND lb.last_log IS NULL
                THEN 'NO LOG BACKUP ON RECORD'
            WHEN d.recovery_model_desc <> 'SIMPLE'
                 AND DATEDIFF(HOUR, lb.last_log, @Now) > @MaxLogHours
                THEN 'LOG BACKUP STALE'
            WHEN DATEDIFF(HOUR, lb.last_diff, @Now) > @MaxDiffHours
                 AND lb.last_diff IS NOT NULL
                THEN 'DIFF BACKUP STALE'
            ELSE 'OK'
        END                                          AS status
FROM sys.databases AS d
LEFT JOIN last_backups AS lb
  ON lb.database_name = d.name
WHERE d.name NOT IN ('tempdb')          -- tempdb is recreated at startup
  AND d.state_desc = 'ONLINE'
ORDER BY CASE WHEN lb.last_full IS NULL THEN 0 ELSE 1 END,
         full_age_hours DESC;

PRINT '';
PRINT 'Databases excluded: tempdb (never backed up) and non-ONLINE databases.';
PRINT 'A database restored or created recently may show NO FULL BACKUP until';
PRINT 'its first scheduled backup runs. Judge the flag; the script only reports.';
