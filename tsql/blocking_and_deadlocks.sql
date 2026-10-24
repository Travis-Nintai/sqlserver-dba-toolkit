/* ============================================================================
   blocking_and_deadlocks.sql -- blocking chains and recent deadlock evidence

   Purpose:
     Find who is blocking whom right now, and pull the most recent deadlock
     graphs captured by the system_health extended event session. Blocking
     is the first thing to check when an application reports timeouts; the
     deadlock report answers the follow-up question of what actually
     deadlocked and which session was chosen as the victim.

     Run this on the server where the blocking or the deadlock occurred.
     The blocking section reads sys.dm_exec_requests, which only sees
     sessions with an active request; a second section lists sessions
     holding open transactions without an active request, because a
     sleeping session with an open transaction is a classic hidden
     blocker.

   Usage (sqlcmd):
     sqlcmd -S <server> -E -i blocking_and_deadlocks.sql

   Thresholds (DECLARE variables below):
     @BlockingDurationSec  Only report blocking that has lasted at least
                           this long. Chain heads are always reported.
                           Default 30 seconds.
     @RecentDeadlocks      How many recent deadlock events to return.
                           Default 5.

   Compatibility:
     SQL Server 2016 or later. Uses sys.dm_exec_requests,
     sys.dm_exec_sessions, sys.dm_tran_session_transactions,
     sys.dm_tran_active_transactions, and the system_health session
     (xml_deadlock_report event), which is on by default. The deadlock
     graph query follows the documented system_health pattern. Reviewed
     against the documented DMV and extended event schemas. Not executed
     against a live SQL Server instance during development; see the
     README testing status.

   Requires:
     VIEW SERVER STATE.

   Safety:
     Read-only.
   ============================================================================ */

SET NOCOUNT ON;

DECLARE @BlockingDurationSec int = 30;
DECLARE @RecentDeadlocks     int = 5;

PRINT '================================================================';
PRINT ' Blocking and deadlock report';
PRINT ' Server        : ' + @@SERVERNAME;
PRINT ' Blocking shown after ' + CAST(@BlockingDurationSec AS nvarchar(10))
      + ' seconds; chain heads always shown';
PRINT '================================================================';

PRINT '';
PRINT '--- Blocking chains (head blocker first, then each blocked session) ---';
PRINT 'head_blocker: the session at the top of the chain; fix that one first.';
;WITH BlockingChain AS (
    -- Anchor: sessions that block others but are not themselves blocked
    SELECT  r.session_id,
            r.blocking_session_id,
            0 AS chain_level,
            CAST(r.session_id AS varchar(4000)) AS chain_path
    FROM sys.dm_exec_requests AS r
    WHERE r.session_id > 50
      AND r.blocking_session_id = 0
      AND EXISTS ( SELECT 1
                   FROM sys.dm_exec_requests AS blocked
                   WHERE blocked.blocking_session_id = r.session_id )
    UNION ALL
    -- Recursive: each session blocked by a session already in the chain
    SELECT  r.session_id,
            r.blocking_session_id,
            bc.chain_level + 1,
            bc.chain_path + ' -> ' + CAST(r.session_id AS varchar(10))
    FROM sys.dm_exec_requests AS r
    JOIN BlockingChain AS bc
      ON r.blocking_session_id = bc.session_id
)
SELECT  bc.chain_level,
        bc.chain_path,
        CASE WHEN bc.blocking_session_id = 0
             THEN 'HEAD BLOCKER' ELSE 'BLOCKED' END AS role_in_chain,
        r.session_id,
        r.blocking_session_id,
        r.wait_type,
        r.wait_time / 1000              AS wait_time_sec,
        r.wait_resource,
        DB_NAME(r.database_id)         AS database_name,
        s.login_name,
        s.host_name,
        s.program_name,
        s.status                       AS session_status,
        SUBSTRING(st.text,
                  (r.statement_start_offset / 2) + 1,
                  ((CASE r.statement_end_offset
                        WHEN -1 THEN DATALENGTH(st.text)
                        ELSE r.statement_end_offset
                    END - r.statement_start_offset) / 2) + 1) AS current_statement
FROM BlockingChain AS bc
JOIN sys.dm_exec_requests AS r
  ON r.session_id = bc.session_id
JOIN sys.dm_exec_sessions AS s
  ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS st
WHERE bc.chain_level = 0
   OR r.wait_time / 1000 >= @BlockingDurationSec
ORDER BY bc.chain_path, bc.chain_level
OPTION (MAXRECURSION 32);

PRINT '';
PRINT '--- Sessions with open transactions but no active request ---';
PRINT 'A sleeping session holding locks will not appear in the chain above.';
SELECT  s.session_id,
        s.login_name,
        s.host_name,
        s.program_name,
        s.status                       AS session_status,
        at.transaction_begin_time,
        DATEDIFF(SECOND, at.transaction_begin_time, GETDATE())
                                       AS open_seconds,
        at.name                        AS transaction_name,
        at.transaction_type,
        at.transaction_state
FROM sys.dm_tran_session_transactions AS tst
JOIN sys.dm_exec_sessions AS s
  ON s.session_id = tst.session_id
JOIN sys.dm_tran_active_transactions AS at
  ON at.transaction_id = tst.transaction_id
WHERE s.session_id > 50
  AND NOT EXISTS ( SELECT 1
                   FROM sys.dm_exec_requests AS r
                   WHERE r.session_id = s.session_id )
ORDER BY open_seconds DESC;

PRINT '';
PRINT '--- Recent deadlock graphs (system_health, newest first) ---';
PRINT 'Open the deadlock_graph XML in SSMS to see the victim, the';
PRINT 'resources, and the two execution stacks side by side.';
SELECT TOP (@RecentDeadlocks)
       XEventData.XEvent.value('(@timestamp)[1]', 'datetime2')
                                           AS deadlock_time_utc,
       CAST(REPLACE(REPLACE(
              XEventData.XEvent.value('(data/value)[1]', 'varchar(max)'),
              '<victim-list>', '<deadlock><victim-list>'),
              '<process-list>', '</victim-list><process-list>')
            AS xml)                        AS deadlock_graph
FROM ( SELECT CAST(xet.target_data AS xml) AS target_data
       FROM sys.dm_xe_session_targets AS xet
       JOIN sys.dm_xe_sessions AS xs
         ON xs.address = xet.event_session_address
       WHERE xs.name = 'system_health'
         AND xet.target_name = 'ring_buffer' ) AS src
CROSS APPLY src.target_data.nodes('//RingBufferTarget/event') AS XEventData (XEvent)
WHERE XEventData.XEvent.value('(@name)[1]', 'varchar(4000)') = 'xml_deadlock_report'
ORDER BY deadlock_time_utc DESC;
