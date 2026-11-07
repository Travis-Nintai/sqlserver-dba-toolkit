# SQL Server Agent job health

`tsql/agent_job_health.sql` is the morning check for everything SQL Server
Agent is supposed to be doing. Backups, index maintenance, log shipping,
and statistics updates all run as Agent jobs on most instances, so a job
that quietly stops succeeding is usually how a backup gap or a stale
secondary is discovered, days late. This script reads the msdb job tables
and reports the jobs that need a DBA's attention, with the last outcome
and the message that explains it.

Run it by hand when you take over an instance, and schedule it as its own
Agent job with output to a file or to the job history so the check itself
is covered by the same monitoring it performs.

## What each section means

### 1. Agent service and job counts

Confirms the Agent service is running and counts enabled versus disabled
jobs. If the service is stopped, nothing else in the script matters much:
no scheduled job will run. The service row comes from
`sys.dm_server_services`, which needs VIEW SERVER STATE. If your login
cannot read it, the section says so and the rest of the script still runs.

### 2. Jobs failed in the last 24 hours

The most urgent section. Each row is a job whose latest outcome row
(step_id 0 in `sysjobhistory`) is a failure inside the look-back window,
with the last run time, how long it ran, and the first 200 characters of
the outcome message.

The next step is always the same: open the job history, find the failed
step, and read its message. The job-level message is a summary; the step
message names the actual error. Common causes are a step that references
a database that was renamed or dropped, a drive that filled up under a
backup step, a proxy or credential that expired, and a step that timed
out because the instance was busy.

A job that fails and then succeeds on retry still appears here only if
its latest outcome is a failure. A job configured to retry on failure
and eventually succeed will not show up, which is the right behavior:
the retry worked. If retries are masking a real problem, the history
will show the retry pattern.

### 3. Enabled jobs with no successful run in 7 days

This is the section that catches the jobs section 2 misses. A job can be
enabled, scheduled, and never succeed, and if its last failure aged out
of the 24-hour window it disappears from section 2 entirely. Section 3
lists every enabled job whose last successful run is older than the
threshold, or that never succeeded at all.

Read the `last_outcome` column first. FAILED means the job is trying and
failing; check the step history. CANCELED means something stopped it,
often a person during an incident, and nobody re-enabled the schedule.
IN PROGRESS on a job that has not succeeded in a week usually means a
run that hung; compare with section 4. NO HISTORY ON RECORD means the
job has no outcome rows in retained history at all, which usually means
one of two things: the job really never ran, or Agent history retention
aged its rows out. Check the retention settings before concluding the
job never ran.

A job that never succeeded is often a job that was created and never
tested, or a job whose first step fails immediately, for example a step
that runs as a proxy the job owner cannot use. That is worth fixing even
if nobody depends on the job yet, because an untested job is a job that
will fail the first night it matters.

### 4. Currently running jobs

Jobs running right now, with how long each has been running and a LONG
RUNNING flag past the threshold (default 60 minutes). This reads
`sysjobactivity` for the current Agent session, so it shows the current
run, not stale rows from a previous Agent restart.

Long is not the same as stuck. A backup job on a large database, an index
rebuild, or a statistics update can legitimately run for hours. Before
stopping a long-running job, check its history for the same job: if it
normally takes 90 minutes, 70 minutes is not a problem. If it normally
takes 10 minutes and it has been running for 3 hours, look at blocking
(`tsql/blocking_and_deadlocks.sql`) and waits
(`tsql/wait_statistics.sql`) before deciding whether to stop it.

### 5. Enabled jobs with no schedule

An enabled job with no schedule only runs when someone starts it by
hand. That is correct for an on-demand job, such as a manual failover
checklist or an ad hoc rebuild. It is a gap for a job that was meant to
run on a schedule, which usually happens when a job is scripted out from
one instance and created on another without its schedule, or when a
schedule is deleted during cleanup and nobody notices the job stopped
running. If the job name suggests it should run regularly and it has no
schedule, ask whether the schedule was lost.

### 6. Disabled jobs

Disabled is a state, not a failure. The thing to look for here is a job
that was disabled during an incident and never re-enabled. If the
description or the name says the job is part of normal operations and it
is disabled with no note explaining why, that is a question for the team,
not a finding to fix silently.

### 7. Jobs with an unresolvable owner login

`SUSER_SNAME(owner_sid)` returns NULL when the login that owns the job
no longer exists. The job can still run, but its execution context is no
longer what the owner intended, and the job will fail if any step
depends on the owner's permissions in a way that is no longer valid.
Point these jobs at a service account or a current DBA login. This
commonly follows a departure: a DBA leaves, their login is removed, and
the jobs they owned keep running until something changes.

### 8. Enabled jobs with no failure notification

A job that fails and tells nobody is how a backup job can be broken for
a week before anyone notices. This section lists enabled jobs with no
email or pager notification configured, along with the event log setting
and the notify operator, if one is set.

The notification levels are: 0 never, 1 on success, 2 on failure,
3 always. For most jobs, notify on failure (2) to the DBA operator is
the right setting. Notify on success is noise for a job that runs every
15 minutes.

On RDS SQL Server this section is expected to be empty, because
operators, alerts, and Database Mail notifications do not run there.
See `docs/aws-hosted-sql-server.md` for what RDS changes.

## Job history retention

`sysjobhistory` only holds what Agent retention allows. By default Agent
keeps 1,000 history rows in total and 100 rows per job, and a job that
runs every 15 minutes can push its own older history out in about a day.
That is why a job can show NO HISTORY ON RECORD even though it ran last
week: the rows aged out.

Raise the limits with `sp_set_sqlagent_properties` if you need deeper
history, and remember the tradeoff: history rows live in msdb, and very
large limits on a busy instance grow msdb. The usual answer is to keep
retention modest and let a scheduled run of this script, with output
captured, be the durable record.

## Scheduling this check

Schedule `agent_job_health.sql` as its own Agent job, daily, with the
output written to a file or captured in the job history. Give the job a
failure notification (section 8 applies to it too), and set the
thresholds at the top of the script to match the instance: a longer
`@NoSuccessDays` on an instance with weekly jobs, a shorter
`@FailedJobHours` if you run the check more than once a day.

## Troubleshooting

| Symptom | Likely cause | First check |
|---|---|---|
| A job fails every run with the same message | Step references something that no longer exists, or a permission was removed | The failed step message in job history |
| A job succeeds sometimes and fails others | Resource contention, a timeout, or a dependency on another job | Run duration variance in history; blocking and waits at the failure time |
| A job never ran | No schedule, disabled, or the Agent service was down | Sections 5 and 6; Agent error log for service restarts |
| A job shows NO HISTORY ON RECORD | History aged out by retention, or it genuinely never ran | Agent retention settings; `sp_help_jobhistory` |
| A job runs far longer than usual | Blocking, a large data change since the last run, or a hung step | `tsql/blocking_and_deadlocks.sql`, `tsql/wait_statistics.sql`, the step output |
| A job fails after a login was removed | Job owner no longer resolves | Section 7 |
| Nobody knew a job was failing | No failure notification configured | Section 8; check Database Mail and the operator |

## Relationship to the other scripts

Backup jobs are the most common Agent jobs, and this script pairs with
`tsql/backup_verification.sql`, which checks msdb backup history rather
than job success: a backup job can report success while an individual
database was skipped, and a backup job can fail while the database was
still backed up by another job. Log shipping jobs are covered from the
log shipping side by `tsql/log_shipping_status.sql`, which reads the
monitor tables; this script covers whether the log shipping jobs
themselves are healthy. Always On monitoring is in
`docs/always-on-availability-groups.md`.
