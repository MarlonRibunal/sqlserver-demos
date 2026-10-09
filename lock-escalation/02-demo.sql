/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  Every probe runs a statement inside a transaction, records the locks this
  session holds, then ROLLS BACK -- so no data changes and the file can be
  re-run. All evidence lands in Demo.LockSnapshots. The summary at the bottom
  is the payoff.

  Scenarios
    A  the threshold          -> where an UPDATE stops holding thousands of
                                 key locks and holds one table lock instead
    B  per statement          -> four big statements in one transaction:
                                 20,000 locks, no escalation
    C  hints                  -> ROWLOCK does not prevent escalation;
                                 PAGLOCK avoids it by taking fewer locks
    D  readers escalate too   -> REPEATABLE READ takes a SHARED table lock
    E  the table option       -> DISABLE: no escalation, every lock kept;
                                 AUTO on a partitioned table: the partition
                                 is locked, not the table

  Expected runtime: about ten seconds.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers.
==============================================================================*/

USE LockEscalationDemo;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('Demo.usp_Probe') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

TRUNCATE TABLE Demo.LockSnapshots;
GO


/*==============================================================================
  SCENARIO A -- the threshold

  UPDATE the first N rows of Demo.Items for a range of N, and look at what the
  session holds afterwards. Below the threshold: one KEY lock per row, an
  intent lock (IX) on each page touched, IX on the table. Above it: one X
  lock on the whole table, and nothing else.

  Documentation and folklore both say 5,000 locks. The sweep runs past that
  in steps of 100 rows, then in steps of 10 around wherever escalation
  actually happened, so the boundary is measured rather than assumed.

  What it means: the statement above the line holds ONE lock instead of
  thousands -- cheaper for the lock manager -- and in exchange no other
  session can read or write ANY row of the table until this transaction
  ends. That second half is the cost, and it is why escalation is worth
  knowing about.

  A DELETE of 7,000 rows is probed too, to show it is not peculiar to UPDATE.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO A: the threshold ---';
GO

DECLARE @n int = 1000, @sql nvarchar(400), @label varchar(90);

-- Coarse: 1,000 to 7,000 rows, every 100 from 4,000 up.
WHILE @n <= 7000
BEGIN
    SET @sql   = N'UPDATE Demo.Items SET Qty = Qty + 1 WHERE ItemID <= ' + CAST(@n AS nvarchar(10))
               + N'; SET @rc = @@ROWCOUNT;';
    SET @label = 'UPDATE ' + CAST(@n AS varchar(10)) + ' rows';
    EXEC Demo.usp_Probe 'A. Threshold', @n, @label, 'Demo.Items', @sql;
    SET @n += CASE WHEN @n < 4000 THEN 1000 ELSE 100 END;
END

-- Fine: every 10 rows across the 100-row step where escalation first appeared.
DECLARE @firstEsc int =
    (SELECT MIN(StepNo) FROM Demo.LockSnapshots WHERE Scenario = 'A. Threshold' AND ObjectMode = 'X');

IF @firstEsc IS NOT NULL
BEGIN
    SET @n = @firstEsc - 90;
    WHILE @n < @firstEsc
    BEGIN
        SET @sql   = N'UPDATE Demo.Items SET Qty = Qty + 1 WHERE ItemID <= ' + CAST(@n AS nvarchar(10))
                   + N'; SET @rc = @@ROWCOUNT;';
        SET @label = 'UPDATE ' + CAST(@n AS varchar(10)) + ' rows';
        EXEC Demo.usp_Probe 'A. Threshold', @n, @label, 'Demo.Items', @sql;
        SET @n += 10;
    END
END

EXEC Demo.usp_Probe 'A. Threshold', 100000, 'DELETE 7000 rows', 'Demo.Items',
     N'DELETE Demo.Items WHERE ItemID <= 7000; SET @rc = @@ROWCOUNT;',
     'escalates like the UPDATE';
GO


/*==============================================================================
  SCENARIO B -- the threshold is per statement, not per transaction

  Four UPDATEs of 5,000 rows each, one after another in ONE transaction. Each
  statement stays under the threshold, so none escalates -- and the
  transaction ends up holding over 20,000 locks.

  This is also why batching works: a purge that deletes 5,000 rows per
  statement never escalates, whether or not it commits between batches.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO B: per statement ---';
GO

EXEC Demo.usp_Probe 'B. Per statement', 1, '4 x UPDATE 5000 rows, one transaction', 'Demo.Items',
     N'UPDATE Demo.Items SET Qty = Qty + 1 WHERE ItemID BETWEEN     1 AND  5000;
       UPDATE Demo.Items SET Qty = Qty + 1 WHERE ItemID BETWEEN  5001 AND 10000;
       UPDATE Demo.Items SET Qty = Qty + 1 WHERE ItemID BETWEEN 10001 AND 15000;
       UPDATE Demo.Items SET Qty = Qty + 1 WHERE ItemID BETWEEN 15001 AND 20000;
       SET @rc = 20000;',
     'no escalation; 20,000+ locks held';
GO


/*==============================================================================
  SCENARIO C -- hints

  WITH (ROWLOCK) is often added "to stop lock escalation". It does not: it
  tells the engine which granularity to START with. 7,000 row locks are still
  over the threshold, and the statement escalates exactly as before.

  WITH (PAGLOCK) avoids escalation the other way: by taking about one lock per
  page (~37 rows) instead of one per row, it never gets near the threshold.
  The price is coarser locking from the start.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO C: hints ---';
GO

EXEC Demo.usp_Probe 'C. Hints', 1, 'UPDATE 7000 rows WITH (ROWLOCK)', 'Demo.Items',
     N'UPDATE Demo.Items WITH (ROWLOCK) SET Qty = Qty + 1 WHERE ItemID <= 7000; SET @rc = @@ROWCOUNT;',
     'escalates anyway';
EXEC Demo.usp_Probe 'C. Hints', 2, 'UPDATE 7000 rows WITH (PAGLOCK)', 'Demo.Items',
     N'UPDATE Demo.Items WITH (PAGLOCK) SET Qty = Qty + 1 WHERE ItemID <= 7000; SET @rc = @@ROWCOUNT;',
     'page locks only; no escalation';
GO


/*==============================================================================
  SCENARIO D -- readers escalate too

  Under the default READ COMMITTED, a SELECT releases each shared lock as it
  moves on, so it never accumulates enough to escalate: after reading 50,000
  rows it holds nothing.

  Under REPEATABLE READ (or SERIALIZABLE, or a HOLDLOCK hint) shared locks are
  KEPT until the transaction ends -- so a reader can cross the threshold and
  escalate to a SHARED lock on the table. Nobody can then modify any row of
  it until the reader commits.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO D: readers ---';
GO

EXEC Demo.usp_Probe 'D. Readers', 1, 'SELECT 50000 rows, READ COMMITTED', 'Demo.Items',
     N'DECLARE @c int; SELECT @c = COUNT(*) FROM Demo.Items WHERE ItemID <= 50000; SET @rc = 50000;',
     'no locks held after the statement';
EXEC Demo.usp_Probe 'D. Readers', 2, 'SELECT 7000 rows WITH (REPEATABLEREAD)', 'Demo.Items',
     N'DECLARE @c int; SELECT @c = COUNT(*) FROM Demo.Items WITH (REPEATABLEREAD) WHERE ItemID <= 7000; SET @rc = 7000;',
     'shared TABLE lock';
GO


/*==============================================================================
  SCENARIO E -- the table option

  LOCK_ESCALATION is a property of the table (ALTER TABLE ... SET), set in
  setup on tables this demo owns:

     DISABLE  the statement keeps every row lock. 20,000 rows: 20,000+ locks,
              no escalation. Concurrency is preserved; lock memory is spent
              instead. (Escalation can still happen in rare cases, such as a
              table hint that demands it.)

     AUTO     on a PARTITIONED table, escalation goes to the partition (a
              HOBT lock) instead of the table. Rows in other partitions stay
              available. An update spanning two partitions escalates each one
              separately; the table itself keeps only an intent lock.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO E: LOCK_ESCALATION ---';
GO

EXEC Demo.usp_Probe 'E. Table option', 1, 'DISABLE: UPDATE 20000 rows', 'Demo.ItemsDisabled',
     N'UPDATE Demo.ItemsDisabled SET Qty = Qty + 1 WHERE ItemID <= 20000; SET @rc = @@ROWCOUNT;',
     'no escalation; every lock kept';
EXEC Demo.usp_Probe 'E. Table option', 2, 'AUTO: UPDATE 20000 rows, one partition', 'Demo.ItemsPartitioned',
     N'UPDATE Demo.ItemsPartitioned SET Qty = Qty + 1 WHERE ItemID <= 20000; SET @rc = @@ROWCOUNT;',
     'X on one partition; table only IX';
EXEC Demo.usp_Probe 'E. Table option', 3, 'AUTO: UPDATE 20000 rows, two partitions', 'Demo.ItemsPartitioned',
     N'UPDATE Demo.ItemsPartitioned SET Qty = Qty + 1 WHERE ItemID BETWEEN 15001 AND 35000; SET @rc = @@ROWCOUNT;',
     'X on two partitions; table only IX';
GO


/*==============================================================================
  VERDICTS
==============================================================================*/
-- A: every probe below the boundary held key locks under IX; every probe at
-- or above it held a single table X lock.
DECLARE @lastRow int =
    (SELECT MAX(StepNo) FROM Demo.LockSnapshots
     WHERE  Scenario = 'A. Threshold' AND StepNo < 100000 AND ObjectMode = 'IX');
