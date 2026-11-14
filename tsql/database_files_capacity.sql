/* ============================================================================
   database_files_capacity.sql -- Database file sizes, autogrowth, free
   space, volume capacity, and VLF counts

   Purpose:
     Answer the capacity questions a DBA asks before a database runs out
     of room: how big is each database and how much free space is left
     inside its files, is autogrowth configured sanely, how much room is
     left on the disks the files live on, and how many virtual log files
     each log has.

     Free space inside a file and free space on the volume are two
     different facts and the script keeps them apart. A database can be
     out of free space in its files while the disk has room, in which
     case autogrowth fixes it, or the disk can be full while the files
     still have free space, in which case autogrowth cannot help. Both
     numbers are reported so the fix matches the actual problem.

     VLF count matters because a log with thousands of virtual log
     files slows recovery, restore, and log backup. High counts almost
     always trace to a log that grew in many small increments, which is
     why the autogrowth audit and the VLF count sit in the same script.

   Usage (sqlcmd):
     sqlcmd -S <server> -E -i database_files_capacity.sql

   Thresholds (DECLARE variables below):
     @FileFreeWarnPct   Flag a database whose data files are below this
                        percent free space inside the files. Default 10.
     @LogUsedWarnPct    Flag a database whose log is above this percent
                        used. Default 80.
     @VolumeFreeWarnGB  Flag a volume with less than this many GB free.
                        Default 20.
     @VlfWarnCount      Flag a database with more than this many VLFs.
                        Default 100.

   Compatibility:
     SQL Server 2016 or later. Uses sys.master_files, sys.databases,
     sys.dm_os_volume_stats, and sys.dm_db_log_space_usage. The VLF
     section uses sys.dm_db_log_info, which needs SQL Server 2016 SP2
     or later; on earlier builds that section is skipped with a note
     instead of failing the script. Reviewed against the documented
     catalog and DMV schemas. Not executed against a live SQL Server
     instance during development; see the README testing status.

   Requires:
     VIEW SERVER STATE and VIEW ANY DEFINITION (a sysadmin works; a
     dedicated monitoring login with those grants is the better
     production answer). Only ONLINE databases are measured for space
     used; other databases still appear in the file inventory with
     their configured sizes.

   Notes:
     - Space used inside data files comes from FILEPROPERTY, which
       needs database context, so the script loops over the ONLINE
       databases and reads it one database at a time. A database the
       login cannot read is reported and skipped, not fatal.
     - Log space used comes from sys.dm_db_log_space_usage, which is
       per-database as well and is collected in the same loop.
     - Growth is reported in MB for fixed growth and as a percent for
       percent growth. Percent growth is flagged in the audit section
       because a fixed percent grows larger with every growth event.
     - max_size of -1 means unlimited. An unlimited file on a volume
       with little free space is a capacity incident waiting to
       happen, which is why the audit and the volume sections sit
       next to each other.

   Safety:
     Read-only.
   ============================================================================ */

SET NOCOUNT ON;

DECLARE @FileFreeWarnPct  decimal(5,2) = 10.0;
DECLARE @LogUsedWarnPct   decimal(5,2) = 80.0;
DECLARE @VolumeFreeWarnGB decimal(18,2) = 20.0;
DECLARE @VlfWarnCount     int = 100;

PRINT '================================================================';
PRINT ' Database files and capacity';
PRINT ' Server        : ' + @@SERVERNAME;
PRINT '================================================================';

/* Space used inside each file needs database context, so collect it
   one ONLINE database at a time. FILEPROPERTY SpaceUsed applies to
   data files; log usage comes from sys.dm_db_log_space_usage. */

CREATE TABLE #FileUsage (
    database_id      int    NOT NULL,
    file_id          int    NOT NULL,
    space_used_pages bigint NULL
);

CREATE TABLE #LogUsage (
    database_id        int           NOT NULL,
    total_log_size_mb  decimal(18,2) NULL,
    used_log_space_pct decimal(5,2)   NULL
);

DECLARE @DbName sysname;
DECLARE @Sql    nvarchar(max);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE state_desc = 'ONLINE';

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        INSERT INTO #FileUsage (database_id, file_id, space_used_pages)
        SELECT DB_ID(), file_id, FILEPROPERTY(name, ''SpaceUsed'')
        FROM sys.database_files;
        INSERT INTO #LogUsage (database_id, total_log_size_mb, used_log_space_pct)
        SELECT DB_ID(), total_log_size_in_bytes / 1048576.0,
               used_log_space_in_percent
        FROM sys.dm_db_log_space_usage;';

    BEGIN TRY
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        PRINT 'Could not read space usage for ' + @DbName + ': '
              + ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

