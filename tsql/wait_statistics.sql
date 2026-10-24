/* ============================================================================
   wait_statistics.sql -- what SQL Server has been waiting on since startup

   Purpose:
     Show the wait types that have consumed the most time since the last
     service start, with each wait's share of total waits, average wait
     per task, and the split between signal waits (time on the runnable
     queue, a CPU pressure hint) and resource waits (time waiting on the
     resource itself). A second section lists sessions waiting right now,
     so a snapshot of history and a snapshot of the present sit together.

     Wait stats reset on every service restart, so the first section also
     prints the start time: numbers gathered over 20 minutes and over
     20 days do not deserve the same conclusions. For trending, capture
     this output on a schedule and diff two snapshots; the shape of the
     output is deliberate about that.

   Usage (sqlcmd):
     sqlcmd -S <server> -E -i wait_statistics.sql

   Thresholds (DECLARE variables below):
     @TopN            How many wait types to list. Default 15.
     @OnlyWaitingNow  When 1, show only currently waiting sessions with
                      a wait longer than @MinWaitMs; when 0, show the
                      cumulative section too. Default 0.

   Compatibility:
     SQL Server 2016 or later. Uses sys.dm_os_wait_stats,
     sys.dm_os_waiting_tasks, sys.dm_exec_sessions, and
     sys.dm_os_sys_info. Idle and background wait types are excluded
     by a configurable list; edit the list, not the logic. Reviewed
     against the documented DMV schemas. Not executed against a live
     SQL Server instance during development; see the README testing
     status.

   Requires:
     VIEW SERVER STATE.

   Safety:
     Read-only.
   ============================================================================ */

SET NOCOUNT ON;

DECLARE @TopN           int = 15;
DECLARE @OnlyWaitingNow bit = 0;
DECLARE @MinWaitMs      int = 1000;

PRINT '================================================================';
PRINT ' Wait statistics';
PRINT ' Server        : ' + @@SERVERNAME;
PRINT ' Collected since: '
      + CONVERT(nvarchar(30),
                (SELECT sqlserver_start_time FROM sys.dm_os_sys_info), 120);
PRINT '================================================================';

