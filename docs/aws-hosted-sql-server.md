# SQL Server on AWS: RDS or EC2

A decision guide for moving a SQL Server workload to AWS, written for
the DBA who has to defend the choice afterward. The short version:
RDS for SQL Server trades control for managed operations, EC2 keeps
full control and full responsibility. Most workloads fit one of the
two cleanly once the blockers are listed; the expensive mistakes come
from assuming RDS is "SQL Server in the cloud" with nothing removed.

Run `tsql/hosting_inventory.sql` on the current instance first. This
doc explains what its output means. AWS changes supported versions,
features, and limits over time, so treat the specifics here as the
shape of the decision and verify the current list against the AWS
documentation for the version and edition you plan to run before
committing to a design.

## The two hosts, plainly

**RDS for SQL Server** is a managed database instance. AWS provisions
the host, patches the engine, takes automated backups, and handles
failover for Multi-AZ deployments. You get no operating system access,
no RDP, no file system access beyond the managed S3 integration folder,
and no sysadmin role. The master user has broad but bounded privileges.
You manage databases, logins, jobs, and parameters through T-SQL and
the RDS API, not through the OS.

**SQL Server on EC2** is SQL Server on a Windows server you own, in an
AWS account. You choose the AMI (license-included or bring your own
license), the instance type, the EBS volumes, and the patching
schedule. Everything that works on premises works here, including
log shipping, availability groups on a failover cluster you build,
CLR, xp_cmdshell, and SSIS/SSRS/SSAS co-hosted the usual way. You
also own everything that breaks: OS patching, cluster health, storage
growth, backup retention, and failover testing.

The decision is therefore not "managed versus unmanaged" in the
abstract. It is: does this workload depend on anything RDS removes?
If yes, the answer is EC2, or rework first and RDS second. If no, RDS
usually wins on operating cost, because the managed backup, patching,
and failover work is real work you stop doing by hand.

## What RDS removes or limits

These are the findings from the inventory script that change the
answer. Each one is documented in the AWS RDS SQL Server feature
support page; check that page for the version you are targeting.

- **Log shipping is not supported on RDS.** This repo's log shipping
  monitor (`tsql/log_shipping_status.sql`) and runbook describe an
  on-premises and EC2 design. On RDS, the replacement is Multi-AZ for
  availability, read replicas or native backup/restore for reporting
  and DR copies, not log shipping. If log shipping is load-bearing
  for your DR story, that alone points to EC2.
- **No sysadmin, no OS access.** xp_cmdshell, extended stored
  procedures, server-level triggers, Service Broker endpoints, and
  T-SQL endpoints (CREATE ENDPOINT) are not available. Database
  snapshots are not supported; RDS instance snapshots are a different
  mechanism with different semantics. Maintenance plans, Policy-Based
  Management, the Performance Data Collector, and PolyBase are not
  available in the managed form.
- **CLR is limited.** SAFE assemblies on 2016 and earlier; not
  supported on 2017 and later. Any UNSAFE or EXTERNAL_ACCESS assembly
  is rework or an EC2 reason.
- **FILESTREAM and file tables are not supported.** A workload that
  stores documents through FILESTREAM needs a different storage design
  before RDS.
- **SSIS, SSRS, and SSAS are not co-hosted the on-premises way.**
  SSIS has a separate supported path on RDS for some versions and
  editions; SSRS and SSAS belong on EC2 or on their own hosts. Do not
  plan a lift of a combined engine plus reporting box into one RDS
  instance.
- **Linked servers have limited support.** Check the current RDS
  linked server guidance per provider before assuming a link moves.
  In practice, cross-instance queries often become data movement jobs
  (DMS, SSIS on its own host, or application-level reads) on RDS.
- **Database Mail and Agent alerts/operators are not available
  through RDS Agent.** Agent itself is supported on Standard,
  Enterprise, and Web editions for T-SQL jobs, but CmdExec and
  PowerShell steps do not run, job steps that depend on Database Mail
  do not notify, and you cannot start, stop, or restart Agent by hand.
  Schedule jobs outside the RDS maintenance and backup windows, or
  expect interruptions. Multi-AZ Agent job replication covers T-SQL
  steps in specific job categories only; turn it on explicitly and
  verify the jobs that matter actually replicate.
- **Time zone is set at instance creation and cannot be changed
  afterward.** A restore across time zones is possible but needs an
  application audit. Get this right at provisioning time; it is not a
  setting you fix later.
