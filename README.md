# SQL Server DBA Toolkit

Operational T-SQL for Microsoft SQL Server administration: instance health
checks, backup verification from backup history, and log shipping
monitoring. These are the checks a DBA runs on a schedule and during an
incident, written to be scheduled in SQL Server Agent or run by hand with
the same result either way.

## Who it is for

DBAs who administer SQL Server and want dependable administrative queries
with documented thresholds and no surprises. The log shipping scripts come
from hands-on log shipping administration: primary and secondary monitoring,
backup/copy/restore job health, and latency reporting against the msdb log
shipping tables.

## Layout

```
sqlserver-dba-toolkit/
├── tsql/   -- T-SQL administrative scripts (health check, backups, log shipping)
└── docs/   -- script conventions and the log shipping runbook
```

## Scripts

| Script | What it does |
|---|---|
| `tsql/db_health_check.sql` | Instance overview: version and uptime, database state and recovery model, file space usage, recent backup presence per database, long-running requests, blocking chains |
| `tsql/backup_verification.sql` | Backup currency per database from msdb backup history: last full, differential, and log backup, with age flags against configurable thresholds |
| `tsql/log_shipping_status.sql` | Log shipping health: primary and secondary status from the msdb log shipping monitor tables, last backup/copy/restore file and times, latency in minutes |

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
and instance health checks that separate configuration facts from current
activity.

## Background

Independent portfolio project. Scripts were written from standard SQL
Server administration practice, not taken from any production system or
employer environment.
