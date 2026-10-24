/* ============================================================================
   tempdb_health.sql -- TempDB configuration, space usage, and contention

   Purpose:
     Report TempDB the way an incident demands: is the file layout sane,
     how full is it right now, what is consuming the space, and is
     anything waiting on TempDB allocation pages this minute.

     TempDB is recreated on every service start, so configuration mistakes
     (one data file, wildly uneven sizes, autogrowth by percent) show up
     here as facts. Space pressure shows up in sys.dm_db_file_space_usage,
     broken into user objects, internal objects (sorts, spools, hash
     spills), and the version store. Contention shows up as PAGELATCH
     waits on pages in database 2.

   Usage (sqlcmd):
     sqlcmd -S <server> -E -i tempdb_health.sql

   Thresholds (DECLARE variables below):
     @SpaceUsedWarnPct  Total TempDB space used beyond this percent of
                        allocated size is flagged. Default 80.

   Compatibility:
     SQL Server 2016 or later. Uses tempdb.sys.database_files,
     sys.dm_db_file_space_usage, sys.dm_db_session_space_usage,
     sys.dm_tran_active_snapshot_database_transactions, and
     sys.dm_os_waiting_tasks. On 2016 and later, data file count and
     sizing follow the setup-time guidance (one file per logical
     processor up to 8, equal sizes); the script reports the facts and
     lets the DBA compare. Reviewed against the documented catalog and
     DMV schemas. Not executed against a live SQL Server instance during
     development; see the README testing status.

   Requires:
     VIEW SERVER STATE.

   Safety:
     Read-only.
   ============================================================================ */

SET NOCOUNT ON;

DECLARE @SpaceUsedWarnPct decimal(5,2) = 80.0;

PRINT '================================================================';
PRINT ' TempDB health';
PRINT ' Server        : ' + @@SERVERNAME;
PRINT '================================================================';

PRINT '';
PRINT '--- TempDB data and log files ---';
PRINT 'Look for: equal-sized data files, count matching cores up to 8,';
PRINT 'fixed MB autogrowth (never percent).';
SELECT  df.name,
        df.physical_name,
        df.type_desc,
        df.size / 128.0                    AS size_mb,
        CASE df.is_percent_growth
            WHEN 1 THEN CAST(df.growth AS nvarchar(20)) + ' percent'
            ELSE CAST(df.growth / 128.0 AS nvarchar(20)) + ' MB'
        END                               AS growth,
        CASE df.max_size
            WHEN -1 THEN 'unlimited'
            WHEN 268435456 THEN '2 TB (log cap)'
            ELSE CAST(df.max_size / 128.0 AS nvarchar(20)) + ' MB'
        END                               AS max_size,
        df.state_desc
FROM tempdb.sys.database_files AS df
ORDER BY df.type_desc, df.file_id;

PRINT '';
PRINT '--- TempDB space usage by category ---';
SELECT  (SELECT SUM(size) FROM tempdb.sys.database_files
         WHERE type = 0) / 128.0                                  AS data_size_mb,
        (SELECT SUM(size) FROM tempdb.sys.database_files
         WHERE type = 1) / 128.0                                  AS log_size_mb,
        fsu.unallocated_extent_page_count / 128.0                 AS free_mb,
        fsu.version_store_reserved_page_count / 128.0             AS version_store_mb,
        fsu.user_object_reserved_page_count / 128.0               AS user_objects_mb,
        fsu.internal_object_reserved_page_count / 128.0           AS internal_objects_mb,
        fsu.mixed_extent_page_count / 128.0                      AS mixed_extents_mb,
        CAST(100.0 * (fsu.version_store_reserved_page_count
                      + fsu.user_object_reserved_page_count
                      + fsu.internal_object_reserved_page_count)
             / NULLIF((SELECT SUM(size) FROM tempdb.sys.database_files
                       WHERE type = 0), 0)
             AS decimal(5,2))                                     AS data_used_pct,
        CASE
            WHEN CAST(100.0 * (fsu.version_store_reserved_page_count
                               + fsu.user_object_reserved_page_count
                               + fsu.internal_object_reserved_page_count)
                      / NULLIF((SELECT SUM(size) FROM tempdb.sys.database_files
                                WHERE type = 0), 0)
                      AS decimal(5,2)) > @SpaceUsedWarnPct
                THEN 'SPACE PRESSURE'
            ELSE 'OK'
        END                                                      AS status
FROM sys.dm_db_file_space_usage AS fsu;

PRINT '';
PRINT '--- Top TempDB consumers by session (allocated minus deallocated) ---';
SELECT TOP 10
       s.session_id,
       s.login_name,
       s.host_name,
       s.program_name,
       (ssu.user_objects_alloc_page_count
        - ssu.user_objects_dealloc_page_count) / 128.0   AS user_objects_net_mb,
       (ssu.internal_objects_alloc_page_count
        - ssu.internal_objects_dealloc_page_count) / 128.0 AS internal_objects_net_mb
FROM sys.dm_db_session_space_usage AS ssu
JOIN sys.dm_exec_sessions AS s
  ON s.session_id = ssu.session_id
WHERE ssu.session_id > 50
ORDER BY (ssu.user_objects_alloc_page_count
          - ssu.user_objects_dealloc_page_count
          + ssu.internal_objects_alloc_page_count
          - ssu.internal_objects_dealloc_page_count) DESC;

PRINT '';
PRINT '--- Longest-running version store transactions (database_id 2) ---';
PRINT 'A growing version store usually traces to one of these.';
SELECT TOP 10
       s.session_id,
       s.login_name,
       s.host_name,
       s.program_name,
       at.transaction_begin_time,
       DATEDIFF(SECOND, at.transaction_begin_time, GETDATE())
                                                    AS open_seconds,
       at.transaction_id
FROM sys.dm_tran_active_snapshot_database_transactions AS at
JOIN sys.dm_exec_sessions AS s
  ON s.session_id = at.session_id
WHERE at.database_id = 2
ORDER BY open_seconds DESC;

PRINT '';
PRINT '--- Current PAGELATCH waits on TempDB pages ---';
PRINT 'Repeated 2:x:x waits here are the classic allocation contention signal.';
SELECT  wt.session_id,
        wt.wait_type,
        wt.wait_duration_ms,
        wt.resource_description,
        s.login_name,
        s.program_name
FROM sys.dm_os_waiting_tasks AS wt
JOIN sys.dm_exec_sessions AS s
  ON s.session_id = wt.session_id
WHERE wt.wait_type LIKE 'PAGELATCH%'
  AND wt.resource_description LIKE '2:%'
ORDER BY wt.wait_duration_ms DESC;