DECLARE @firstRow int =
    (SELECT MIN(StepNo) FROM Demo.LockSnapshots
     WHERE  Scenario = 'A. Threshold' AND StepNo < 100000 AND ObjectMode = 'X');

UPDATE Demo.LockSnapshots
SET    Verdict = CASE WHEN ObjectMode = 'IX' AND StepNo < @firstRow AND Escalations = 0 THEN 'ROW LOCKS'
                      WHEN ObjectMode = 'X'  AND StepNo >= @firstRow AND Escalations = 1 AND TotalLocks = 1 THEN 'ESCALATED'
                      ELSE 'unexpected' END,
       Expected = COALESCE(Expected, CASE WHEN StepNo < @firstRow THEN 'row locks' ELSE 'table X lock' END)
WHERE  Scenario = 'A. Threshold';

-- The sweep must find a boundary at all, and only one.
IF @firstRow IS NULL OR @lastRow > @firstRow
    UPDATE Demo.LockSnapshots SET Verdict = 'unexpected' WHERE Scenario = 'A. Threshold';

UPDATE Demo.LockSnapshots
SET    Verdict = CASE WHEN Escalations = 0 AND KeyLocks >= 20000 THEN 'NO ESCALATION' ELSE 'unexpected' END
WHERE  Scenario = 'B. Per statement';

