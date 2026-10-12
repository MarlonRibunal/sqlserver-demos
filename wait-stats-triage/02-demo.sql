/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Wait statistics answer "where did the time go?". Each scenario makes one
  kind of wait happen on purpose, measures it in THIS session's waits
  (sys.dm_exec_session_wait_stats), and checks the triage identity:

        elapsed  =  CPU  +  waits

     A  LCK_M_S: a reader blocked by a writer, watched live in
        sys.dm_os_waiting_tasks; then with READ_COMMITTED_SNAPSHOT
     B  WRITELOG: 2,000 single-row commits, one transaction, and delayed
        durability
     C  PAGEIOLATCH_SH: a scan from disk (read-ahead hides most of it), and
        scattered lookups from disk and from memory
     D  SOS_SCHEDULER_YIELD: a query that is busy, not waiting
     E  the instance-wide numbers, and why the top of them is noise

  WHAT THIS CHANGES: only WaitDemo, and it says so as it goes:
     - scenario A turns READ_COMMITTED_SNAPSHOT on for WaitDemo, then off
     - scenario B sets DELAYED_DURABILITY = FORCED on WaitDemo, then back
       to DISABLED
     - scenario C takes WaitDemo OFFLINE and back ONLINE, twice, to empty
       the cache of its pages. Anyone else connected to WaitDemo is
       disconnected.
  The instance's wait statistics are only read, never cleared.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

-- A previous run may have stopped half way through.
ALTER DATABASE WaitDemo SET READ_COMMITTED_SNAPSHOT OFF WITH ROLLBACK IMMEDIATE;
ALTER DATABASE WaitDemo SET DELAYED_DURABILITY = DISABLED;
GO

USE WaitDemo;
GO
SET NOCOUNT ON;
GO

TRUNCATE TABLE Demo.Waits;
TRUNCATE TABLE Demo.Runs;
TRUNCATE TABLE Demo.Verdicts;
TRUNCATE TABLE Demo.Log;
GO


/*==============================================================================
  A. LCK_M_S. A background session reads account 1 while this session holds
     an update lock on it for 2 seconds. This session watches it wait.
==============================================================================*/
PRINT '=== A: a blocked reader ===';
GO
DECLARE @wt nvarchar(60), @by int, @res nvarchar(200), @ms int, @lw bigint, @seen bigint;

EXEC Demo.usp_A_Run 'read committed', @wt OUTPUT, @by OUTPUT, @res OUTPUT, @ms OUTPUT, @lw OUTPUT, @seen OUTPUT;
INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('A', 'the blocked reader shows up in sys.dm_os_waiting_tasks, waiting on LCK_M_S, blocked by this session',
 ISNULL(@wt, 'no lock wait seen') + ', blocked by ' + ISNULL(CAST(@by AS varchar(10)), '?') + ' (this session is ' + CAST(@@SPID AS varchar(10)) + '); resource: ' + ISNULL(@res, '?'),
 CASE WHEN @wt IS NULL AND @ms IS NULL THEN 'INCONCLUSIVE'
      WHEN @wt = N'LCK_M_S' AND @by = @@SPID THEN 'CONFIRMED' ELSE 'unexpected' END),
('A', 'its read took as long as the lock was held, and the wait was visible while it lasted',
 'read took ' + ISNULL(CAST(@ms AS varchar(10)), '?') + ' ms; longest wait_duration_ms seen: ' + ISNULL(CAST(@seen AS varchar(10)), '?'),
 CASE WHEN @ms IS NULL THEN 'INCONCLUSIVE'
      WHEN @ms >= 1500 AND @seen >= 1500 THEN 'CONFIRMED' ELSE 'unexpected' END),
('A', 'but the reader''s own sys.dm_exec_session_wait_stats recorded no lock wait (it is a background session)',
 'LCK_M_% in the reader''s session wait stats: ' + ISNULL(CAST(@lw AS varchar(10)), '?') + ' ms',
 CASE WHEN @lw IS NULL THEN 'INCONCLUSIVE' ELSE 'info' END);
