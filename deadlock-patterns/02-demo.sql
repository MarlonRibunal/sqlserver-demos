/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  The deadlocks real systems have, each made to happen on cue between this
  session and a background worker (Service Broker activation; no second
  window needed), each followed by its fix. Then the evidence SQL Server
  kept: the deadlock graphs in the built-in system_health session. Results
  land in Demo.Outcomes and Demo.Verdicts; the summary at the bottom is the
  payoff.

  Scenarios
    A  two transactions, same rows, opposite order  -> deadlock
    B  the same, in the same order                  -> one waits; no deadlock
    C  read, then update, under REPEATABLE READ     -> deadlock: both hold S,
                                                       both want X
    D  read WITH (UPDLOCK), then update             -> one waits; no deadlock
    E  a reader's key lookup vs a writer's update,
       no explicit transaction at all               -> deadlocks
       ... with a covering index                    -> none
    F  A again, with a retry loop                   -> deadlocked, retried,
                                                       committed
    G  the deadlock graphs in system_health         -> one per deadlock, naming
                                                       the indexes involved

  This session runs with DEADLOCK_PRIORITY LOW in A-D and F, so it is the
  victim whenever there is one and the worker always finishes. Scenario E
  changes IX_Accounts_Ref and this file puts it back.

  Expected runtime: about a minute, most of it G waiting for system_health
  to write its buffers to disk (up to two minutes).

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE DeadlockDemo;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('Demo.usp_Scenario') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- Let a worker an interrupted earlier run left behind finish, then reset.
DECLARE @i int = 0;
WHILE EXISTS (SELECT 1 FROM Demo.WorkerStatus WITH (NOLOCK) WHERE ID = 1 AND State IN ('sent', 'holding')) AND @i < 300
BEGIN
    WAITFOR DELAY '00:00:00.100';
    SET @i += 1;
END
UPDATE Demo.WorkerStatus SET RunTag = NULL, State = 'idle' WHERE ID = 1;
DELETE Demo.Outcomes;
UPDATE Demo.Accounts SET Balance = 1000, Status = 0 WHERE AccountID IN (1, 2, 5000);
GO

-- The index scenario E starts from: no Balance in it.
IF EXISTS (SELECT 1 FROM sys.index_columns
           WHERE object_id = OBJECT_ID('Demo.Accounts') AND index_id = INDEXPROPERTY(OBJECT_ID('Demo.Accounts'), 'IX_Accounts_Ref', 'IndexID')
             AND is_included_column = 1)
    CREATE INDEX IX_Accounts_Ref ON Demo.Accounts (AccountRef, Status) WITH (DROP_EXISTING = ON);
GO

IF OBJECT_ID('Demo.Verdicts') IS NOT NULL DROP TABLE Demo.Verdicts;
CREATE TABLE Demo.Verdicts
(
    Scenario  char(1)       NOT NULL,
    Item      varchar(70)   NOT NULL,
    Detail    varchar(300)  NOT NULL,
    Expected  varchar(80)   NOT NULL,
    Verdict   varchar(30)   NOT NULL
);
IF OBJECT_ID('Demo.Balances') IS NOT NULL DROP TABLE Demo.Balances;
CREATE TABLE Demo.Balances (Scenario char(1) NOT NULL, Acct1 decimal(12,2), Acct2 decimal(12,2));
GO

-- The demo's start, in UTC like system_health's timestamps (scenario G).
IF OBJECT_ID('Demo.RunStart') IS NOT NULL DROP TABLE Demo.RunStart;
SELECT StartedUtc = SYSUTCDATETIME() INTO Demo.RunStart;
GO


/*==============================================================================
  A -- the textbook deadlock. The worker updates account 2 and waits; this
  session updates account 1, then asks for account 2 and waits for the
  worker; the worker asks for account 1 and waits for this session. Neither
  can move. The deadlock monitor picks a victim and rolls it back.
==============================================================================*/
PRINT '=== A: same rows, opposite order ===';
DECLARE @tag varchar(30) = 'A_' + FORMAT(SYSDATETIME(), 'HHmmssfff');
UPDATE Demo.Accounts SET Balance = 1000 WHERE AccountID IN (1, 2);
EXEC Demo.usp_Scenario @tag, 'OPPOSITE';
INSERT Demo.Balances SELECT 'A', MAX(CASE WHEN AccountID = 1 THEN Balance END), MAX(CASE WHEN AccountID = 2 THEN Balance END)
FROM Demo.Accounts WHERE AccountID IN (1, 2);
GO