IF @OnlyWaitingNow = 0
BEGIN
    PRINT '';
    PRINT '--- Top waits since startup (idle/background waits excluded) ---';
    PRINT 'signal waits ~ CPU pressure; resource waits ~ the named resource.';
    SELECT TOP (@TopN)
           wait_type,
           wait_time_ms / 1000.0                            AS wait_time_sec,
           100.0 * wait_time_ms
               / SUM(wait_time_ms) OVER ()                 AS pct_of_total,
           waiting_tasks_count,
           wait_time_ms * 1.0
               / NULLIF(waiting_tasks_count, 0)             AS avg_wait_ms,
           max_wait_time_ms,
           signal_wait_time_ms / 1000.0                    AS signal_wait_sec,
           (wait_time_ms - signal_wait_time_ms) / 1000.0   AS resource_wait_sec
    FROM sys.dm_os_wait_stats
    WHERE wait_type NOT IN (
        -- Idle, background, and always-on noise: not actionable on their own
        'BROKER_EVENTHANDLER', 'BROKER_RECEIVE_WAITFOR', 'BROKER_TASK_STOP',
        'BROKER_TO_FLUSH', 'BROKER_TRANSMITTER',
        'CHECKPOINT_QUEUE', 'CLR_AUTO_EVENT', 'CLR_MANUAL_EVENT',
        'CLR_SEMAPHORE',
        'DBMIRROR_DBM_EVENT', 'DBMIRROR_EVENTS_QUEUE',
        'DBMIRROR_WORKER_QUEUE', 'DBMIRRORING_CMD',
        'DIRTY_PAGE_POLL', 'DISPATCHER_QUEUE_SEMAPHORE', 'EXECSYNC',
        'FSAGENT', 'FT_IFTS_SCHEDULER_IDLE_WAIT', 'FT_IFTSHC_MUTEX',
        'HADR_CLUSAPI_CALL', 'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        'HADR_LOGCAPTURE_WAIT', 'HADR_NOTIFICATION_DEADLOCK',
        'HADR_TIMER_TASK', 'HADR_WORK_QUEUE',
        'KSOURCE_WAKEUP', 'LAZYWRITER_SLEEP', 'LOGMGR_QUEUE',
        'MEMORY_ALLOCATION_EXT', 'ONDEMAND_TASK_QUEUE',
        'PARALLEL_REDO_DRAIN_WORKER', 'PARALLEL_REDO_LOG_CACHE',
        'PARALLEL_REDO_TRAN_LIST', 'PARALLEL_REDO_WORKER_SYNC',
        'PARALLEL_REDO_WORKER_WAIT_WORK',
        'PREEMPTIVE_OS_FLUSHFILEBUFFERS', 'PREEMPTIVE_XE_CALLBACKEXECUTE',
        'PREEMPTIVE_XE_DISPATCHER', 'PREEMPTIVE_XE_GETTARGETSTATE',
        'PREEMPTIVE_XE_SESSIONCOMMIT', 'PREEMPTIVE_XE_TARGETFINALIZE',
        'PREEMPTIVE_XE_TARGETINIT',
        'PWAIT_ALL_COMPONENTS_INITIALIZED',
        'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
        'PWAIT_EXTENSIBILITY_CLEANUP_TASK',
        'QDS_ASYNC_QUEUE', 'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
        'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', 'QDS_SHUTDOWN_QUEUE',
        'REDO_THREAD_PENDING_WORK', 'REQUEST_FOR_DEADLOCK_SEARCH',
        'RESOURCE_QUEUE', 'SERVER_IDLE_CHECK',
        'SLEEP_BPOOL_FLUSH', 'SLEEP_DBSTARTUP', 'SLEEP_DCOMSTARTUP',
        'SLEEP_MASTERDBREADY', 'SLEEP_MASTERMDREADY',
        'SLEEP_MASTERUPGRADED', 'SLEEP_MSDBSTARTUP', 'SLEEP_SYSTEMTASK',
        'SLEEP_TASK', 'SLEEP_TEMPDBSTARTUP',
        'SNI_HTTP_ACCEPT', 'SOS_WORK_DISPATCHER',
        'SP_SERVER_DIAGNOSTICS_SLEEP',
        'SQLTRACE_BUFFER_FLUSH', 'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
        'SQLTRACE_WAIT_ENTRIES',
        'WAIT_FOR_RESULTS', 'WAITFOR', 'WAITFOR_TASKSHUTDOWN',
        'WAIT_XTP_RECOVERY', 'WAIT_XTP_HOST_WAIT',
        'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', 'WAIT_XTP_CKPT_CLOSE',
        'XE_BUFFERMGR_ALLPROCESSED_EVENT', 'XE_DISPATCHER_JOIN',
        'XE_DISPATCHER_WAIT', 'XE_LIVE_TARGET_TVF', 'XE_TIMER_EVENT'
    )
    ORDER BY wait_time_ms DESC;
END

PRINT '';
PRINT '--- Sessions waiting right now ---';
SELECT  wt.session_id,
        wt.exec_context_id,
        wt.wait_type,
        wt.wait_duration_ms,
        wt.waiting_task_address,
        wt.blocking_session_id,
        wt.resource_description,
        s.login_name,
        s.host_name,
        s.program_name,
        DB_NAME(s.database_id) AS database_name
FROM sys.dm_os_waiting_tasks AS wt
JOIN sys.dm_exec_sessions AS s
  ON s.session_id = wt.session_id
WHERE wt.session_id > 50
  AND wt.session_id <> @@SPID
  AND wt.wait_duration_ms >= @MinWaitMs
ORDER BY wt.wait_duration_ms DESC;