UPDATE Demo.LockSnapshots
SET    Verdict = CASE WHEN StepNo = 1 AND ObjectMode = 'X'  AND Escalations = 1                     THEN 'ESCALATED ANYWAY'
                      WHEN StepNo = 2 AND ObjectMode = 'IX' AND Escalations = 0 AND KeyLocks = 0    THEN 'PAGE LOCKS ONLY'
                      ELSE 'unexpected' END
WHERE  Scenario = 'C. Hints';

UPDATE Demo.LockSnapshots
SET    Verdict = CASE WHEN StepNo = 1 AND TotalLocks = 0                                 THEN 'NOTHING HELD'
                      WHEN StepNo = 2 AND ObjectMode = 'S' AND Escalations = 1           THEN 'TABLE S LOCK'
                      ELSE 'unexpected' END
WHERE  Scenario = 'D. Readers';

UPDATE Demo.LockSnapshots
SET    Verdict = CASE WHEN StepNo = 1 AND Escalations = 0 AND KeyLocks >= 20000                         THEN 'NO ESCALATION'
                      WHEN StepNo = 2 AND ObjectMode = 'IX' AND HobtLocks = 1 AND HobtModes = 'X'       THEN 'PARTITION X LOCK'
                      WHEN StepNo = 3 AND ObjectMode = 'IX' AND HobtLocks = 2 AND HobtModes = 'X'       THEN 'PARTITION X LOCKS'
                      ELSE 'unexpected' END
WHERE  Scenario = 'E. Table option';
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. SCENARIO A: the boundary ===';
GO
SELECT  LastRowLockProbe  = MAX(CASE WHEN ObjectMode = 'IX' THEN StepNo END),
        LocksHeldThere    = MAX(CASE WHEN ObjectMode = 'IX' THEN TotalLocks END),
        FirstEscalated    = MIN(CASE WHEN ObjectMode = 'X'  THEN StepNo END)
FROM    Demo.LockSnapshots
WHERE   Scenario = 'A. Threshold' AND StepNo < 100000;
GO

PRINT '';
PRINT '=== 2. SCENARIO A: the sweep ===';
GO
SELECT  Label, RowsTouched, KeyLocks, PageLocks, TableLock = ObjectMode, TotalLocks, Escalations, Verdict
FROM    Demo.LockSnapshots
WHERE   Scenario = 'A. Threshold'
ORDER BY StepNo;
GO

PRINT '';
PRINT '=== 3. SCENARIOS B to E ===';
GO
SELECT  Scenario, Label, RowsTouched, KeyLocks, PageLocks, TableLock = ObjectMode,
        PartitionLocks = HobtLocks, PartitionMode = HobtModes, TotalLocks, Escalations, Expected, Verdict
FROM    Demo.LockSnapshots
WHERE   Scenario <> 'A. Threshold'
ORDER BY Scenario, StepNo;
GO

PRINT '';
PRINT '=== 4. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Label, KeyLocks, ObjectMode, TotalLocks, Escalations, Verdict
FROM   Demo.LockSnapshots
WHERE  Verdict = 'unexpected' OR Verdict IS NULL;
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 4 should be EMPTY. Anything in it is either';
PRINT ' a genuine difference on your build, or another session';
PRINT ' holding locks on these tables -- both are worth';
PRINT ' reading before you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