- **Database count and storage maximums vary by instance class and
  edition.** Do not assume one large instance consolidates every
  database from a large on-premises host. Size from the inventory
  script's file totals, not from the old host's disk size.

## Backups and recovery: the biggest behavioral change

On premises and on EC2, backups are files you control: where they go,
how long they are kept, and how you restore them. On RDS, backups are
a managed service with a native escape hatch, and the two must not be
confused.

**Automated backups and snapshots.** RDS takes automated backups on
its schedule and keeps them for the configured retention period.
Point-in-time recovery restores to a new instance, not in place over
the existing one. DB snapshots are manual, instance-level, and survive
until you delete them. Neither shows up in msdb backup history the way
an on-premises backup does, so this repo's
`tsql/backup_verification.sql`, which reads msdb backupset, does not
directly verify RDS automated backups. On RDS, backup health is
checked through the RDS console or API (latest restorable time,
snapshot status), not through msdb. That is a monitoring change to
plan, not a gap to paper over by running the old script and trusting
a blank result.

**Native backup and restore through S3.** RDS supports native
`.bak` restores and backups through S3 buckets in the same AWS Region
as the instance, using the `rds_backup_database` and
`rds_restore_database` procedures. This is the migration path in both
directions and the DR copy path: restore a native backup from
on-premises into RDS, or back a database out of RDS to S3 and restore
it elsewhere. Know its limits before depending on it: same-Region
buckets only, a per-file size limit that makes large databases
multi-file backups, a cap on concurrent backup files, and no native
log backups taken from RDS itself. On a Multi-AZ instance, only
databases in FULL recovery can be restored this way. Test the restore
of your largest database before migration day; a backup that restores
in the lab and a backup that restores at production size are
different claims.

**Recovery model discipline matters more on RDS, not less.** A
database left in SIMPLE recovery cannot take log backups and cannot
be restored onto a Multi-AZ instance by native restore. The
inventory script flags recovery models for exactly this reason:
fix them before migration, not during it.

## Availability: Multi-AZ is not your availability group

RDS Multi-AZ is the managed availability story. Depending on edition
and version, it is implemented with database mirroring, Always On
availability groups, or block-level replication, and the details that
matter (whether the secondary accepts reads, whether the listener
supports Kerberos, whether a database can be renamed while Multi-AZ
is on, whether an instance can be stopped) vary by implementation.
Read the Multi-AZ limitations page for your version before promising
behavior. What does not vary: failover is managed, the standby is not
a reporting replica you can query (except in the read replica
configurations RDS explicitly supports), and Agent jobs need the
replication step above to survive failover.

On EC2, availability groups are yours to build: a Windows Server
failover cluster, a listener, synchronous or asynchronous commit per
database, and the monitoring in
`docs/always-on-availability-groups.md`, which applies directly. The
trade is control for effort: you get readable secondaries, custom
failover conditions, and cluster quorum decisions, and you own the
patching and testing of all of it.

Read replicas deserve their own line. RDS read replicas serve read
traffic and offload reporting, but they are not a second Multi-AZ
standby and they are not a DR answer by themselves unless you have
tested promotion and know the replication lag your application
tolerates. Measure lag with the same seriousness this repo measures
log shipping latency: a replica that is usually current is not the
same as a replica that is current when it matters.

## What still works the same

Not everything changes, and the unchanged parts are why the rest of
this repo stays useful on either host:

- DMV-based monitoring (blocking, waits, TempDB, index candidates)
  works on RDS subject to the permissions of the login you run it as.
  The queries do not assume OS access. Test them with the RDS master
  user, not with a sysadmin account you will not have there.
- Index and statistics maintenance guidance is the same. Agent can
  run the T-SQL maintenance jobs on RDS; the schedule and the
  notification path are what change.
- Always On concepts (queues, redo, lag, failover readiness) transfer
  to EC2 directly and to RDS Multi-AZ as the mental model, even
  though the knobs are managed on RDS.
- Recovery model, backup currency, and latency thinking transfer
  everywhere. Only the mechanism that produces the backup changes.

## Migration paths, in order of preference

1. **Native backup/restore through S3.** Simplest for a cutover with
   a downtime window: full backup on premises, restore into RDS,
   verify, cut over. Fits most single-database moves and any move
   where a window is acceptable.
