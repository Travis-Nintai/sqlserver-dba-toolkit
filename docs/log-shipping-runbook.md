# Log shipping troubleshooting runbook

Log shipping is three jobs and a file share: the primary backs up the
transaction log on a schedule, a copy job moves the files to the secondary,
and a restore job applies them in order. When a secondary drifts, one of
those three stages has stalled, and the monitor tables tell you which one.

Run `tsql/log_shipping_status.sql` first. Work from its output.

## Step 1: find the stalled stage

Compare the three timestamps for the affected database:

- `last_backup_date` old, copy and restore newer or equal: the **backup
  job** on the primary is the problem.
- Backup current, `last_copied_date` old: the **copy job** or the share
  path is the problem.
- Backup and copy current, `last_restored_date` old: the **restore job**
  on the secondary is the problem.

Do not start by restarting everything. Fix the stalled stage; the others
are doing their jobs and restarting them only adds noise.

## Step 2: backup stage problems

- Check the backup job history in SQL Server Agent on the primary. Common
  causes: the job is disabled, the Agent service is stopped, the backup
  share is full, or the account running the job lost permission to the
  share.
- Check the database is still in FULL or BULK_LOGGED recovery and ONLINE.
  A database switched to SIMPLE recovery breaks the log chain, and log
  backups stop being possible until a new full backup re-establishes it.
- Check free space on the backup share. Log shipping fails quietly in
  reports but loudly in disk usage: hourly log backups of a busy database
  accumulate fast when the copy stage is down.

## Step 3: copy stage problems

- Check the copy job history on the secondary and the monitor error detail
  (`msdb.dbo.log_shipping_monitor_error_detail`, surfaced by the status
  script).
- Test the path by hand: from the secondary, open the primary's backup
  share. Permission changes and expired service account passwords are the
  usual story, and they present as "the copy job runs but copies nothing."
- Confirm the files exist on the primary side. A copy job with nothing to
  copy because the backup stage silently failed looks identical to a copy
  failure until you check the source folder.

## Step 4: restore stage problems

- Check the restore job history on the secondary. The frequent cause is a
  restore that cannot get exclusive access: someone connected to the
  secondary database, or a read-only reporting process is holding it. The
  restore job disconnects users when configured to; verify that setting
  before blaming the job.
- A restore chain breaks permanently if a log backup file was deleted
  before being applied. If sequence is broken, the cure is re-initializing
  the secondary from a fresh full backup of the primary, taken with the
  log shipping configuration in mind. There is no shortcut past a missing
  link in the chain.
- If restores run but latency grows, look at file size and restore rate: a
  primary generating log faster than the secondary restores it will drift
  during peak hours and catch up off-peak. That is a capacity question,
  not an outage, until it stops catching up.

## Step 5: threshold and alert hygiene

- The backup and restore thresholds in the monitor tables are the values
  log shipping itself uses to raise threshold alerts. If the status script
  flags `OVERDUE (past threshold)` but nobody was paged, check that the
  alert job (`log shipping alert job`) exists and is enabled on the
  monitor server. The monitoring data and the alerting are separate
  mechanisms.
- Keep thresholds honest. A restore threshold of 24 hours on a secondary
  that is supposed to be a warm standby is not monitoring, it is
  decoration.

## After any fix

Re-run `tsql/log_shipping_status.sql` and confirm the stage timestamps
advance and latency falls. Then confirm the last restored file on the
secondary matches, or is approaching, the last backup file on the primary.
The secondary is only as current as its last restored log, and that number,
not job success, is the health of the configuration.

## Related material

- `tsql/log_shipping_status.sql`: the monitor-table report this runbook
  starts from.
- `tsql/backup_verification.sql`: validates the primary's backup chain
  itself, including databases that are not log shipped.