GO

USE master;
ALTER DATABASE WaitDemo SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
USE WaitDemo;
GO

DECLARE @wt nvarchar(60), @by int, @res nvarchar(200), @ms int, @lw bigint, @seen bigint;
EXEC Demo.usp_A_Run 'read committed snapshot', @wt OUTPUT, @by OUTPUT, @res OUTPUT, @ms OUTPUT, @lw OUTPUT, @seen OUTPUT;
INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('A', 'fix: with READ_COMMITTED_SNAPSHOT the reader reads the last committed version and doesn''t wait',
 'read took ' + ISNULL(CAST(@ms AS varchar(10)), '?') + ' ms; seen waiting: ' + ISNULL(@wt, 'no'),
 CASE WHEN @ms IS NULL THEN 'INCONCLUSIVE'
      WHEN @wt IS NULL AND @ms < 500 THEN 'CONFIRMED' ELSE 'unexpected' END);
GO

USE master;
ALTER DATABASE WaitDemo SET READ_COMMITTED_SNAPSHOT OFF WITH ROLLBACK IMMEDIATE;
USE WaitDemo;
GO


/*==============================================================================
  B. WRITELOG. 2,000 inserts, each its own transaction; then all 2,000 in
     one transaction; then each its own transaction again, with
     DELAYED_DURABILITY = FORCED on WaitDemo.
==============================================================================*/
PRINT '=== B: commits ===';
GO
EXEC Demo.usp_Measure 'B', '2,000 inserts, each its own commit', N'
    DECLARE @i int = 0;
    WHILE @i < 2000 BEGIN INSERT Demo.Log (Msg) VALUES (''one at a time''); SET @i += 1; END';

EXEC Demo.usp_Measure 'B', '2,000 inserts, one commit', N'
    DECLARE @i int = 0;
    BEGIN TRANSACTION;
    WHILE @i < 2000 BEGIN INSERT Demo.Log (Msg) VALUES (''one transaction''); SET @i += 1; END
    COMMIT;';
GO

ALTER DATABASE CURRENT SET DELAYED_DURABILITY = FORCED;
GO
EXEC Demo.usp_Measure 'B', '2,000 inserts, each its own commit, delayed durability', N'
    DECLARE @i int = 0;
    WHILE @i < 2000 BEGIN INSERT Demo.Log (Msg) VALUES (''delayed''); SET @i += 1; END';
GO
ALTER DATABASE CURRENT SET DELAYED_DURABILITY = DISABLED;
GO


/*==============================================================================
  C. PAGEIOLATCH_SH. Empty the cache of WaitDemo's pages (OFFLINE, ONLINE),
     then read Demo.Big from disk two ways: one scan, and 2,000 single-row
     lookups scattered across it. Then the lookups again, from memory.
==============================================================================*/
PRINT '=== C: reading from disk ===';
GO
USE master;
ALTER DATABASE WaitDemo SET OFFLINE WITH ROLLBACK IMMEDIATE;
ALTER DATABASE WaitDemo SET ONLINE;
GO
USE WaitDemo;
GO
DECLARE @cold int = (SELECT COUNT(*) FROM sys.dm_os_buffer_descriptors WHERE database_id = DB_ID());
INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict)
SELECT 'C', 'the cache really was empty: pages of WaitDemo in memory before the cold reads',
       CAST(@cold AS varchar(10)) + ' pages (Demo.Big alone is about 13,000)',
       CASE WHEN @cold < 2000 THEN 'CONFIRMED' ELSE 'INCONCLUSIVE' END;
GO
EXEC Demo.usp_Measure 'C', 'scan of Demo.Big (100 MB), cold cache', N'
    DECLARE @s decimal(18,2), @n varchar(40);
    SELECT @s = SUM(Amount), @n = MAX(Note) FROM Demo.Big WITH (INDEX (PK_Big)) OPTION (MAXDOP 1);';