2. **AWS Database Migration Service (DMS).** For minimal-downtime
   moves and for continuous replication into RDS during a phased
   cutover. Validate data types, LOB handling, and what DMS does not
   replicate (it moves data, not Agent jobs, logins, or server-level
   objects; those migrate separately). DMS is a data movement tool,
   not a whole-server migration.
3. **Transactional replication or log-based tooling on EC2.** When
   the target is EC2 and near-zero downtime matters, the on-premises
   replication and log shipping techniques in this repo apply, because
   the target is a full SQL Server you control.
4. **Backup/restore plus manual object migration.** Always the
   fallback: script logins (with SIDs if you want users to map
   cleanly), Agent jobs, linked servers, and server-level objects
   separately from the database restore, and verify each category
   after restore. The inventory script's sections are, in effect,
   the checklist for this step.

Whichever path you pick, migrate logins and Agent jobs as their own
workstream with their own verification. A database that restores
perfectly with no logins and no jobs is not a migrated system.

## Sizing and cost notes

- **RDS:** instance class sets compute and memory together; you do
  not pick them independently. Storage is provisioned per instance
  with IOPS characteristics by storage type (gp3 versus io2 and
  provisioned IOPS). License-included versus bring-your-own-license
  changes the bill substantially for Standard and Enterprise; model
  both before choosing. Multi-AZ doubles the instance cost for the
  standby; budget it as part of availability, not as an optional
  extra discovered later.
- **EC2:** instance, EBS, Windows licensing, and SQL Server licensing
  are separate lines, and you pay for the cluster nodes and the
  standby whether they are busy or not. The hidden cost is operations:
  patching, cluster maintenance, backup management, and failover
  testing are staff time, not line items, and they recur.
- **Both:** data transfer out of AWS, cross-Region copies, and S3
  storage for native backups are easy to forget in an estimate. A
  migration estimate that omits the S3 staging for the largest
  database is an estimate that will be wrong on migration week.

## Security and access, briefly

RDS instances live in a VPC with security groups controlling the
database port; there is no public file share, no RDP, and no local
admin to social-engineer. Use IAM database authentication where it
fits, or SQL logins with secrets managed outside the repository,
never in it. On EC2, the same VPC and security group discipline
applies, plus OS hardening, Windows patching, and domain or local
account management for the service accounts. In both cases, the
connection strings in examples in this repo are fictional
(`db.example.local`); real endpoints never belong in a repository.

## Decision checklist

Before choosing, you should be able to answer yes or no to each of
these from the inventory script, not from memory:

- Does anything depend on log shipping, FILESTREAM, CLR beyond SAFE,
  xp_cmdshell, server triggers, or endpoints? Any yes points to EC2
  or rework.
- Are all Agent jobs T-SQL steps, or can the non-T-SQL steps move to
  another host or service? If not, EC2 or a redesign.
- Are all databases in FULL recovery, or is SIMPLE recovery a
  deliberate choice you can defend for the databases that have it?
- Is the total database size, file count, and database count within
  the RDS limits for the instance class and edition you priced?
- Is the time zone decision made, and is the maintenance and backup
  window compatible with your job schedule?
- Has the largest database been restored through the chosen path
  (native S3 restore or DMS) and verified, not just backed up?
- If RDS: is Multi-AZ on, are Agent jobs replicating, and is backup
  health monitored through RDS (latest restorable time), not msdb?
- If EC2: is the failover cluster built, patched, and tested, and is
  someone on call for the OS layer, not just the database?

If every answer is clean for RDS, take RDS and stop paying the EC2
operations tax. If any answer is a hard blocker, take EC2 without
apology: a managed service that cannot run your workload is not
cheaper, it is a migration that fails in production instead of in
planning.

## Sources to verify against

AWS documentation changes with versions and editions; verify the
current statements for your target before relying on them:

- Features not supported and features with limited support, RDS for
  SQL Server:
  https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/SQLServer.Concepts.General.FeatureNonSupport.html
- Importing and exporting SQL Server databases using native backup
  and restore:
  https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/SQLServer.Procedural.Importing.html
- Microsoft SQL Server Multi-AZ deployment limitations, notes, and
  recommendations (AWS documentation, RDS user guide).

## Honesty note

This doc is architecture guidance and a migration checklist, not a
record of a migration performed. It was written from the AWS
documentation and standard SQL Server administration practice, and
the inventory script was syntax and logic reviewed, not executed
against a live SQL Server or RDS instance during development. Validate
every limit against the AWS documentation for your version and
edition, and validate every inventory finding against your own
instance before acting on it.
