/* ============================================================================
   index_maintenance_candidates.sql -- indexes and statistics that need care

   Purpose:
     List the indexes whose fragmentation has crossed the maintenance
     thresholds, with a suggested action per index, and list statistics
     that are stale enough and changed enough to deserve an update.
     This script only reports candidates; it does not rebuild, reorganize,
     or update anything. Maintenance itself belongs in a scheduled job
     (SQL Server Agent, or a community maintenance solution) where the
     window, the edition (online vs offline rebuild), and the logging
     behavior are chosen deliberately.

     Run in the context of the database you want to check. The physical
     stats function is scoped to the current database; repeat per
     database, or drive it from a loop over sys.databases in a job.

   Usage (sqlcmd):
     sqlcmd -S <server> -d <database> -E -i index_maintenance_candidates.sql

   Thresholds (DECLARE variables below):
     @ReorganizePct    Fragmentation at or above this suggests REORGANIZE.
                       Default 10 percent.
     @RebuildPct       Fragmentation at or above this suggests REBUILD.
                       Default 30 percent.
     @MinPages         Ignore indexes smaller than this many pages; tiny
                       indexes churn without benefit. Default 1000.
     @StaleStatsDays   Statistics older than this many days are candidates
                       when they also exceed @MinModifications.
                       Default 7 days.
     @MinModifications Minimum modification counter for a stale statistic
                       to be listed. Default 1000.

   Compatibility:
     SQL Server 2016 or later. Uses sys.dm_db_index_physical_state,
     sys.dm_db_stats_properties, and STATS_DATE. SAMPLED mode keeps the
     scan cost reasonable on large tables; use DETAILED when precision
     matters and the window allows it. Reviewed against the documented
     catalog and DMV schemas. Not executed against a live SQL Server
     instance during development; see the README testing status.

   Requires:
     VIEW DATABASE STATE in the target database (plus CONNECT). The
     stats section needs nothing beyond that.

   Safety:
     Read-only. No index or statistics is modified by this script.
   ============================================================================ */

SET NOCOUNT ON;

DECLARE @ReorganizePct    decimal(5,2) = 10.0;
DECLARE @RebuildPct       decimal(5,2) = 30.0;
DECLARE @MinPages         int          = 1000;
DECLARE @StaleStatsDays   int          = 7;
DECLARE @MinModifications bigint       = 1000;

PRINT '================================================================';
PRINT ' Index and statistics maintenance candidates';
PRINT ' Server        : ' + @@SERVERNAME;
PRINT ' Database      : ' + DB_NAME();
PRINT ' Reorganize >= ' + CAST(@ReorganizePct AS nvarchar(10))
      + '%   Rebuild >= ' + CAST(@RebuildPct AS nvarchar(10))
      + '%   Min pages ' + CAST(@MinPages AS nvarchar(10));
PRINT '================================================================';

PRINT '';
PRINT '--- Fragmented indexes (SAMPLED scan) ---';
PRINT 'REBUILD is offline in Standard edition: schedule accordingly.';
SELECT  OBJECT_SCHEMA_NAME(ips.object_id) AS schema_name,
        OBJECT_NAME(ips.object_id)        AS table_name,
        i.name                            AS index_name,
        i.type_desc                       AS index_type,
        ips.avg_fragmentation_in_percent,
        ips.page_count,
        ips.avg_page_space_used_in_percent,
        CASE
            WHEN ips.avg_fragmentation_in_percent >= @RebuildPct
                THEN 'REBUILD'
            WHEN ips.avg_fragmentation_in_percent >= @ReorganizePct
                THEN 'REORGANIZE'
            ELSE 'NONE'
        END                               AS suggested_action
FROM sys.dm_db_index_physical_state(DB_ID(), NULL, NULL, NULL, 'SAMPLED') AS ips
JOIN sys.indexes AS i
  ON i.object_id = ips.object_id
 AND i.index_id  = ips.index_id
WHERE ips.index_id > 0                 -- skip heaps; fragmentation guidance differs
  AND ips.page_count >= @MinPages
  AND ips.alloc_unit_type_desc = 'IN_ROW_DATA'
  AND ips.avg_fragmentation_in_percent >= @ReorganizePct
ORDER BY ips.avg_fragmentation_in_percent DESC;

PRINT '';
PRINT '--- Stale statistics with significant changes ---';
PRINT 'Auto-update usually handles these; investigate when it does not.';
SELECT  OBJECT_SCHEMA_NAME(s.object_id) AS schema_name,
        OBJECT_NAME(s.object_id)         AS table_name,
        s.name                           AS stats_name,
        STATS_DATE(s.object_id, s.stats_id) AS last_updated,
        DATEDIFF(DAY, STATS_DATE(s.object_id, s.stats_id), GETDATE())
                                         AS age_days,
        sp.modification_counter,
        sp.rows,
        sp.rows_sampled,
        CASE WHEN sp.rows > 0
             THEN 100.0 * sp.rows_sampled / sp.rows
             ELSE NULL END               AS sample_pct
FROM sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE s.is_temporary = 0
  AND DATEDIFF(DAY, STATS_DATE(s.object_id, s.stats_id), GETDATE()) > @StaleStatsDays
  AND sp.modification_counter > @MinModifications
ORDER BY sp.modification_counter DESC;