/*==============================================================================
  B -- the fix for A: everyone touches rows in the same order. This session
  asks for account 1, finds the worker has it, and simply waits its turn.
==============================================================================*/
PRINT '=== B: same rows, same order ===';
DECLARE @tag varchar(30) = 'B_' + FORMAT(SYSDATETIME(), 'HHmmssfff');
UPDATE Demo.Accounts SET Balance = 1000 WHERE AccountID IN (1, 2);
EXEC Demo.usp_Scenario @tag, 'SAME';
INSERT Demo.Balances SELECT 'B', MAX(CASE WHEN AccountID = 1 THEN Balance END), MAX(CASE WHEN AccountID = 2 THEN Balance END)
FROM Demo.Accounts WHERE AccountID IN (1, 2);
GO

/*==============================================================================
  C -- one row is enough. Under REPEATABLE READ both sessions read account 1
  and keep their shared locks; both then want to update it, which needs an
  exclusive lock, which waits for the OTHER session's shared lock. The
  conversion deadlock.
==============================================================================*/
PRINT '=== C: read, then update, REPEATABLE READ ===';
DECLARE @tag varchar(30) = 'C_' + FORMAT(SYSDATETIME(), 'HHmmssfff');
UPDATE Demo.Accounts SET Balance = 1000 WHERE AccountID IN (1, 2);
EXEC Demo.usp_Scenario @tag, 'CONVERT';
INSERT Demo.Balances SELECT 'C', MAX(CASE WHEN AccountID = 1 THEN Balance END), MAX(CASE WHEN AccountID = 2 THEN Balance END)
FROM Demo.Accounts WHERE AccountID IN (1, 2);
GO

/*==============================================================================
  D -- the fix for C: read WITH (UPDLOCK). Only one session at a time can
  hold an update lock on the row, so the second waits at its READ -- and
  then reads the value the first one wrote.
==============================================================================*/
PRINT '=== D: read WITH (UPDLOCK), then update ===';
DECLARE @tag varchar(30) = 'D_' + FORMAT(SYSDATETIME(), 'HHmmssfff');
UPDATE Demo.Accounts SET Balance = 1000 WHERE AccountID IN (1, 2);
EXEC Demo.usp_Scenario @tag, 'UPDLOCK';
INSERT Demo.Balances SELECT 'D', MAX(CASE WHEN AccountID = 1 THEN Balance END), MAX(CASE WHEN AccountID = 2 THEN Balance END)
FROM Demo.Accounts WHERE AccountID IN (1, 2);
GO

/*==============================================================================
  E -- no transaction, no hint, one row each: a SELECT and an UPDATE still
  deadlock, because each statement locks two indexes in opposite orders.
  Five seconds of each, then the same with Balance included in the index,
  so the reader never touches the clustered index at all.
==============================================================================*/
PRINT '=== E: key lookup vs update ===';
DECLARE @tag varchar(30) = 'E1_' + FORMAT(SYSDATETIME(), 'HHmmssfff');
EXEC Demo.usp_LookupRace @tag, 5;
GO
CREATE INDEX IX_Accounts_Ref ON Demo.Accounts (AccountRef, Status) INCLUDE (Balance) WITH (DROP_EXISTING = ON);
GO
PRINT '=== E: ... with a covering index ===';
DECLARE @tag varchar(30) = 'E2_' + FORMAT(SYSDATETIME(), 'HHmmssfff');
EXEC Demo.usp_LookupRace @tag, 5;
GO
CREATE INDEX IX_Accounts_Ref ON Demo.Accounts (AccountRef, Status) WITH (DROP_EXISTING = ON);
GO

