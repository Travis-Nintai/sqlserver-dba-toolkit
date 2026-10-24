# Always On availability groups: monitoring concepts

A reference for the queries and judgments behind availability group
health. This doc assumes the groups already exist; it is about knowing
they are healthy and knowing quickly when they are not. The queries
below are meant to be run by hand or pasted into a monitoring job, and
each says what it reads.

## What healthy looks like

An availability group is healthy when every replica reports the role it
should hold, synchronization health is HEALTHY on all replicas, every
database is SYNCHRONIZED (synchronous commit) or SYNCHRONIZING without a
growing queue (asynchronous commit), and the secondary could take over
without surprises. "Without surprises" is the part people skip: a
synchronous secondary that is healthy but far behind on redo is not
ready for failover, it is just not alarming yet.

## Replica state at a glance

```sql
SELECT ag.name                                   AS availability_group,
       ar.replica_server_name,
       ars.role_desc,
       ars.operational_state_desc,
       ars.synchronization_health_desc,
       ars.connected_state_desc,
       ars.last_connect_error_description,
       ars.last_connect_error_timestamp
FROM sys.dm_hadr_availability_replica_states AS ars
JOIN sys.availability_replicas AS ar
  ON ar.replica_id = ars.replica_id
JOIN sys.availability_groups AS ag
  ON ag.group_id = ars.group_id
ORDER BY ag.name, ars.role_desc DESC;
```

Read this first in any incident. `role_desc` tells you who is primary
right now, which matters because after an automatic failover the old
primary is not the primary anymore and assumptions kill. Anything other
than HEALTHY in `synchronization_health_desc` deserves the next query,
not a wait-and-see.

## Per-database sync depth

Replica-level health is a summary; the queues live per database:

```sql
SELECT DB_NAME(drs.database_id)                  AS database_name,
       ar.replica_server_name,
       drs.synchronization_state_desc,
       drs.synchronization_health_desc,
       drs.log_send_queue_size                   AS log_send_queue_kb,
       drs.log_send_rate                         AS log_send_kb_per_sec,
       drs.redo_queue_size                       AS redo_queue_kb,
       drs.redo_rate                             AS redo_kb_per_sec,
       drs.secondary_lag_seconds
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_replicas AS ar
  ON ar.replica_id = drs.replica_id
ORDER BY drs.log_send_queue_size DESC, drs.redo_queue_size DESC;
```

How to read it:

- **log_send_queue_size** growing on the primary side means log records
  are waiting to reach the secondary: usually network or a secondary
  that cannot keep up. Divide by `log_send_rate` for a rough time to
  drain.
- **redo_queue_size** growing on the secondary means the secondary
  received the log but has not applied it: usually an underpowered
  secondary or redo blocked behind something on that replica.
- **secondary_lag_seconds** is the honest number for RPO conversations.
  On synchronous commit it should stay near zero; sustained lag there
  means the primary is waiting on the secondary and the application
  feels it as slower commits.
- A database stuck in NOT SYNCHRONIZING while the replica says
  connected is the classic "the AG looks fine" trap. This query shows
  it; the replica summary does not.

## Failover readiness

Before any planned failover, confirm three things beyond green health:

1. The intended new primary's databases are SYNCHRONIZED (synchronous
   commit) or the redo queue is drained (asynchronous commit).
2. The cluster quorum is healthy. `sys.dm_hadr_availability_replica_cluster_states`
   shows each replica's view; a failover into a quorum problem trades
   one outage for another.
3. The listener resolves and the application connection string actually
   uses it. Failovers fail more often in DNS and connection strings
   than in SQL Server.

For automatic failover specifically: it requires synchronous commit,
healthy synchronization, and the configured failover conditions. An
automatic failover that did not happen is usually one of those three
not being true, not a SQL Server bug. Check them in that order.

## What to alert on

If these feed a monitoring system, the short list that earns pages:

- Any replica `synchronization_health_desc` not HEALTHY.
- Any database `synchronization_state_desc` = NOT SYNCHRONIZING.
- `log_send_queue_size` or `redo_queue_size` above the site's threshold
  for more than the site's tolerance (pick both numbers from your own
  RPO, not from a blog).
- Role change on the primary replica outside a maintenance window
  (unexpected failover happened; find out why before assuming it is
  fine).
- Cluster quorum warnings from the Windows side; SQL Server cannot
  outvote a lost quorum.

## Relationship to the rest of this repo

- Log shipping (`tsql/log_shipping_status.sql`) and availability groups
  solve overlapping problems differently. Log shipping is simpler,
  cheaper, and slower to fail over; availability groups are faster and
  more automatic with more moving parts to monitor. The runbook for log
  shipping lives in `docs/log-shipping-runbook.md`; this doc is its
  Always On counterpart.
- `tsql/wait_statistics.sql`: on a synchronous primary, a lagging
  secondary surfaces as `HADR_SYNC_COMMIT` waits. When that wait type
  climbs the top-waits list, come back to the queue query above.

## Honesty note

These queries were syntax and logic reviewed against the documented
DMV schemas and were not executed against a live availability group
during development. The concepts reflect hands-on Always On
administration; validate the queries against your own replicas before
scheduling them, the same as any administrative script new to an
environment.