PRINT '';
PRINT '--- Capacity summary per database ---';
PRINT 'Free space is inside the files. Compare with the volume section';
PRINT 'below: free space in the files does not help if the disk is full.';
SELECT  d.name                                     AS database_name,
        d.recovery_model_desc,
        SUM(CASE WHEN mf.type = 0 THEN mf.size ELSE 0 END) / 128.0
                                                   AS data_size_mb,
        SUM(CASE WHEN mf.type = 0
                 THEN ISNULL(fu.space_used_pages, 0) ELSE 0 END) / 128.0
                                                   AS data_used_mb,
        SUM(CASE WHEN mf.type = 0
                 THEN mf.size - ISNULL(fu.space_used_pages, 0)
                 ELSE 0 END) / 128.0               AS data_free_mb,
        CAST(100.0 * SUM(CASE WHEN mf.type = 0
                               THEN mf.size - ISNULL(fu.space_used_pages, 0)
                               ELSE 0 END)
             / NULLIF(SUM(CASE WHEN mf.type = 0 THEN mf.size ELSE 0 END), 0)
             AS decimal(5,2))                      AS data_free_pct,
        SUM(CASE WHEN mf.type = 1 THEN mf.size ELSE 0 END) / 128.0
                                                   AS log_size_mb,
        lu.used_log_space_pct                      AS log_used_pct,
        COALESCE(NULLIF(
            CASE WHEN CAST(100.0 * SUM(CASE WHEN mf.type = 0
                                             THEN mf.size
                                                  - ISNULL(fu.space_used_pages, 0)
                                             ELSE 0 END)
                      / NULLIF(SUM(CASE WHEN mf.type = 0 THEN mf.size ELSE 0 END), 0)
                      AS decimal(5,2)) < @FileFreeWarnPct
                 THEN 'LOW FREE SPACE; ' ELSE '' END
          + CASE WHEN lu.used_log_space_pct > @LogUsedWarnPct
                 THEN 'LOG NEARLY FULL; ' ELSE '' END
          + CASE WHEN EXISTS (SELECT 1 FROM sys.master_files AS x
                              WHERE x.database_id = d.database_id
                                AND x.is_percent_growth = 1)
                 THEN 'PERCENT GROWTH; ' ELSE '' END
          + CASE WHEN EXISTS (SELECT 1 FROM sys.master_files AS x
                              WHERE x.database_id = d.database_id
                                AND x.max_size = -1)
                 THEN 'UNLIMITED MAX SIZE; ' ELSE '' END, ''), 'OK')
                                                   AS notes
FROM sys.databases AS d
JOIN sys.master_files AS mf
  ON mf.database_id = d.database_id
LEFT JOIN #FileUsage AS fu
  ON fu.database_id = mf.database_id
 AND fu.file_id = mf.file_id
LEFT JOIN #LogUsage AS lu
  ON lu.database_id = d.database_id
GROUP BY d.name, d.database_id, d.recovery_model_desc,
         lu.used_log_space_pct
ORDER BY d.name;

PRINT '';
PRINT '--- File inventory ---';
PRINT 'Used and free space are shown for data files. Log file usage is';
PRINT 'in the summary above; FILEPROPERTY does not measure log files.';
SELECT  d.name                                     AS database_name,
        mf.name                                    AS file_name,
        mf.type_desc,
        mf.physical_name,
        mf.size / 128.0                            AS size_mb,
        CASE WHEN mf.type = 0
             THEN ISNULL(fu.space_used_pages, 0) / 128.0
             ELSE NULL END                         AS used_mb,
        CASE WHEN mf.type = 0
             THEN (mf.size - ISNULL(fu.space_used_pages, 0)) / 128.0
             ELSE NULL END                         AS free_mb,
        CASE mf.is_percent_growth
            WHEN 1 THEN CAST(mf.growth AS nvarchar(20)) + ' percent'
            ELSE CAST(mf.growth / 128.0 AS nvarchar(20)) + ' MB'
        END                                        AS growth,
        CASE mf.max_size
            WHEN -1 THEN 'unlimited'
            WHEN 268435456 THEN '2 TB cap'
            ELSE CAST(mf.max_size / 128.0 AS nvarchar(20)) + ' MB'
        END                                        AS max_size,
        mf.state_desc
FROM sys.master_files AS mf
JOIN sys.databases AS d
  ON d.database_id = mf.database_id
LEFT JOIN #FileUsage AS fu
  ON fu.database_id = mf.database_id
 AND fu.file_id = mf.file_id
ORDER BY d.name, mf.type, mf.file_id;