GO
USE master;
ALTER DATABASE WaitDemo SET OFFLINE WITH ROLLBACK IMMEDIATE;
ALTER DATABASE WaitDemo SET ONLINE;
GO
USE WaitDemo;
GO
-- One row every 197 IDs: every lookup lands on a different page.
EXEC Demo.usp_Measure 'C', '2,000 single-row lookups, cold cache', N'
    DECLARE @i int = 0, @s decimal(18,2), @t decimal(18,2) = 0;
    WHILE @i < 2000
    BEGIN
        SELECT @s = Amount FROM Demo.Big WHERE ID = 1 + @i * 197;
        SET @t += @s; SET @i += 1;
    END';
EXEC Demo.usp_Measure 'C', '2,000 single-row lookups, warm cache', N'
    DECLARE @i int = 0, @s decimal(18,2), @t decimal(18,2) = 0;
    WHILE @i < 2000
    BEGIN
        SELECT @s = Amount FROM Demo.Big WHERE ID = 1 + @i * 197;
        SET @t += @s; SET @i += 1;
    END';
GO


/*==============================================================================
  D. SOS_SCHEDULER_YIELD. A query that hashes every row of Demo.Big five
     times, from memory: all CPU. It yields the scheduler every 4 ms or so;
     on an idle machine it gets it straight back.
==============================================================================*/
PRINT '=== D: busy, not waiting ===';
GO
EXEC Demo.usp_Measure 'D', 'hash every row five times, warm cache', N'
    DECLARE @x bigint;
    SELECT @x = SUM(CAST(CHECKSUM(HASHBYTES(''SHA2_256'', b.Note + CAST(k.k AS varchar(2)))) AS bigint))
    FROM   Demo.Big AS b
    CROSS JOIN (VALUES (1), (2), (3), (4), (5)) AS k (k)
    OPTION (MAXDOP 1);';
GO


/*==============================================================================
  Verdicts for B, C, D, and the triage identity for every measured run.
==============================================================================*/
DECLARE @b1_n bigint, @b1_ms bigint, @b1_el bigint, @b2_n bigint, @b2_el bigint, @b3_n bigint, @b3_el bigint,
        @c1_n bigint, @c1_ms bigint, @c1_el bigint, @c1_r bigint, @c1_st bigint, @c2_n bigint, @c2_ms bigint, @c2_el bigint, @c2_r bigint, @c2_st bigint, @c3_n bigint, @c3_el bigint, @c3_r bigint,
        @d_n bigint, @d_ms bigint, @d_sig bigint, @d_el bigint, @d_cpu bigint;

SELECT @b1_n = ISNULL(SUM(Tasks), 0), @b1_ms = ISNULL(SUM(WaitMs), 0) FROM Demo.Waits WHERE Label = '2,000 inserts, each its own commit' AND WaitType = N'WRITELOG';
SELECT @b2_n = ISNULL(SUM(Tasks), 0) FROM Demo.Waits WHERE Label = '2,000 inserts, one commit' AND WaitType = N'WRITELOG';
SELECT @b3_n = ISNULL(SUM(Tasks), 0) FROM Demo.Waits WHERE Label LIKE '%delayed durability' AND WaitType = N'WRITELOG';
SELECT @b1_el = ElapsedMs FROM Demo.Runs WHERE Label = '2,000 inserts, each its own commit';
SELECT @b2_el = ElapsedMs FROM Demo.Runs WHERE Label = '2,000 inserts, one commit';
SELECT @b3_el = ElapsedMs FROM Demo.Runs WHERE Label LIKE '%delayed durability';