/*==============================================================================
  F -- A again, but this session treats 1205 as "try again", the way any
  code that can deadlock should. The worker commits; the retry then goes
  through.
==============================================================================*/
PRINT '=== F: A with a retry loop ===';
DECLARE @tag varchar(30) = 'F_' + FORMAT(SYSDATETIME(), 'HHmmssfff');
UPDATE Demo.Accounts SET Balance = 1000 WHERE AccountID IN (1, 2);
EXEC Demo.usp_Scenario @tag, 'OPPOSITE', @MaxAttempts = 3;
INSERT Demo.Balances SELECT 'F', MAX(CASE WHEN AccountID = 1 THEN Balance END), MAX(CASE WHEN AccountID = 2 THEN Balance END)
FROM Demo.Accounts WHERE AccountID IN (1, 2);
GO


/*==============================================================================
  G -- what SQL Server kept. The built-in system_health Extended Events
  session records an xml_deadlock_report for every deadlock, with no trace
  flag and nothing to switch on. It reaches the event file only when the
  session's buffers are flushed (up to max_dispatch_latency, 120 s), so
  wait for as many graphs as this demo had deadlocks.

  Compare timestamp_utc as datetime2: compared with a string literal the
  tested build returned no rows at all.
==============================================================================*/
PRINT '=== G: the deadlock graphs in system_health ===';
IF OBJECT_ID('Demo.Graphs') IS NOT NULL DROP TABLE Demo.Graphs;
CREATE TABLE Demo.Graphs (TimestampUtc datetime2(3) NOT NULL, Graph xml NOT NULL);
GO

DECLARE @start datetime2(3) = (SELECT StartedUtc FROM Demo.RunStart);
DECLARE @expected int = (SELECT SUM(Deadlocks) FROM Demo.Outcomes);
DECLARE @t0 datetime2(3) = SYSDATETIME(), @n int = 0;
WHILE DATEDIFF(second, @t0, SYSDATETIME()) < 150
BEGIN
    TRUNCATE TABLE Demo.Graphs;
    INSERT Demo.Graphs (TimestampUtc, Graph)
    SELECT CAST(f.timestamp_utc AS datetime2(3)), x.g.query('.')
    FROM   sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL) AS f
    CROSS APPLY (SELECT CAST(f.event_data AS xml)) AS e (ev)
    CROSS APPLY e.ev.nodes('event/data[@name="xml_report"]/value/deadlock') AS x (g)
    WHERE  f.object_name = N'xml_deadlock_report'
      AND  CAST(f.timestamp_utc AS datetime2(3)) >= @start
      AND  x.g.exist('process-list/process[@currentdbname="DeadlockDemo"]') = 1;
    SET @n = @@ROWCOUNT;
    IF @n >= @expected BREAK;
    WAITFOR DELAY '00:00:05';
END
GO


/*==============================================================================
  Verdicts
==============================================================================*/
-- Which scenario each run tag belongs to, and each side's outcome.
IF OBJECT_ID('tempdb..#o') IS NOT NULL DROP TABLE #o;
SELECT Scenario = LEFT(o.RunTag, CHARINDEX('_', o.RunTag) - 1), o.*
INTO   #o
FROM   Demo.Outcomes AS o;

DECLARE @d varchar(300), @dDemo int, @dWorker int, @att int, @ms int, @it int, @oth nvarchar(200),
        @a1 decimal(12,2), @a2 decimal(12,2);

-- A
SELECT @dDemo = Deadlocks, @ms = ElapsedMs FROM #o WHERE Scenario = 'A' AND Who = 'demo';
SELECT @dWorker = Deadlocks, @oth = OtherError FROM #o WHERE Scenario = 'A' AND Who = 'worker';
SELECT @a1 = Acct1, @a2 = Acct2 FROM Demo.Balances WHERE Scenario = 'A';
SET @d = CONCAT('this session: ', @dDemo, ' deadlock(s), after ', @ms, ' ms; worker: ', @dWorker,
                '; balances ', @a1, ' / ', @a2, ' (the worker''s +10s only)');
INSERT Demo.Verdicts VALUES ('A', 'opposite order deadlocks', @d, 'this session the victim; worker commits',
    CASE WHEN @dDemo = 1 AND @dWorker = 0 AND @oth IS NULL AND @a1 = 1010 AND @a2 = 1010 THEN 'DEADLOCK' ELSE 'unexpected' END);