PRINT '';
PRINT '--- Volume free space ---';
PRINT 'One row per volume that holds a database file. A volume shared';
PRINT 'by several databases is one risk, not several.';
SELECT DISTINCT
        vs.volume_mount_point,
        vs.total_bytes / 1073741824.0              AS total_gb,
        vs.available_bytes / 1073741824.0          AS available_gb,
        CAST(100.0 * vs.available_bytes
             / NULLIF(vs.total_bytes, 0) AS decimal(5,2))
                                                   AS available_pct,
        CASE WHEN vs.available_bytes / 1073741824.0 < @VolumeFreeWarnGB
             THEN 'LOW FREE SPACE' ELSE 'OK' END  AS status
FROM sys.master_files AS mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
ORDER BY vs.volume_mount_point;

PRINT '';
PRINT '--- Autogrowth audit ---';
PRINT 'Files listed here need attention. An empty result means no';
PRINT 'autogrowth concerns were found. Percent growth, growth of less';
PRINT 'than 64 MB, autogrowth off, and unlimited max size are all';
PRINT 'flagged because each one fails in a different way when a';
PRINT 'database grows under load.';
SELECT  d.name                                     AS database_name,
        mf.name                                    AS file_name,
        mf.type_desc,
        mf.size / 128.0                            AS size_mb,
        CASE mf.is_percent_growth
            WHEN 1 THEN CAST(mf.growth AS nvarchar(20)) + ' percent'
            ELSE CAST(mf.growth / 128.0 AS nvarchar(20)) + ' MB'
        END                                        AS growth,
        CASE mf.max_size
            WHEN -1 THEN 'unlimited'
            WHEN 268435456 THEN '2 TB cap'
            ELSE CAST(mf.max_size / 128.0 AS nvarchar(20)) + ' MB'
        END                                        AS max_size,
        CASE WHEN mf.growth = 0 THEN 'AUTOGROWTH OFF; ' ELSE '' END
      + CASE WHEN mf.is_percent_growth = 1
             THEN 'PERCENT GROWTH; ' ELSE '' END
      + CASE WHEN mf.is_percent_growth = 0 AND mf.growth > 0
                  AND mf.growth / 128.0 < 64
             THEN 'SMALL GROWTH INCREMENT; ' ELSE '' END
      + CASE WHEN mf.max_size = -1
             THEN 'UNLIMITED MAX SIZE; ' ELSE '' END
                                                   AS findings
FROM sys.master_files AS mf
JOIN sys.databases AS d
  ON d.database_id = mf.database_id
WHERE mf.growth = 0
   OR mf.is_percent_growth = 1
   OR (mf.is_percent_growth = 0 AND mf.growth > 0
       AND mf.growth / 128.0 < 64)
   OR mf.max_size = -1
ORDER BY d.name, mf.type, mf.file_id;

PRINT '';
PRINT '--- Virtual log file counts ---';
PRINT 'High VLF counts slow recovery, restore, and log backup. They';
PRINT 'usually trace to a log that grew in many small increments.';
CREATE TABLE #VlfSummary (
    database_id        int           NOT NULL,
    vlf_count          int           NOT NULL,
    active_vlf_count   int           NOT NULL,
    total_log_size_mb  decimal(18,2) NOT NULL,
    avg_vlf_size_mb    decimal(18,2) NULL
);

DECLARE @VlfSql nvarchar(max) = N'
    INSERT INTO #VlfSummary (database_id, vlf_count, active_vlf_count,
                             total_log_size_mb, avg_vlf_size_mb)
    SELECT database_id,
           COUNT(*),
           SUM(CASE WHEN vlf_active = 1 THEN 1 ELSE 0 END),
           SUM(vlf_size_mb),
           AVG(vlf_size_mb)
    FROM sys.dm_db_log_info(NULL)
    GROUP BY database_id;';

BEGIN TRY
    EXEC sp_executesql @VlfSql;

    SELECT  d.name                                 AS database_name,
            vs.vlf_count,
            vs.active_vlf_count,
            vs.total_log_size_mb,
            vs.avg_vlf_size_mb,
            CASE WHEN vs.vlf_count > @VlfWarnCount
                 THEN 'HIGH VLF COUNT' ELSE 'OK' END
                                                   AS status
    FROM #VlfSummary AS vs
    JOIN sys.databases AS d
      ON d.database_id = vs.database_id
    ORDER BY vs.vlf_count DESC;
END TRY
BEGIN CATCH
    PRINT 'VLF information is not available on this build.';
    PRINT 'sys.dm_db_log_info needs SQL Server 2016 SP2 or later.';
    PRINT 'On earlier builds, run DBCC LOGINFO in each database for';
    PRINT 'the same information: one row per VLF, Status 2 is active.';
END CATCH;

DROP TABLE IF EXISTS #FileUsage;
DROP TABLE IF EXISTS #LogUsage;
DROP TABLE IF EXISTS #VlfSummary;
