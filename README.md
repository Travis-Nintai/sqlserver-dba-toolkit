# SQL Server DBA Toolkit

Operational T-SQL for Microsoft SQL Server administration: instance health
checks, backup verification from backup history, log shipping
monitoring, blocking and deadlock diagnosis, wait statistics, index and
statistics maintenance guidance, TempDB health, Always On
availability group monitoring concepts, and AWS hosting guidance
(RDS versus EC2) with an inventory script to feed that decision.
These are the checks a DBA runs
on a schedule and during an incident, written to be scheduled in SQL
Server Agent or run by hand with the same result either way.

## Who it is for

DBAs who administer SQL Server and want dependable administrative queries
with documented thresholds and no surprises. The log shipping scripts come
from hands-on log shipping administration: primary and secondary monitoring,
backup/copy/restore job health, and latency reporting against the msdb log
shipping tables.

## Layout

```
sqlserver-dba-toolkit/
├── tsql/   -- T-SQL administrative scripts (health, backups, log shipping,
│               blocking/deadlocks, waits, indexes, TempDB)
└── docs/   -- script conventions, runbooks, and maintenance guidance
```

## Scripts

| Script | What it does |
|---|---|
| `tsql/db_health_check.sql` | Instance overview: version and uptime, database state and recovery model, file space usage, recent backup presence per database, long-running requests, blocking chains |
| `tsql/backup_verification.sql` | Backup currency per database from msdb backup history: last full, differential, and log backup, with age flags against configurable thresholds |
| `tsql/log_shipping_status.sql` | Log shipping health: primary and secondary status from the msdb log shipping monitor tables, last backup/copy/restore file and times, latency in minutes |
| `tsql/blocking_and_deadlocks.sql` | Blocking chains with head blockers, sessions holding open transactions without active requests, and recent deadlock graphs from the system_health session |
| `tsql/wait_statistics.sql` | Top wait types since startup with signal/resource split, plus sessions waiting right now; idle waits excluded |
| `tsql/index_maintenance_candidates.sql` | Fragmented index candidates with reorganize/rebuild guidance, and stale statistics with high modification counts (reports only) |
| `tsql/tempdb_health.sql` | TempDB file layout, space usage by category, top consumers, version store transactions, and current PAGELATCH contention on TempDB pages |
| `tsql/hosting_inventory.sql` | Read-only inventory for an AWS hosting decision: edition and version, database recovery models and flags, Agent job step types, linked servers, log shipping and availability group configuration, snapshots, CLR and xp_cmdshell settings |

## Docs

| Doc | What it covers |
|---|---|
| `docs/script-conventions.md` | Conventions every script follows |
| `docs/log-shipping-runbook.md` | Log shipping troubleshooting runbook |
| `docs/index-maintenance.md` | Reorganize vs rebuild, statistics strategy, and how to schedule maintenance |
| `docs/always-on-availability-groups.md` | Availability group monitoring: replica state, sync queues and lag, failover readiness, what to alert on |
| `docs/aws-hosted-sql-server.md` | RDS versus EC2 decision guide: what RDS removes or limits, backup and recovery behavior, Multi-AZ versus availability groups, migration paths, sizing and cost notes, decision checklist |

Health check with defaults:

```
sqlcmd -S db.example.local -E -i tsql\db_health_check.sql
```

Backup verification with defaults (flags databases with no full backup in
24 hours, no differential in 48, no log backup in 1 hour). Thresholds are
DECLARE variables at the top of the script; edit them there:

```
sqlcmd -S db.example.local -E -i tsql\backup_verification.sql
```

Log shipping status:

```
sqlcmd -S db.example.local -E -i tsql\log_shipping_status.sql
```

Run the log shipping script on the monitor server if you have one, or on
the primary or secondary: the monitor tables live wherever log shipping was
configured to record them, and each script header says what it reads.

Blocking and deadlock report:

```
sqlcmd -S db.example.local -E -i tsql\blocking_and_deadlocks.sql
```

Wait statistics (cumulative since startup plus currently waiting sessions):

```
sqlcmd -S db.example.local -E -i tsql\wait_statistics.sql
```

Index and statistics maintenance candidates (run in the target database;
reports only, changes nothing):

```
sqlcmd -S db.example.local -d <database> -E -i tsql\index_maintenance_candidates.sql
```

TempDB health:

```
sqlcmd -S db.example.local -E -i tsql\tempdb_health.sql
```

AWS hosting inventory (run on the current instance before migration
planning; read the output alongside `docs/aws-hosted-sql-server.md`):

```
sqlcmd -S db.example.local -E -i tsql\hosting_inventory.sql
```

## Assumptions

- SQL Server 2016 or later. The scripts use DMVs and catalog views
  available since then (`sys.dm_exec_requests`, `sys.dm_os_sys_info`,
  `msdb.dbo.backupset`, the `msdb.dbo.log_shipping_monitor_*` tables).
- Run as a login that can read the DMVs (`VIEW SERVER STATE`) and msdb
  backup and log shipping history. A sysadmin works; a dedicated monitoring
  login with those grants is the better production answer.
- Log shipping monitoring assumes log shipping was configured through the
  standard SQL Server tooling, which is what populates the monitor tables.
- Server and database names in examples are fictional.

## Testing status

These scripts were syntax and logic reviewed against the documented SQL
Server catalog and DMV schemas. They were not executed against a live SQL
Server instance during development, because no SQL Server engine is
available in the development environment. Headers in each script say the
same thing. Treat first use on a real instance the way you would any new
administrative script: run it, read the output against what you know about
the instance, and confirm it agrees.

## Safety notes

- Everything here is read-only. The scripts query DMVs, catalog views, and
  msdb history tables; they change nothing.
- Backup and log shipping findings are prompts to investigate, not
  instructions to act. A database with no log backups may be in SIMPLE
  recovery by design; the script flags the absence, the DBA judges it.
- Never commit credentials, server names, or environment-specific details
  alongside these scripts.

## What this demonstrates

SQL Server operations as practiced: backup verification from msdb history
rather than job success alone (a backup job can succeed and still write
nothing useful), log shipping monitored from the monitor tables with
latency in minutes so a drifting secondary is visible before it matters,
blocking diagnosed as chains with the head blocker identified rather
than as isolated blocked sessions, waits reported with the signal and
resource split so CPU pressure and resource pressure are not confused,
and instance health checks that separate configuration facts from current
activity. The AWS hosting material applies the same discipline to a
platform decision: inventory the blockers first (log shipping, CLR,
Agent step types, recovery models), then choose RDS or EC2 on evidence
rather than on the assumption that a managed instance runs everything
an on-premises instance runs.

## Background

Independent portfolio project. Scripts were written from standard SQL
Server administration practice, not taken from any production system or
employer environment.