-- B
SELECT @dDemo = Deadlocks, @ms = ElapsedMs FROM #o WHERE Scenario = 'B' AND Who = 'demo';
SELECT @dWorker = Deadlocks FROM #o WHERE Scenario = 'B' AND Who = 'worker';
SELECT @a1 = Acct1, @a2 = Acct2 FROM Demo.Balances WHERE Scenario = 'B';
SET @d = CONCAT('deadlocks: this session ', @dDemo, ', worker ', @dWorker, '; this session waited ', @ms,
                ' ms; balances ', @a1, ' / ', @a2);
INSERT Demo.Verdicts VALUES ('B', 'same order: wait, don''t deadlock', @d, 'no deadlock; a wait; both changes kept',
    CASE WHEN @dDemo = 0 AND @dWorker = 0 AND @ms >= 1000 AND @a1 = 1011 AND @a2 = 1011 THEN 'WAITED' ELSE 'unexpected' END);

-- C
SELECT @dDemo = Deadlocks FROM #o WHERE Scenario = 'C' AND Who = 'demo';
SELECT @dWorker = Deadlocks FROM #o WHERE Scenario = 'C' AND Who = 'worker';
SELECT @a1 = Acct1 FROM Demo.Balances WHERE Scenario = 'C';
SET @d = CONCAT('deadlocks: this session ', @dDemo, ', worker ', @dWorker, '; account 1 = ', @a1);
INSERT Demo.Verdicts VALUES ('C', 'S-to-X conversion deadlocks on ONE row', @d, 'this session the victim',
    CASE WHEN @dDemo = 1 AND @dWorker = 0 AND @a1 = 1010 THEN 'DEADLOCK' ELSE 'unexpected' END);

-- D
SELECT @dDemo = Deadlocks, @ms = ElapsedMs FROM #o WHERE Scenario = 'D' AND Who = 'demo';
SELECT @dWorker = Deadlocks FROM #o WHERE Scenario = 'D' AND Who = 'worker';
SELECT @a1 = Acct1 FROM Demo.Balances WHERE Scenario = 'D';
SET @d = CONCAT('deadlocks: this session ', @dDemo, ', worker ', @dWorker, '; this session waited ', @ms,
                ' ms; account 1 = ', @a1, ' (1000 + 10 + 1: nothing lost)');
INSERT Demo.Verdicts VALUES ('D', 'UPDLOCK: wait at the read, don''t deadlock', @d, 'no deadlock; 1011',
    CASE WHEN @dDemo = 0 AND @dWorker = 0 AND @ms >= 1000 AND @a1 = 1011 THEN 'WAITED' ELSE 'unexpected' END);

-- E
DECLARE @e1dl int, @e1it int, @e2dl int, @e2it int, @e1w int, @e2w int;
SELECT @e1dl = SUM(Deadlocks), @e1it = MAX(CASE WHEN Who = 'demo' THEN Iterations END),
       @e1w = MAX(CASE WHEN Who = 'worker' THEN Iterations END) FROM #o WHERE Scenario = 'E1';
SELECT @e2dl = SUM(Deadlocks), @e2it = MAX(CASE WHEN Who = 'demo' THEN Iterations END),
       @e2w = MAX(CASE WHEN Who = 'worker' THEN Iterations END) FROM #o WHERE Scenario = 'E2';
SET @d = CONCAT('5 s each: ', @e1dl, ' deadlocks; reader ', @e1it, ' reads, writer ', @e1w, ' updates');
INSERT Demo.Verdicts VALUES ('E', 'key lookup vs update deadlocks', @d, 'deadlocks > 0',
    CASE WHEN @e1dl > 0 THEN 'DEADLOCKS' ELSE 'unexpected' END);
SET @d = CONCAT('5 s each: ', @e2dl, ' deadlocks; reader ', @e2it, ' reads, writer ', @e2w, ' updates');
INSERT Demo.Verdicts VALUES ('E', 'covering index: no lookup, no deadlock', @d, 'no deadlocks; far more work done',
    CASE WHEN @e2dl = 0 AND @e2it > 10 * ISNULL(NULLIF(@e1it, 0), 1) THEN 'NONE' ELSE 'unexpected' END);

