# Database file and capacity checks

`tsql/database_files_capacity.sql` is the capacity check for an instance:
how much room each database has left inside its files, whether
autogrowth is configured sanely, how much room is left on the disks the
files live on, and how many virtual log files each log has. Run it when
you take over an instance, after a large data load, before a maintenance
window that will grow the database, and on a schedule so a slow fill is
visible weeks before it becomes an outage.

The script is read-only. It reports facts and flags the ones that need a
decision; it never grows a file, shrinks a log, or changes a setting.

## What each section means

### 1. Capacity summary per database

One row per database: data size, data used, data free, and free percent
inside the data files, plus log size and log used percent. The `notes`
column flags the databases that need attention: LOW FREE SPACE when the
data files are below the threshold (default 10 percent free), LOG NEARLY
FULL when the log is above the threshold (default 80 percent used),
PERCENT GROWTH when any file in the database grows by percent, and
UNLIMITED MAX SIZE when any file has no maximum size.

Free space inside the files is not the same as free space on the disk.
A database can be out of room in its files while the disk has space, in
which case autogrowth fixes it, or the disk can be full while the files
still have free space, in which case autogrowth cannot help. Section 1
answers the first question; section 3 answers the second. Read them
together before deciding what to fix.

Only ONLINE databases are measured for space used. A database that is
restoring, offline, or otherwise unavailable still appears in the file
inventory in section 2 with its configured sizes, but its used space is
not measured. If the login cannot read a database, the script prints a
line naming it and moves on.

### 2. File inventory

Every file on the instance: logical name, type, physical path, size,
used and free space for data files, growth setting, maximum size, and
state. This is the section to read when a specific database is flagged
in section 1: it shows which file is the problem, where it lives, and
what its growth settings are.

Used and free space are shown for data files only. Log file usage is
reported in section 1 from `sys.dm_db_log_space_usage`, because
FILEPROPERTY does not measure log files.

A file in RECOVERY_PENDING, SUSPECT, or OFFLINE state shows up here
with its configured size. That is a different problem from capacity,
but this section is often where it is first noticed, so do not ignore a
state that is not ONLINE.

### 3. Volume free space

One row per volume that holds a database file, with total size, free
space, and free percent. A volume shared by several databases appears
once, which is the point: several databases on one volume are one
capacity risk, not several. The LOW FREE SPACE flag uses the threshold
at the top of the script (default 20 GB free).

When a volume is flagged, the fix depends on what is on it. A volume
holding only log files needs log backups or a log file move. A volume
holding data files needs either more disk, a file move, or space freed
inside the files. Shrinking a data file to free disk space is usually
the wrong answer: it fragments the file and the space is normally needed
again soon.

### 4. Autogrowth audit

Files whose growth settings need attention. An empty result means no
autogrowth concerns were found. Four findings are flagged:

- AUTOGROWTH OFF: the file never grows. The database fails with a file
  full error when the file fills, even if the disk has room. This is
  correct only for a file that is deliberately sized and monitored, and
  then only with an alert on the free space in section 1.
- PERCENT GROWTH: the growth amount increases with every growth event.
  Ten percent of a 500 GB file is 50 GB in a single growth, which stalls
  the writes that triggered it and can take a long time on slow storage.
  Fixed MB growth is the usual answer.
- SMALL GROWTH INCREMENT: a fixed growth of less than 64 MB. The file
  grows often, and each growth event is a small stall and a new extent
  allocation. Size the increment to the database: 64 MB to 1 GB is a
  common range, larger for large databases.
- UNLIMITED MAX SIZE: the file can grow until the disk is full. This is
  the default and it is not always wrong, but it means the disk, not
  the database, is the limit, so it belongs next to the volume section.
  Set a maximum size deliberately when the disk is shared with other
  databases or other applications.

