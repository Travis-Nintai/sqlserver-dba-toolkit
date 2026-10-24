# Index and statistics maintenance

How this repo approaches index fragmentation and stale statistics: what the
candidate script reports, what to do with the findings, and where the
judgment calls are. The companion script
`tsql/index_maintenance_candidates.sql` is read-only; maintenance itself is
a scheduling and edition decision, not something a reporting script should
make for you.

## What fragmentation means here

`sys.dm_db_index_physical_state` in `SAMPLED` mode reports logical
fragmentation: the percentage of pages out of physical order for the
index. It is a reasonable proxy for scan-heavy workloads and a weak one
for pure seek workloads. Treat the suggested action as a starting point,
not a verdict.

## Reorganize vs rebuild

- **REORGANIZE** (at or above 10 percent, below 30): defragments the leaf
  level in place, always online, minimally logged. Safe to run during the
  day for most workloads; still generates log, so watch log space on
  databases in FULL recovery.
- **REBUILD** (at or above 30 percent): recreates the index. In Enterprise
  edition this can run `WITH (ONLINE = ON)`; in Standard edition a
  rebuild is offline for the duration, which means it belongs in a
  maintenance window. Rebuild also lets you set `FILLFACTOR` and,
  as a side effect, updates the index's statistics with a full scan.

Practical thresholds vary. High-write tables may benefit from a lower
rebuild threshold; mostly-static reference tables may never need either.
The script exposes both thresholds as DECLARE variables so the policy
lives in one place.

## What the script deliberately skips

- **Heaps** (`index_id = 0`): fragmentation guidance for heaps is
  different (rebuild the heap with `ALTER TABLE ... REBUILD`, or add a
  clustered index). Heaps with heavy forwarding deserve attention, but
  they do not fit the reorganize/rebuild ladder, so the script excludes
  them rather than mislabeling them.
- **Tiny indexes** (under 1000 pages by default): maintenance on small
  indexes costs more than it saves. Tune `@MinPages` down for small
  databases where it makes sense.
- **LOB and row-overflow allocation units**: the script reports
  `IN_ROW_DATA` only, to keep the fragmentation numbers comparable.

## Statistics

Stale statistics are the quieter half of this story. A plan built on
statistics that describe the table as it was a month ago will misjudge
cardinality, and misjudged cardinality is how good queries get bad plans.

- Auto-update statistics handles the common case. The script's stale
  statistics section exists for the cases it does not: auto-update
  disabled, trace flag behavior, ascending-key columns where new values
  fall outside the histogram, and tables where the modification counter
  climbs faster than the auto-update threshold fires.
- The section lists statistics older than `@StaleStatsDays` whose
  modification counter exceeds `@MinModifications`, with the last sample
  percentage so you can judge whether a `FULLSCAN` update is warranted or
  a default sample will do.
- Updating statistics is cheap compared to rebuilding indexes; when a
  query regresses and the plan looks stale, check statistics before
  touching indexes.

## Scheduling maintenance

Options, in order of how much you want to own:

1. **A community maintenance solution** (the well-known index and
   statistics maintenance scripts in the SQL Server community): the
   pragmatic default. Parameterized, logged, widely understood by the
   next DBA.
2. **Maintenance plans**: fine for simple cases, opaque when they are
   not. They rebuild everything on a schedule whether it needs it or
   not, which wastes log and time on large databases.
3. **Custom Agent jobs** driven by the candidate script: most control,
   most ownership. Reasonable when maintenance policy differs sharply
   between databases.

Whichever you choose, the policy questions are the same: which window,
which edition (online rebuild available or not), what FILLFACTOR for
high-write tables, and how you will know it ran (job history and the
candidate script the next morning, not assumptions).

## Reading list within this repo

- `tsql/index_maintenance_candidates.sql`: the candidate report.
- `docs/script-conventions.md`: why thresholds are DECLARE variables
  and why scripts report rather than act.
- `tsql/wait_statistics.sql`: when `PAGEIOLATCH` waits dominate, the
  answer is often storage or memory pressure, not fragmentation; check
  before rebuilding.
