/* ============================================================================
   hosting_inventory.sql -- Instance inventory for an AWS hosting decision

   Purpose:
     Collect, in one read-only pass, the instance facts that decide
     whether a SQL Server workload fits Amazon RDS for SQL Server, fits
     better on SQL Server on Amazon EC2, or needs rework before either
     move. It does not make the decision. It surfaces the blockers and
     the sizing inputs: edition and version, database count and recovery
     models, Agent job step types, linked servers, log shipping and
     availability group configuration, database snapshots, CLR and
     xp_cmdshell settings, and file layout per database.

     Run this on the on-premises or current instance before migration
     planning, and read it alongside docs/aws-hosted-sql-server.md, which
     explains what each finding means on RDS versus EC2. The companion
     doc is the judgment layer; this script is the evidence layer.

   Usage (sqlcmd):
     sqlcmd -S <server> -E -i hosting_inventory.sql

   Compatibility:
     SQL Server 2016 or later. Uses SERVERPROPERTY, sys.databases,
     sys.configurations, msdb job and log shipping monitor tables, and
     the availability group catalog views. Reviewed against the
     documented catalog and DMV schemas. Not executed against a live
     SQL Server instance during development; see the README testing
     status.

   Requires:
     VIEW SERVER STATE, plus read access to msdb job and log shipping
     history. Availability group catalog views return only groups the
     login can see.

   Safety:
     Read-only.
   ============================================================================ */

SET NOCOUNT ON;

PRINT '================================================================';
PRINT ' Hosting inventory (RDS vs EC2 decision inputs)';
PRINT ' Server        : ' + @@SERVERNAME;
PRINT '================================================================';

PRINT '';
PRINT '--- Edition and version ---';
PRINT 'RDS supports a defined set of SQL Server versions and editions;';
PRINT 'compare this row against the current RDS supported list before';
PRINT 'assuming a like-for-like move. Express edition has its own size';
PRINT 'and feature limits on any host.';
SELECT  SERVERPROPERTY('ProductVersion')    AS product_version,
        SERVERPROPERTY('ProductLevel')      AS product_level,
        SERVERPROPERTY('Edition')           AS edition,
        SERVERPROPERTY('EngineEdition')     AS engine_edition,
        SERVERPROPERTY('MachineName')       AS machine_name;

PRINT '';
PRINT '--- Databases: state, recovery model, and flags that affect a move ---';
PRINT 'TRUSTWORTHY, Service Broker, snapshots, and SIMPLE recovery each';
PRINT 'change what a migration path can carry. A database in SIMPLE';
PRINT 'recovery cannot take log backups, which matters for log-based';
PRINT 'migration methods and for Multi-AZ restore on RDS.';
SELECT  d.name,
        d.database_id,
        d.state_desc,
        d.recovery_model_desc,
        d.compatibility_level,
        d.user_access_desc,
        d.is_read_only,
        d.is_trustworthy_on,
        d.is_broker_enabled,
        d.source_database_id              AS snapshot_of_database_id,
        d.log_reuse_wait_desc
FROM sys.databases AS d
ORDER BY d.name;

PRINT '';
PRINT '--- Database files: count and total size per database ---';
PRINT 'File count and size feed storage sizing on either host. On RDS,';
PRINT 'storage is provisioned per instance with a maximum per engine;';
PRINT 'on EC2, it is EBS volumes you choose and can grow separately.';
SELECT  DB_NAME(mf.database_id)           AS database_name,
        COUNT(*)                          AS file_count,
        SUM(CAST(mf.size AS bigint)) / 128.0 AS total_size_mb,
        SUM(CASE WHEN mf.type = 0 THEN CAST(mf.size AS bigint)
                 ELSE 0 END) / 128.0      AS data_size_mb,
        SUM(CASE WHEN mf.type = 1 THEN CAST(mf.size AS bigint)
                 ELSE 0 END) / 128.0      AS log_size_mb
FROM sys.master_files AS mf
GROUP BY mf.database_id
ORDER BY database_name;

PRINT '';
PRINT '--- CLR and xp_cmdshell configuration ---';
PRINT 'CLR is limited on RDS (SAFE assemblies only on 2016 and earlier,';
PRINT 'not supported on 2017 and later), and xp_cmdshell is not';
PRINT 'available on RDS at all. A value of 1 here is a rework flag,';
PRINT 'not a finding to carry over.';
SELECT  c.name,
        c.value_in_use
FROM sys.configurations AS c
WHERE c.name IN ('clr enabled', 'xp_cmdshell');

PRINT '';
PRINT '--- SQL Server Agent jobs and step types ---';
PRINT 'RDS supports Agent on Standard, Enterprise, and Web editions,';
PRINT 'but only T-SQL job steps replicate to a Multi-AZ secondary, and';
PRINT 'CmdExec, PowerShell, SSIS, and replication steps do not run on';
PRINT 'RDS the way they run on premises. Any non-TSQL step is rework.';
SELECT  j.enabled,
        js.subsystem,
        COUNT(*)                          AS step_count
FROM msdb.dbo.sysjobs AS j
JOIN msdb.dbo.sysjobsteps AS js
  ON js.job_id = j.job_id
GROUP BY j.enabled, js.subsystem
ORDER BY j.enabled DESC, step_count DESC;

PRINT '';
PRINT '--- Linked servers ---';
PRINT 'Linked servers have limited support on RDS. Each row here needs';
PRINT 'a check against the current RDS linked server guidance, and a';
PRINT 'decision about whether the link moves, is replaced by a data';
PRINT 'movement job, or stays on EC2 where linked servers work as usual.';
SELECT  s.name,
        s.product,
        s.provider,
        s.data_source
FROM sys.servers AS s
WHERE s.is_linked = 1
ORDER BY s.name;

PRINT '';
PRINT '--- Log shipping configuration ---';
PRINT 'Log shipping is not supported on RDS for SQL Server. If this';
PRINT 'section returns rows, the HA/DR design must change for RDS';
PRINT '(Multi-AZ, read replicas, or native backup/restore), or the';
PRINT 'workload stays on EC2 where log shipping works as usual.';
SELECT  'primary'                         AS role,
        COUNT(*)                          AS configured_count
FROM msdb.dbo.log_shipping_monitor_primary
UNION ALL
SELECT  'secondary',
        COUNT(*)
FROM msdb.dbo.log_shipping_monitor_secondary;

PRINT '';
PRINT '--- Availability groups ---';
PRINT 'On EC2, availability groups run on a Windows failover cluster';
PRINT 'you build and own. On RDS, Multi-AZ is the managed equivalent';
PRINT 'and the listener and replica behavior are managed, not yours';
PRINT 'to configure. Existing groups do not migrate as-is to RDS.';
SELECT  ag.name                           AS availability_group,
        COUNT(DISTINCT ar.replica_id)     AS replica_count
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar
  ON ar.group_id = ag.group_id
GROUP BY ag.name
ORDER BY ag.name;

PRINT '';
PRINT '--- Database snapshots ---';
PRINT 'Database snapshots are not supported on RDS (instance snapshots';
PRINT 'are a different thing). A snapshot here is a dependency to';
PRINT 'resolve before an RDS move, usually by replacing it with a';
PRINT 'backup/restore point or a reporting copy.';
SELECT  d.name                            AS snapshot_name,
        d.source_database_id,
        DB_NAME(d.source_database_id)     AS source_database
FROM sys.databases AS d
WHERE d.source_database_id IS NOT NULL
ORDER BY d.name;