SELECT @c1_n = ISNULL(SUM(Tasks), 0), @c1_ms = ISNULL(SUM(WaitMs), 0) FROM Demo.Waits WHERE Label LIKE 'scan%cold cache' AND WaitType LIKE N'PAGEIOLATCH[_]%';
SELECT @c2_n = ISNULL(SUM(Tasks), 0), @c2_ms = ISNULL(SUM(WaitMs), 0) FROM Demo.Waits WHERE Label LIKE '%lookups, cold cache' AND WaitType LIKE N'PAGEIOLATCH[_]%';
SELECT @c3_n = ISNULL(SUM(Tasks), 0) FROM Demo.Waits WHERE Label LIKE '%lookups, warm cache' AND WaitType LIKE N'PAGEIOLATCH[_]%';
SELECT @c1_el = ElapsedMs, @c1_r = FileReads, @c1_st = ReadStallMs FROM Demo.Runs WHERE Label LIKE 'scan%cold cache';
SELECT @c2_el = ElapsedMs, @c2_r = FileReads, @c2_st = ReadStallMs FROM Demo.Runs WHERE Label LIKE '%lookups, cold cache';
SELECT @c3_el = ElapsedMs, @c3_r = FileReads FROM Demo.Runs WHERE Label LIKE '%lookups, warm cache';

SELECT @d_n = ISNULL(SUM(Tasks), 0), @d_ms = ISNULL(SUM(WaitMs), 0), @d_sig = ISNULL(SUM(SignalMs), 0) FROM Demo.Waits WHERE Scenario = 'D' AND WaitType = N'SOS_SCHEDULER_YIELD';
SELECT @d_el = ElapsedMs, @d_cpu = CpuMs FROM Demo.Runs WHERE Scenario = 'D';

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('B', 'every commit waits for its log write: about one WRITELOG per commit',
 CAST(@b1_n AS varchar(10)) + ' WRITELOG waits, ' + CAST(@b1_ms AS varchar(10)) + ' ms, for 2,000 commits; elapsed ' + CAST(@b1_el AS varchar(10)) + ' ms',
 CASE WHEN @b1_n >= 1000 THEN 'CONFIRMED' ELSE 'unexpected' END),
('B', 'fix: one transaction, one commit, almost no WRITELOG',
 CAST(@b2_n AS varchar(10)) + ' WRITELOG waits; elapsed ' + CAST(@b2_el AS varchar(10)) + ' ms',
 CASE WHEN @b2_n <= 20 THEN 'CONFIRMED' ELSE 'unexpected' END),
('B', 'delayed durability: commits don''t wait for the log write (and can be lost)',
 CAST(@b3_n AS varchar(10)) + ' WRITELOG waits; elapsed ' + CAST(@b3_el AS varchar(10)) + ' ms',
 CASE WHEN @b3_n <= 20 THEN 'CONFIRMED' ELSE 'unexpected' END),

('C', 'the cold scan read Demo.Big from disk',
 CAST(@c1_r AS varchar(10)) + ' physical reads, ' + CAST(@c1_st AS varchar(10)) + ' ms of read stall; ' + CAST(@c1_n AS varchar(10)) + ' PAGEIOLATCH waits, '
     + CAST(@c1_ms AS varchar(10)) + ' ms; elapsed ' + CAST(@c1_el AS varchar(10)) + ' ms',
 CASE WHEN @c1_r >= 50 THEN 'CONFIRMED' ELSE 'unexpected' END),
('C', 'so did the cold lookups, one page at a time',
 CAST(@c2_r AS varchar(10)) + ' physical reads, ' + CAST(@c2_st AS varchar(10)) + ' ms of read stall; ' + CAST(@c2_n AS varchar(10)) + ' PAGEIOLATCH waits, '
     + CAST(@c2_ms AS varchar(10)) + ' ms; elapsed ' + CAST(@c2_el AS varchar(10)) + ' ms',
 CASE WHEN @c2_r >= 50 THEN 'CONFIRMED' ELSE 'unexpected' END),
('C', 'PAGEIOLATCH waits appear only when a read is still in flight when the page is needed',
 'cold scan ' + CAST(@c1_n AS varchar(10)) + ' and lookups ' + CAST(@c2_n AS varchar(10)) + ' waits, for ' + CAST(@c1_st + @c2_st AS varchar(10))
     + ' ms of read stall: ' + CASE WHEN @c1_n + @c2_n < 50 THEN 'storage this fast hides disk reads from wait stats' ELSE 'slow enough to wait for' END,
 'info'),
