/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  Four background workers (Service Broker activation -- see 01-setup.sql)
  build a real blocking chain while this script watches it through the
  DMVs, finds its head, and sees it drain. Evidence lands in Demo.Chain,
  Demo.WorkerLog and Demo.Verdicts; the summary is the payoff.

  Scenarios
    A  a blocking chain      -> HEAD holds item 1; B1 waits on HEAD; B2 and
                                B3 wait on B1. Three sessions stuck behind
                                one that is doing nothing
    B  finding the head      -> the session that blocks but is not blocked
    C  draining              -> when the head commits, the chain unwinds in
                                order
    D  LOCK_TIMEOUT          -> wait a bounded time, then fail with 1222
    E  a deadlock            -> a chain that loops: the engine picks a victim

  Expected runtime: about twenty seconds, most of it the head blocker
  holding its lock on purpose.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE BlockingDemo;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('Demo.usp_Send') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

TRUNCATE TABLE Demo.WorkerLog;
UPDATE Demo.Items SET Qty = 0;
DROP TABLE IF EXISTS Demo.Chain, Demo.Verdicts;
CREATE TABLE Demo.Chain
(
    SessionID        int            NOT NULL,
    Worker           varchar(10)    NULL,
    Command          nvarchar(40)   NULL,
    BlockedBy        int            NULL,
    WaitType         nvarchar(60)   NULL,
    WaitMs           int            NULL,
    SessionStatus    nvarchar(30)   NULL,
    OpenTransactions int            NULL,
    Depth            int            NULL,       -- 1 = head of the chain
    IsHead           bit            NULL
);
CREATE TABLE Demo.Verdicts
(
    Scenario  varchar(60)   NOT NULL,
    Item      varchar(90)   NOT NULL,
    Detail    nvarchar(300) NULL,
    Expected  nvarchar(140) NULL,
    Verdict   varchar(24)   NULL
);
GO


/*==============================================================================
  SCENARIO A -- build a blocking chain

     Q1  HEAD:6000   takes item 1, then sits for 6 seconds, transaction open
     Q2  B1          takes item 2, then asks for item 1   -> waits on HEAD
     Q3  B2          reads item 1                         -> waits on B1 (!)
     Q4  B3          reads item 2                         -> waits on B1

  B3 has never touched item 1 and has nothing to do with HEAD. It is stuck
  anyway, because B1 is holding item 2 while B1 waits. That is a chain: the
  sessions at the end are blocked by sessions that are themselves blocked.

  B2 is the surprise. It wants item 1, which HEAD holds -- yet the DMVs
  report it blocked by B1, which does not hold item 1 at all. B1's exclusive
  request for item 1 is already queued, and lock requests are granted in
  order: B2's shared request waits behind B1's, not merely behind HEAD's
  lock. blocking_session_id names the request ahead in the queue.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO A: building the chain ---';
GO

EXEC Demo.usp_Send 1, 'A', N'HEAD:6000';
EXEC Demo.usp_WaitForLog 'A', 'Q1', 'holding item 1';
EXEC Demo.usp_Send 2, 'A', N'B1';
EXEC Demo.usp_WaitForLog 'A', 'Q2', 'holding item 2';
EXEC Demo.usp_WaitBlocked 1;
EXEC Demo.usp_Send 3, 'A', N'B2';
EXEC Demo.usp_Send 4, 'A', N'B3';
EXEC Demo.usp_WaitBlocked 3;
GO


/*==============================================================================
  SCENARIO B -- finding the head

  sys.dm_exec_requests shows, for each WAITING request, the session it is
  blocked by. Following those links back to a session that is not itself
  waiting finds the head of the chain -- the one to look at, and if it comes
  to it, the one to kill. Killing anything further down only moves the
  queue.

  The head is often not a request at all: an application that began a
  transaction and went quiet shows up in sys.dm_exec_sessions as 'sleeping'
  with an open transaction, and has no row in sys.dm_exec_requests. The
  query below starts from sessions, not requests, so it finds that case
  too. (This demo's head is an activation procedure inside WAITFOR, so it
  does have a request -- waiting, like the rest, but on nothing but time.)

  The recursive query is the one to keep.
==============================================================================*/
;WITH links AS
(
    -- every session in this database: who blocks it (0 = nobody)
    SELECT  s.session_id,
            BlockedBy = ISNULL(r.blocking_session_id, 0)
    FROM    sys.dm_exec_sessions AS s
    LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = s.session_id
    WHERE   s.database_id = DB_ID() AND s.session_id <> @@SPID
),
heads AS
(
    -- blocks someone, and is blocked by no one
    SELECT  l.session_id FROM links AS l
    WHERE   l.BlockedBy = 0
      AND   EXISTS (SELECT 1 FROM links AS x WHERE x.BlockedBy = l.session_id)
),
chain AS
(
    SELECT session_id, Depth = 1 FROM heads
    UNION ALL
    SELECT l.session_id, c.Depth + 1 FROM links AS l JOIN chain AS c ON l.BlockedBy = c.session_id
)
INSERT Demo.Chain (SessionID, Worker, Command, BlockedBy, WaitType, WaitMs, SessionStatus, OpenTransactions, Depth, IsHead)
SELECT  c.session_id,
        w.Worker, w.Command,
        NULLIF(r.blocking_session_id, 0), r.wait_type, r.wait_time,
        s.status, s.open_transaction_count,
        c.Depth, CASE WHEN c.Depth = 1 THEN 1 ELSE 0 END
