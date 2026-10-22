/* ============================================================================
   log_shipping_status.sql -- log shipping health from the msdb monitor tables

   Purpose:
     Report the state of every log shipping configuration recorded on this
     server: for each primary, the last transaction log backup taken and
     when; for each secondary, the last backup file copied and restored,
     and the latency of each stage in minutes.

     Run this on the monitor server when the configuration uses one. When
     there is no separate monitor, the same tables are populated on the
     primary (primary monitor tables) and on each secondary (secondary
     monitor tables), so run it on whichever side you are checking; the
     report labels each section.

   Usage (sqlcmd):
     sqlcmd -S <server> -E -i log_shipping_status.sql

   Thresholds (DECLARE variable below):
     @WarnLatencyMin  Latency beyond this many minutes is flagged in the
                      status column. Default 60.

   Compatibility:
     SQL Server 2016 or later. The log shipping monitor tables
     (msdb.dbo.log_shipping_monitor_primary,
      msdb.dbo.log_shipping_monitor_secondary,
      msdb.dbo.log_shipping_monitor_history_detail,
      msdb.dbo.log_shipping_monitor_error_detail)
     are populated by the standard log shipping backup, copy, and restore
     jobs. Reviewed against the documented msdb schema. Not executed
     against a live SQL Server instance during development; see the
     README testing status.

   Requires:
     Read access to msdb.

   Safety:
     Read-only.
   ============================================================================ */

SET NOCOUNT ON;

DECLARE @WarnLatencyMin int = 60;
DECLARE @Now datetime = GETDATE();

PRINT '================================================================';
PRINT ' Log shipping status (msdb monitor tables)';
PRINT ' Server        : ' + @@SERVERNAME;
PRINT ' Latency over ' + CAST(@WarnLatencyMin AS nvarchar(10))
      + ' minutes is flagged';
PRINT '================================================================';

PRINT '';
PRINT '--- Primary side: last log backup per primary database ---';
SELECT  p.primary_server,
        p.primary_database,
        p.backup_threshold                       AS backup_threshold_min,
        p.last_backup_date,
        DATEDIFF(MINUTE, p.last_backup_date, @Now) AS backup_age_min,
        p.last_backup_file,
        CASE
            WHEN p.last_backup_date IS NULL
                THEN 'NO BACKUP RECORDED'
            WHEN DATEDIFF(MINUTE, p.last_backup_date, @Now) > p.backup_threshold
                THEN 'BACKUP OVERDUE (past threshold)'
            WHEN DATEDIFF(MINUTE, p.last_backup_date, @Now) > @WarnLatencyMin
                THEN 'BACKUP LATE'
            ELSE 'OK'
        END                                      AS status
FROM msdb.dbo.log_shipping_monitor_primary AS p
ORDER BY p.primary_database;

PRINT '';
PRINT '--- Secondary side: last copy and restore per secondary database ---';
SELECT  s.secondary_server,
        s.secondary_database,
        s.primary_database,
        s.restore_threshold                      AS restore_threshold_min,
        s.last_copied_date,
        DATEDIFF(MINUTE, s.last_copied_date, @Now) AS copy_age_min,
        s.last_copied_file,
        s.last_restored_date,
        DATEDIFF(MINUTE, s.last_restored_date, @Now) AS restore_age_min,
        s.last_restored_file,
        s.last_restored_latency                  AS restore_latency_min,
        CASE
            WHEN s.last_restored_date IS NULL
                THEN 'NEVER RESTORED'
            WHEN DATEDIFF(MINUTE, s.last_restored_date, @Now) > s.restore_threshold
                THEN 'RESTORE OVERDUE (past threshold)'
            WHEN DATEDIFF(MINUTE, s.last_restored_date, @Now) > @WarnLatencyMin
                THEN 'RESTORE LATE'
            ELSE 'OK'
        END                                      AS status
FROM msdb.dbo.log_shipping_monitor_secondary AS s
ORDER BY s.secondary_database;

PRINT '';
PRINT '--- Recent log shipping errors (last 24 hours, newest first) ---';
SELECT TOP (50)
        e.agent_id,
        e.session_id,
        e.database_name,
        e.message                                AS error_message,
        e.log_time
FROM msdb.dbo.log_shipping_monitor_error_detail AS e
WHERE e.log_time >= DATEADD(HOUR, -24, @Now)
ORDER BY e.log_time DESC;

PRINT '';
PRINT 'Empty primary or secondary sections mean this server does not record';
PRINT 'that side of any configuration (for example, a primary with no monitor';
PRINT 'role). Run the script on the monitor, primary, and secondary servers';
PRINT 'to see the whole picture.';