('C', 'warm, the same lookups read nothing from disk and don''t wait',
 CAST(@c3_r AS varchar(10)) + ' physical reads, ' + CAST(@c3_n AS varchar(10)) + ' PAGEIOLATCH waits; elapsed ' + CAST(@c3_el AS varchar(10)) + ' ms',
 CASE WHEN @c3_r <= 2 AND @c3_n <= 2 THEN 'CONFIRMED' ELSE 'unexpected' END),

('D', 'a CPU-bound query yields often (SOS_SCHEDULER_YIELD) but barely waits: its time is CPU',
 CAST(@d_n AS varchar(10)) + ' SOS_SCHEDULER_YIELD, ' + CAST(@d_ms AS varchar(10)) + ' ms (' + CAST(@d_sig AS varchar(10)) + ' ms of it waiting for a CPU); CPU '
     + CAST(@d_cpu AS varchar(10)) + ' ms of ' + CAST(@d_el AS varchar(10)) + ' ms elapsed',
 CASE WHEN @d_n >= 10 AND @d_cpu >= 0.6 * @d_el THEN 'CONFIRMED' ELSE 'unexpected' END);

-- The identity: a serial request's elapsed time is its CPU time plus its
-- waits (signal waits, the time it was ready but waiting for a CPU,
-- included). PREEMPTIVE_% waits are time the thread spent inside an OS
-- call; on the tested build (Linux) the CPU counter included that time
-- too, so they are counted once: elapsed must fall between CPU + the other
-- waits and CPU + all waits. Allow a quarter, plus 100 ms, for timer
-- granularity.
INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict)
SELECT Scenario, 'elapsed = CPU + waits: ' + Label,
       CAST(ElapsedMs AS varchar(10)) + ' ms elapsed; ' + CAST(CpuMs AS varchar(10)) + ' CPU + ' + CAST(WaitMs - PreemptMs AS varchar(10)) + ' waits'
           + CASE WHEN PreemptMs > 0 THEN ' (+ ' + CAST(PreemptMs AS varchar(10)) + ' preemptive)' ELSE '' END,
       CASE WHEN ElapsedMs >= CpuMs + WaitMs - PreemptMs - (0.25 * ElapsedMs + 100)
             AND ElapsedMs <= CpuMs + WaitMs + (0.25 * ElapsedMs + 100) THEN 'CONFIRMED' ELSE 'unexpected' END
FROM   Demo.Runs
ORDER BY Seq;
GO


/*==============================================================================
  E. The instance-wide view: sys.dm_os_wait_stats since the instance
     started. Read only. The raw top 10 is mostly background tasks waiting
     for work; filtering those out leaves waits that cost a query time.
==============================================================================*/
PRINT '=== E: the instance-wide view ===';
GO
DECLARE @benign TABLE (Pattern nvarchar(60) NOT NULL);
INSERT @benign (Pattern) VALUES
 (N'%SLEEP%'), (N'%IDLE%'), (N'%QUEUE%'), (N'BROKER[_]%'), (N'XE[_]%'), (N'QDS[_]%'), (N'CLR[_]%'),
 (N'WAITFOR'), (N'DISPATCHER_QUEUE_SEMAPHORE'), (N'CHECKPOINT_QUEUE'), (N'REQUEST_FOR_DEADLOCK_SEARCH'),
 (N'SQLTRACE[_]%'), (N'SOS_WORK_DISPATCHER'), (N'DIRTY_PAGE_POLL'), (N'HADR_FILESTREAM_IOMGR_IOCOMPLETION'),
 (N'SP_SERVER_DIAGNOSTICS_SLEEP'), (N'PREEMPTIVE_XE_DISPATCHER'), (N'PWAIT_ALL_COMPONENTS_INITIALIZED'),
 (N'PVS_PREALLOCATE'), (N'STARTUP_DEPENDENCY_MANAGER'), (N'WAIT_XTP_%'), (N'PARALLEL_REDO_%'),
 (N'SNI_HTTP_ACCEPT'), (N'CXCONSUMER'), (N'ONDEMAND_TASK_QUEUE'), (N'PREEMPTIVE_OS_FLUSHFILEBUFFERS'),
 (N'VDI_CLIENT_OTHER'), (N'MEMORY_ALLOCATION_EXT'), (N'RESERVED_MEMORY_ALLOCATION_EXT');