FROM    chain AS c
JOIN    sys.dm_exec_sessions AS s ON s.session_id = c.session_id
LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = c.session_id
OUTER APPLY (SELECT TOP (1) Worker, Command FROM Demo.WorkerLog WITH (NOLOCK)
             WHERE RunTag = 'A' AND Spid = c.session_id ORDER BY LogID) AS w;
GO

DECLARE @headSpid int = (SELECT SessionID FROM Demo.Chain WHERE IsHead = 1);
DECLARE @headWorker varchar(10) = (SELECT Worker FROM Demo.Chain WHERE IsHead = 1);
DECLARE @heads int = (SELECT COUNT(*) FROM Demo.Chain WHERE IsHead = 1);
DECLARE @b3Depth int = (SELECT Depth FROM Demo.Chain WHERE Worker = 'Q4');
DECLARE @b3By int = (SELECT BlockedBy FROM Demo.Chain WHERE Worker = 'Q4');
DECLARE @b1Spid int = (SELECT SessionID FROM Demo.Chain WHERE Worker = 'Q2');
DECLARE @d nvarchar(300) = CAST(@heads AS nvarchar(10)) + N' head: session ' + ISNULL(CAST(@headSpid AS nvarchar(10)), N'?')
    + N' (' + ISNULL(@headWorker, N'?') + N'); ' + CAST((SELECT COUNT(*) FROM Demo.Chain) - 1 AS nvarchar(10))
    + N' sessions behind it';
INSERT Demo.Verdicts VALUES ('B. Finding the head', 'the session that blocks but is not blocked', @d,
    'one head: the HEAD worker (Q1)',
    CASE WHEN @heads = 1 AND @headWorker = 'Q1' THEN 'HEAD FOUND' ELSE 'unexpected' END);

SET @d = N'B3 (Q4) is blocked by session ' + ISNULL(CAST(@b3By AS nvarchar(10)), N'?') + N' (B1 is session '
       + ISNULL(CAST(@b1Spid AS nvarchar(10)), N'?') + N'), at depth ' + ISNULL(CAST(@b3Depth AS nvarchar(10)), N'?');
INSERT Demo.Verdicts VALUES ('A. The chain', 'B3, which never touched item 1', @d,
    'blocked by B1, not by HEAD: depth 3',
    CASE WHEN @b3By = @b1Spid AND @b3Depth = 3 THEN 'BLOCKED SECOND-HAND' ELSE 'unexpected' END);