-- F
SELECT @dDemo = Deadlocks, @att = Attempts, @oth = OtherError FROM #o WHERE Scenario = 'F' AND Who = 'demo';
SELECT @a1 = Acct1, @a2 = Acct2 FROM Demo.Balances WHERE Scenario = 'F';
SET @d = CONCAT('this session: ', @dDemo, ' deadlock(s), ', @att, ' attempt(s); balances ', @a1, ' / ', @a2);
INSERT Demo.Verdicts VALUES ('F', 'retry on 1205 completes the work', @d, '1 deadlock, 2 attempts; 1011 / 1011',
    CASE WHEN @dDemo = 1 AND @att = 2 AND @oth IS NULL AND @a1 = 1011 AND @a2 = 1011 THEN 'RETRIED' ELSE 'unexpected' END);

-- G
DECLARE @expected int = (SELECT SUM(Deadlocks) FROM Demo.Outcomes), @graphs int = (SELECT COUNT(*) FROM Demo.Graphs);
DECLARE @both int = (SELECT COUNT(*) FROM Demo.Graphs
                     WHERE Graph.exist('deadlock/resource-list/keylock[@indexname="PK_Accounts"]') = 1
                       AND Graph.exist('deadlock/resource-list/keylock[@indexname="IX_Accounts_Ref"]') = 1);
SET @d = CONCAT(@graphs, ' graph(s) for ', @expected, ' deadlock(s); ', @both, ' name both PK_Accounts and IX_Accounts_Ref');
INSERT Demo.Verdicts VALUES ('G', 'system_health kept every graph', @d, 'one graph per deadlock; E''s name both indexes',
    CASE WHEN @graphs = @expected AND @both > 0 THEN 'RECORDED'
         WHEN @graphs < @expected AND @both > 0 THEN 'INCONCLUSIVE'   -- still in the buffers after 150 s
         ELSE 'unexpected' END);
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. HOW EACH SIDE ENDED ===';
GO
SELECT Scenario = LEFT(RunTag, CHARINDEX('_', RunTag) - 1), Who, Attempts, Deadlocks, Iterations, ElapsedMs, OtherError
FROM   Demo.Outcomes
ORDER BY RunTag, Who;
GO

PRINT '';
PRINT '=== 2. THE DEADLOCK GRAPHS, AS system_health RECORDED THEM ===';
GO
-- One row per graph: when, which scenario, who was the victim and what it
-- was running, and every lock in the cycle. Point this at your own instance
-- by removing the date and database filters in scenario G.
SELECT  g.TimestampUtc,
        Scenario = (SELECT TOP (1) LEFT(o.RunTag, CHARINDEX('_', o.RunTag) - 1)
                    FROM Demo.Outcomes AS o
                    WHERE o.Who = 'demo' AND o.StartedUtc <= g.TimestampUtc
                    ORDER BY o.StartedUtc DESC),
        -- The victim's innermost frame: the procedure and the statement that
        -- was waiting. (inputbuf holds the whole batch, which for a script
        -- run with F5 is the top of the file.)
        Victim = CONCAT(REPLACE(v.f.value('@procname', 'nvarchar(200)'), 'DeadlockDemo.', ''), ': ',
                        LEFT(LTRIM(REPLACE(REPLACE(v.f.value('.', 'nvarchar(400)'), CHAR(13), ' '), CHAR(10), ' ')), 70)),
        Locks = STUFF((SELECT '; ' + CONCAT(k.r.value('local-name(.)', 'varchar(20)'), ' ',
                                            k.r.value('@indexname', 'varchar(60)'), ' ',
                                            k.r.value('@mode', 'varchar(10)'))
                       FROM g.Graph.nodes('deadlock/resource-list/*') AS k (r)
                       FOR XML PATH(''), TYPE).value('.', 'varchar(400)'), 1, 2, '')
FROM    Demo.Graphs AS g
OUTER APPLY g.Graph.nodes('deadlock/process-list/process[@id = (../../victim-list/victimProcess/@id)[1]]/executionStack/frame[1]') AS v (f)
ORDER BY g.TimestampUtc;
GO

PRINT '';
PRINT '=== 3. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario, Item DESC;
GO

PRINT '';
PRINT '=== 4. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Detail, Verdict FROM Demo.Verdicts WHERE Verdict IN ('unexpected', 'INCONCLUSIVE');
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 4 should be EMPTY. G can show as INCONCLUSIVE';
PRINT ' if system_health had not flushed every graph to disk in';
PRINT ' time. Anything marked unexpected is a genuine difference';
PRINT ' on your build, worth reading before you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