DECLARE @top TABLE (Rank_ int, WaitType nvarchar(60), WaitS decimal(18,1), Benign bit);
INSERT @top
SELECT TOP (10) ROW_NUMBER() OVER (ORDER BY w.wait_time_ms DESC), w.wait_type, w.wait_time_ms / 1000.0,
       CASE WHEN EXISTS (SELECT 1 FROM @benign AS b WHERE w.wait_type LIKE b.Pattern) THEN 1 ELSE 0 END
FROM   sys.dm_os_wait_stats AS w
ORDER BY w.wait_time_ms DESC;

DECLARE @benignTop int = (SELECT COUNT(*) FROM @top WHERE Benign = 1);
INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict)
SELECT 'E', 'the raw instance-wide top 10 is mostly background waits',
       CAST(@benignTop AS varchar(10)) + ' of the top 10 are on the filter list: '
           + (SELECT STRING_AGG(CAST(WaitType AS varchar(60)), ', ') WITHIN GROUP (ORDER BY Rank_) FROM @top WHERE Benign = 1),
       'info';

PRINT '';
PRINT '=== E1. THE INSTANCE-WIDE TOP 10, RAW ===';
SELECT Rank_, WaitType, WaitS, OnFilterList = CASE Benign WHEN 1 THEN 'yes' ELSE '' END FROM @top ORDER BY Rank_;

PRINT '';
PRINT '=== E2. THE INSTANCE-WIDE TOP 10, FILTERED ===';
SELECT TOP (10) WaitType = w.wait_type, WaitS = CAST(w.wait_time_ms / 1000.0 AS decimal(18,1)),
       Tasks = w.waiting_tasks_count, AvgMs = CAST(w.wait_time_ms * 1.0 / NULLIF(w.waiting_tasks_count, 0) AS decimal(18,2)),
       SignalPct = CAST(100.0 * w.signal_wait_time_ms / NULLIF(w.wait_time_ms, 0) AS decimal(5,1))
FROM   sys.dm_os_wait_stats AS w
WHERE  w.waiting_tasks_count > 0
  AND  NOT EXISTS (SELECT 1 FROM @benign AS b WHERE w.wait_type LIKE b.Pattern)
ORDER BY w.wait_time_ms DESC;
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. WHERE THE TIME WENT, PER MEASURED RUN ===';
GO
SELECT r.Scenario, r.Label, r.ElapsedMs, r.CpuMs, r.WaitMs, r.PreemptMs, r.FileReads, r.ReadStallMs,
       TopWaits = (SELECT STRING_AGG(CAST(w.WaitType AS varchar(60)) + ' ' + CAST(w.WaitMs AS varchar(20)) + ' ms (' + CAST(w.Tasks AS varchar(20)) + ')', ', ')
                          WITHIN GROUP (ORDER BY w.WaitMs DESC, w.Tasks DESC)
                   FROM  (SELECT TOP (3) * FROM Demo.Waits AS w0
                          WHERE w0.Scenario = r.Scenario AND w0.Label = r.Label
                          ORDER BY w0.WaitMs DESC, w0.Tasks DESC) AS w)
FROM   Demo.Runs AS r
ORDER BY r.Seq;
GO

PRINT '';
PRINT '=== 2. VERDICTS ===';
GO
SELECT Scenario, Claim, Evidence, Verdict FROM Demo.Verdicts ORDER BY Scenario, Seq;
GO

PRINT '';
PRINT '=== 3. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Claim, Evidence, Verdict FROM Demo.Verdicts WHERE Verdict IN ('unexpected', 'INCONCLUSIVE') ORDER BY Scenario, Seq;
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 3 should be EMPTY. Anything in it is a';
PRINT ' genuine difference on your build or machine, worth';
PRINT ' reading before you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