DECLARE @b2By int = (SELECT BlockedBy FROM Demo.Chain WHERE Worker = 'Q3');
SET @d = N'B2 (Q3) wants item 1, held by HEAD (session ' + ISNULL(CAST(@headSpid AS nvarchar(10)), N'?')
       + N'); reported blocked by session ' + ISNULL(CAST(@b2By AS nvarchar(10)), N'?');
INSERT Demo.Verdicts VALUES ('A. The chain', 'B2, which wants the row HEAD holds', @d,
    'blocked by B1: queued behind B1''s earlier exclusive request',
    CASE WHEN @b2By = @b1Spid THEN 'QUEUED BEHIND B1' ELSE 'unexpected' END);
GO


/*==============================================================================
  SCENARIO C -- draining

  Wait for every worker to finish, then read the order they finished in from
  Demo.WorkerLog. When HEAD commits, B1 gets item 1 and finishes; then B2
  and B3 get their rows. The whole chain waited on one session that was doing
  nothing.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO C: waiting for the chain to drain ---';
GO

EXEC Demo.usp_WaitForLog 'A', 'Q1', 'done', 15000;
EXEC Demo.usp_WaitForLog 'A', 'Q2', 'done', 15000;
EXEC Demo.usp_WaitForLog 'A', 'Q3', 'done', 15000;
EXEC Demo.usp_WaitForLog 'A', 'Q4', 'done', 15000;
GO

DECLARE @h datetime2(3), @b1 datetime2(3), @b2 datetime2(3), @b3 datetime2(3), @b3start datetime2(3);
SELECT @h  = At FROM Demo.WorkerLog WHERE RunTag = 'A' AND Worker = 'Q1' AND Event = 'done';
SELECT @b1 = At FROM Demo.WorkerLog WHERE RunTag = 'A' AND Worker = 'Q2' AND Event = 'done';
SELECT @b2 = At FROM Demo.WorkerLog WHERE RunTag = 'A' AND Worker = 'Q3' AND Event = 'done';
SELECT @b3 = At FROM Demo.WorkerLog WHERE RunTag = 'A' AND Worker = 'Q4' AND Event = 'done';
SELECT @b3start = At FROM Demo.WorkerLog WHERE RunTag = 'A' AND Worker = 'Q4' AND Event = 'started';

DECLARE @d nvarchar(300) = N'HEAD done ' + CONVERT(nvarchar(12), @h, 114) + N'; B1 ' + CONVERT(nvarchar(12), @b1, 114)
    + N'; B2 ' + CONVERT(nvarchar(12), @b2, 114) + N'; B3 ' + CONVERT(nvarchar(12), @b3, 114)
    + N' (B3 waited ' + CAST(DATEDIFF(millisecond, @b3start, @b3) AS nvarchar(10)) + N' ms)';
INSERT Demo.Verdicts VALUES ('C. Draining', 'the order the chain finished in', @d,
    'HEAD first; B1 and B2 after it; B3 after B1',
    CASE WHEN @b1 >= @h AND @b2 >= @h AND @b3 >= @b1 THEN 'DRAINED IN ORDER' ELSE 'unexpected' END);
GO


/*==============================================================================
  SCENARIO D -- LOCK_TIMEOUT

  By default a blocked request waits forever. SET LOCK_TIMEOUT bounds the
  wait: after that many milliseconds the statement fails with Msg 1222 and
  the caller can decide what to do. Here this session asks for item 1 while
  a fresh HEAD holds it, with a one-second limit.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO D: LOCK_TIMEOUT ---';
GO

EXEC Demo.usp_Send 1, 'D', N'HEAD:3000';
EXEC Demo.usp_WaitForLog 'D', 'Q1', 'holding item 1';
GO

SET LOCK_TIMEOUT 1000;
DECLARE @t0 datetime2(7) = SYSDATETIME(), @q int, @err int;
BEGIN TRY
    SELECT @q = Qty FROM Demo.Items WHERE ItemID = 1;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
END CATCH
DECLARE @ms int = DATEDIFF(millisecond, @t0, SYSDATETIME());
SET LOCK_TIMEOUT -1;

DECLARE @d nvarchar(300) = N'failed with ' + ISNULL(N'Msg ' + CAST(@err AS nvarchar(10)), N'no error') + N' after '
    + CAST(@ms AS nvarchar(10)) + N' ms';
INSERT Demo.Verdicts VALUES ('D. LOCK_TIMEOUT', 'SET LOCK_TIMEOUT 1000, then read a locked row', @d,
    'Msg 1222 after about a second',
    CASE WHEN @err = 1222 AND @ms BETWEEN 900 AND 2000 THEN 'TIMED OUT' ELSE 'unexpected' END);
GO

EXEC Demo.usp_WaitForLog 'D', 'Q1', 'done', 10000;
GO


/*==============================================================================
  SCENARIO E -- a deadlock

  A chain that loops back on itself never drains: DL_A holds item 3 and wants
  item 4, DL_B holds item 4 and wants item 3. Each waits for the other.
  The deadlock monitor finds the cycle, picks a victim, and rolls it back
  with Msg 1205. The other completes.

  Unlike blocking, a deadlock resolves itself -- by failing one transaction,
  which the application must be ready to retry.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO E: a deadlock ---';
GO

EXEC Demo.usp_Send 1, 'E', N'DL_A';
EXEC Demo.usp_Send 2, 'E', N'DL_B';
GO

DECLARE @t0 datetime2(3) = SYSDATETIME();
WHILE (SELECT COUNT(*) FROM Demo.WorkerLog WITH (NOLOCK) WHERE RunTag = 'E' AND Event IN ('done', 'failed')) < 2
  AND DATEDIFF(millisecond, @t0, SYSDATETIME()) < 20000
    WAITFOR DELAY '00:00:00.100';

DECLARE @victims int = (SELECT COUNT(*) FROM Demo.WorkerLog WHERE RunTag = 'E' AND Event = 'failed' AND ErrorNum = 1205);
DECLARE @done int    = (SELECT COUNT(*) FROM Demo.WorkerLog WHERE RunTag = 'E' AND Event = 'done');
DECLARE @victim nvarchar(40) = (SELECT TOP (1) Command FROM Demo.WorkerLog WHERE RunTag = 'E' AND ErrorNum = 1205);
DECLARE @secs int = DATEDIFF(millisecond,
    (SELECT MIN(At) FROM Demo.WorkerLog WHERE RunTag = 'E' AND Event = 'started'),
    (SELECT MAX(At) FROM Demo.WorkerLog WHERE RunTag = 'E' AND Event IN ('done', 'failed')));
DECLARE @d nvarchar(300) = CAST(@victims AS nvarchar(10)) + N' victim (' + ISNULL(@victim, N'none') + N', Msg 1205), '
    + CAST(@done AS nvarchar(10)) + N' completed; resolved ' + CAST(@secs AS nvarchar(10)) + N' ms after the start';
INSERT Demo.Verdicts VALUES ('E. Deadlock', 'DL_A and DL_B, opposite order', @d,
    'one victim with 1205; the other commits',
    CASE WHEN @victims = 1 AND @done = 1 THEN 'ONE VICTIM' ELSE 'unexpected' END);
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. THE CHAIN, AS THE DMVs SAW IT ===';
GO
SELECT Depth, IsHead, SessionID, Worker, Command, BlockedBy, WaitType, WaitMs, SessionStatus, OpenTransactions
FROM   Demo.Chain ORDER BY Depth, Worker;
GO

PRINT '';
PRINT '=== 2. WHAT EACH WORKER DID ===';
GO
SELECT RunTag, Worker, Command, Event, Spid, ErrorNum, At FROM Demo.WorkerLog ORDER BY LogID;
GO

PRINT '';
PRINT '=== 3. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario;
GO

PRINT '';
PRINT '=== 4. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Detail, Verdict FROM Demo.Verdicts WHERE Verdict = 'unexpected';
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 4 should be EMPTY. Anything in it is either';
PRINT ' a genuine difference on your build, or another session';
PRINT ' working in BlockingDemo -- read it before the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