Growth settings are a safety net, not a sizing strategy. The right
answer for a database that grows steadily is to pre-size the files for
the expected growth, during a maintenance window, and let autogrowth
cover the unexpected. A file that grows under load is a file that stalls
writes while it grows.

### 5. Virtual log file counts

One row per database: total VLFs, active VLFs, total log size, and
average VLF size. The HIGH VLF COUNT flag uses the threshold at the top
of the script (default 100). High counts slow recovery, restore, and
log backup, because each of those operations walks the VLF list. The
usual cause is a log that grew in many small increments, which is why
this section sits next to the autogrowth audit: fix the growth setting
first, then fix the count.

Reducing a high VLF count means shrinking the log and regrowing it in
sized increments, which is a planned operation, not something to do
while the log is busy. Shrink in steps, regrow in a few large chunks
(for example, four to eight growths of equal size), and confirm the new
count with this script afterward. Do not shrink a log that is waiting on
a log backup, replication, or a long-running transaction: the shrink
will not work, and the wait is the real problem. A log with a high VLF
count and a small number of active VLFs is a recovery-time problem, not
a space problem, so do not treat it like one.

This section needs SQL Server 2016 SP2 or later, because it reads
`sys.dm_db_log_info`. On earlier builds the script prints a note and
moves on instead of failing. On those builds, run DBCC LOGINFO in each
database for the same information: one row per VLF, Status 2 is active.

## Scheduling this check

Schedule `database_files_capacity.sql` as its own Agent job, weekly on
a quiet instance, daily on one that grows fast, with the output written
to a file or captured in the job history. Set the thresholds at the top
of the script to match the instance: a lower `@VolumeFreeWarnGB` on a
small development instance, a higher one on a production volume that
holds several large databases, a lower `@VlfWarnCount` if recovery time
objectives are tight.

Run it by hand after any large data load, index rebuild, or restore,
and before any maintenance window that will grow the database. A
capacity check run after the load tells you what the load cost; run
before the window, it tells you whether the window will fit.

## Troubleshooting

| Symptom | Likely cause | First check |
|---|---|---|
| A database is out of free space in its files | Growth under load, or a file that never grew | Section 1 for the database, section 2 for the file, section 4 for its growth settings |
| Autogrowth is on but the database still fails to grow | The disk is full, or the file hit its maximum size | Section 3 for the volume, section 2 for the max size |
| Writes stall periodically | Small or percent growth events under load | Section 4; look for SMALL GROWTH INCREMENT or PERCENT GROWTH on the busy database |
| A file grows in large jumps | Percent growth on a large file | Section 4; switch the file to a fixed MB increment sized to the database |
| Recovery or restore is slow | High VLF count in the log | Section 5; check the growth history that produced the count in section 4 |
| A log will not shrink | The log is waiting on a backup, replication, or an open transaction | Section 1 log used percent; `sys.databases.log_reuse_wait_desc` for the wait reason |
| The script reports a database it cannot read | The login lacks access to that database | The printed line names the database; grant the monitoring login access or accept the gap |

## Relationship to the other scripts

TempDB file layout is covered in detail by `tsql/tempdb_health.sql`,
which reads TempDB space usage by category and current PAGELATCH
contention. This script includes TempDB in its sections, so a TempDB
capacity problem shows up here too, but the layout and contention detail
lives in the TempDB script. Backup growth shows up indirectly here: a
database whose data files grow steadily will need larger backups, which
is what `tsql/backup_verification.sql` checks from msdb history. Index
rebuilds grow the log, so a maintenance window that rebuilds large
indexes is a good reason to run this check first; the rebuild candidates
are in `tsql/index_maintenance_candidates.sql`. Log shipping secondaries
should match the primary in file sizes and growth settings, so run this
script on both sides and compare; log shipping health itself is in
`tsql/log_shipping_status.sql`. On RDS SQL Server, files live on managed
storage and volume free space is reported differently; see
`docs/aws-hosted-sql-server.md` for what RDS changes.
