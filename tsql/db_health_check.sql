/* ============================================================================
   db_health_check.sql -- SQL Server instance health check

   Purpose:
     One-pass instance overview: version and uptime, database state and
     recovery model, database file space usage, and current activity
     (requests running longer than a threshold, blocking chains).

   Usage (sqlcmd):
     sqlcmd -S <server> -E -i db_health_check.sql

   Thresholds:
     @LongRequestSec below. Requests running longer than this many seconds
     are listed in the activity section. Edit the DECLARE to tune it; the
     value is a variable, not buried in the queries.

   Compatibility:
     SQL Server 2016 or later. Reviewed against the documented catalog and
     DMV schemas. Not executed against a live SQL Server instance during
     development; see the README testing status.

   Requires:
     VIEW SERVER STATE for the DMV sections; msdb read access is not
     needed by this script.

   Safety:
     Read-only. Queries DMVs and catalog views only.
   ============================================================================ */

SET NOCOUNT ON;

DECLARE @LongRequestSec int = 60;

PRINT '================================================================';
PRINT ' SQL Server health check';
PRINT ' Server        : ' + @@SERVERNAME;
PRINT ' SQL Server    : ' + CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128))
      + ' (' + CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) + ')';
PRINT ' Started       : ' + CONVERT(nvarchar(30),
        (SELECT sqlserver_start_time FROM sys.dm_os_sys_info), 120);
PRINT ' Long req >    : ' + CAST(@LongRequestSec AS nvarchar(10)) + ' seconds';
PRINT '================================================================';

PRINT '';
PRINT '--- Databases: state, recovery model, compatibility ---';
SELECT  d.name                                   AS database_name,
        d.state_desc                             AS state,
        d.recovery_model_desc                    AS recovery_model,
        d.compatibility_level                    AS compat_level,
        d.user_access_desc                       AS user_access,
        CASE WHEN d.is_read_only = 1 THEN 'READ_ONLY' ELSE '' END AS notes
FROM sys.databases AS d
ORDER BY d.name;

PRINT '';
PRINT '--- Database files: size and free space ---';
SELECT  DB_NAME(mf.database_id)                  AS database_name,
        mf.name                                  AS file_logical_name,
        mf.type_desc                             AS file_type,
        CAST(mf.size * 8.0 / 1024 AS decimal(18,1)) AS size_mb,
        CAST((mf.size - FILEPROPERTY(mf.name, 'SpaceUsed')) * 8.0 / 1024
             AS decimal(18,1))                   AS free_mb_inside_file,
        mf.physical_name
FROM sys.master_files AS mf
ORDER BY database_name, mf.type, mf.name;

PRINT '';
PRINT '--- Long-running requests (active, over threshold) ---';
SELECT  r.session_id,
        r.status,
        r.command,
        DB_NAME(r.database_id)                   AS database_name,
        s.login_name,
        r.cpu_time                               AS cpu_ms,
        r.total_elapsed_time / 1000              AS elapsed_sec,
        r.reads,
        r.writes,
        r.logical_reads,
        SUBSTRING(t.text, 1, 200)                AS statement_text
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s
  ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.session_id <> @@SPID
  AND r.total_elapsed_time >= @LongRequestSec * 1000
ORDER BY r.total_elapsed_time DESC;

PRINT '';
PRINT '--- Blocking chains (blocked sessions and their blockers) ---';
SELECT  r.session_id                             AS blocked_session,
        s.login_name                             AS blocked_login,
        DB_NAME(r.database_id)                   AS database_name,
        r.blocking_session_id                    AS blocking_session,
        bs.login_name                            AS blocking_login,
        r.wait_type,
        r.wait_time / 1000                       AS wait_sec,
        SUBSTRING(t.text, 1, 200)                AS blocked_statement
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s
  ON s.session_id = r.session_id
LEFT JOIN sys.dm_exec_sessions AS bs
  ON bs.session_id = r.blocking_session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.blocking_session_id <> 0
ORDER BY r.wait_time DESC;

PRINT '';
PRINT '--- tempdb: files and current usage ---';
SELECT  CAST(SUM(unallocated_extent_page_count) * 8.0 / 1024 AS decimal(18,1))
                                                 AS tempdb_free_mb,
        CAST(SUM(version_store_reserved_page_count) * 8.0 / 1024 AS decimal(18,1))
                                                 AS version_store_mb,
        CAST(SUM(user_object_reserved_page_count) * 8.0 / 1024 AS decimal(18,1))
                                                 AS user_objects_mb,
        CAST(SUM(internal_object_reserved_page_count) * 8.0 / 1024 AS decimal(18,1))
                                                 AS internal_objects_mb
FROM sys.dm_db_file_space_usage
WHERE database_id = DB_ID('tempdb');

PRINT '';
PRINT 'Health check complete.';
