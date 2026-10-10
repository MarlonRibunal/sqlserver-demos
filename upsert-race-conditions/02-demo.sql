/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  Four background workers (Service Broker activation; no second window
  needed) run the same "add one, or insert the row if it is new" over the
  same keys at the same moment, once per upsert pattern. Afterwards the
  table is compared with what four correct workers would have left: one row
  per key, and every hit counted. Evidence lands in Demo.Outcomes and
  Demo.Verdicts; the summary at the bottom is the payoff.

  Scenarios
    A  IF EXISTS ... UPDATE ELSE INSERT      -> primary key violations
    B  the same, on a table with no key      -> duplicate rows, and every
                                                later update counts twice
    C  SELECT the value, then UPDATE it      -> lost updates
    D  MERGE, no hint                        -> still a race, just a rare one
    E  MERGE WITH (HOLDLOCK)                 -> exact
    F  UPDATE WITH (UPDLOCK, SERIALIZABLE),
       INSERT if nothing was updated         -> exact, even with the gap
    G  SELECT WITH (UPDLOCK), then UPDATE    -> exact, even with the gap

  A, B, C, F and G pause 10 ms between reading and writing (see
  Demo.usp_Upsert): the stand-in for whatever real code does in between.
  The race exists without it, at a rate of a few in thousands.

  Scenario D can come up empty: the MERGE race needs two sessions inside one
  statement's few microseconds. It runs up to three rounds of 80,000 upserts
  and reports INCONCLUSIVE if none of them lost.

  Expected runtime: one to two minutes.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers,
  Linux container.
==============================================================================*/

USE UpsertDemo;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('Demo.usp_Scenario') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- Let any worker an interrupted earlier run left behind finish (each gives
-- up within a minute), then start clean.
DECLARE @i int = 0;
UPDATE Demo.Control SET GoFlag = 1 WHERE ID = 1;
WHILE EXISTS (SELECT 1 FROM Demo.WorkerResults WITH (NOLOCK) WHERE State = 'ready') AND @i < 1200
BEGIN
    WAITFOR DELAY '00:00:00.100';
    SET @i += 1;
END
DELETE Demo.WorkerResults;
DELETE Demo.Outcomes;
GO

IF OBJECT_ID('Demo.Verdicts') IS NOT NULL DROP TABLE Demo.Verdicts;
CREATE TABLE Demo.Verdicts
(
    Scenario  char(1)       NOT NULL,
    Item      varchar(60)   NOT NULL,
    Detail    varchar(200)  NOT NULL,
    Expected  varchar(60)   NOT NULL,
    Verdict   varchar(20)   NOT NULL
);
GO


/*==============================================================================
  A, B, C -- the three read-first patterns.
==============================================================================*/
PRINT '=== A: IF EXISTS ... UPDATE ELSE INSERT ===';
EXEC Demo.usp_Scenario 'A: check, then insert', 'CHECK_THEN_ACT', 200, 10;
GO
PRINT '=== B: the same, with no unique key ===';
EXEC Demo.usp_Scenario 'B: check, then insert, no key', 'CHECK_THEN_ACT_NOKEY', 200, 10;
GO
PRINT '=== C: read the value, then write it back ===';
EXEC Demo.usp_Scenario 'C: read, then write', 'READ_THEN_WRITE', 200, 10;
GO


/*==============================================================================
  D -- plain MERGE. One statement, but its read and its insert are still two
  steps, and nothing holds the gap between them shut. Up to three rounds.
==============================================================================*/
PRINT '=== D: MERGE, no hint ===';
DECLARE @round int = 1;
WHILE @round <= 3
BEGIN
    EXEC Demo.usp_Scenario 'D: MERGE', 'MERGE', 20000, 0;
    IF (SELECT SUM(PkViolations) FROM Demo.Outcomes WHERE Pattern = 'MERGE') > 0 BREAK;
    SET @round += 1;
END
GO


/*==============================================================================
  E, F, G -- the locked patterns. F and G get the same 10 ms gap as A and C.
==============================================================================*/
PRINT '=== E: MERGE WITH (HOLDLOCK) ===';
EXEC Demo.usp_Scenario 'E: MERGE WITH (HOLDLOCK)', 'MERGE_HOLDLOCK', 5000, 0;
GO
PRINT '=== F: UPDATE WITH (UPDLOCK, SERIALIZABLE), then INSERT ===';
EXEC Demo.usp_Scenario 'F: UPDLOCK, SERIALIZABLE', 'UPDLOCK_SERIALIZABLE', 200, 10;
GO
PRINT '=== G: SELECT WITH (UPDLOCK), then UPDATE ===';
EXEC Demo.usp_Scenario 'G: read WITH (UPDLOCK), then write', 'READ_UPDLOCK_THEN_WRITE', 200, 10;
GO


/*==============================================================================
  Verdicts
==============================================================================*/
-- Every run must have finished, or nothing below means anything.
INSERT Demo.Verdicts
SELECT LEFT(Scenario, 1), 'all four workers finished',
       CONCAT(RunTag, ': ', WorkersDone, ' of 4 done'), '4 of 4',
       CASE WHEN WorkersDone = 4 THEN 'as predicted' ELSE 'unexpected' END
FROM   Demo.Outcomes;

WITH o AS
(
    SELECT Pattern, Keys,
           Scenario = CASE Pattern WHEN 'CHECK_THEN_ACT' THEN 'A' WHEN 'CHECK_THEN_ACT_NOKEY' THEN 'B'
                                   WHEN 'READ_THEN_WRITE' THEN 'C' WHEN 'MERGE' THEN 'D'
                                   WHEN 'MERGE_HOLDLOCK' THEN 'E' WHEN 'UPDLOCK_SERIALIZABLE' THEN 'F' ELSE 'G' END,
           Rounds = COUNT(*), Upserts = SUM(Upserts),
           RowsLeft = MAX(RowsLeft), DistinctKeys = MAX(DistinctKeys),   -- the last round's table
           TotalHits = MAX(TotalHits), ExpectedHits = MAX(ExpectedHits),
           Pk = SUM(PkViolations), Dl = SUM(Deadlocks), Other = SUM(OtherErrors)
    FROM   Demo.Outcomes
    GROUP BY Pattern, Keys
)
INSERT Demo.Verdicts (Scenario, Item, Detail, Expected, Verdict)
SELECT o.Scenario,
       CASE o.Scenario
            WHEN 'A' THEN 'check-then-insert races'
            WHEN 'B' THEN 'no key: duplicates go in silently'
            WHEN 'C' THEN 'read-then-write loses updates'
            WHEN 'D' THEN 'plain MERGE still races'
            WHEN 'E' THEN 'MERGE WITH (HOLDLOCK) is exact'
            WHEN 'F' THEN 'UPDLOCK, SERIALIZABLE is exact'
            ELSE          'read WITH (UPDLOCK) is exact' END,
       CONCAT(o.Upserts, ' upserts in ', o.Rounds, ' round(s); last round: ', o.RowsLeft, ' rows for ',
              o.DistinctKeys, ' keys, hits ', o.TotalHits, ' of ', o.ExpectedHits,
              '; PK violations ', o.Pk, ', deadlocks ', o.Dl, ', other errors ', o.Other),
       CASE o.Scenario
            WHEN 'A' THEN 'PK violations > 0'
            WHEN 'B' THEN 'rows > keys, no errors'
            WHEN 'C' THEN 'hits < expected, no errors'
            WHEN 'D' THEN 'PK violations > 0'
            ELSE          'exact, no errors' END,
       CASE
            -- A: the key catches the race, as an error the application sees.
            WHEN o.Scenario = 'A' THEN CASE WHEN o.Pk > 0 AND o.RowsLeft = o.DistinctKeys AND o.Other = 0
                                            THEN 'as predicted' ELSE 'unexpected' END
            -- B: nothing catches it.
            WHEN o.Scenario = 'B' THEN CASE WHEN o.RowsLeft > o.DistinctKeys AND o.Pk + o.Other = 0
                                            THEN 'as predicted' ELSE 'unexpected' END
            -- C: no error either; the count is just wrong.
            WHEN o.Scenario = 'C' THEN CASE WHEN o.TotalHits < o.ExpectedHits AND o.Pk + o.Other = 0
                                            THEN 'as predicted' ELSE 'unexpected' END
            WHEN o.Scenario = 'D' THEN CASE WHEN o.Pk > 0 AND o.Other = 0 THEN 'as predicted'
                                            WHEN o.Pk = 0 AND o.Other = 0 THEN 'INCONCLUSIVE'
                                            ELSE 'unexpected' END
            -- E, F, G: exactly right, and nothing to retry.
            ELSE CASE WHEN o.RowsLeft = o.Keys AND o.DistinctKeys = o.Keys AND o.TotalHits = o.ExpectedHits
                           AND o.Pk + o.Dl + o.Other = 0
                      THEN 'as predicted' ELSE 'unexpected' END
       END
FROM   o;
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. WHAT EACH PATTERN LEFT BEHIND ===';
GO
SELECT Scenario, GapMs, Upserts, RowsLeft, DistinctKeys, TotalHits, ExpectedHits,
       PkViolations, Deadlocks, OtherErrors, SlowestWorkerMs = ElapsedMs, LastError
FROM   Demo.Outcomes
ORDER BY Scenario, RunTag;
GO

PRINT '';
PRINT '=== 2. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario, Item;
GO

PRINT '';
PRINT '=== 3. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Detail, Verdict FROM Demo.Verdicts WHERE Verdict <> 'as predicted';
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 3 should be EMPTY. D can show as INCONCLUSIVE:';
PRINT ' the plain MERGE race is real but rare, and some runs miss';
PRINT ' it. Anything marked unexpected is a genuine difference on';
PRINT ' your build, worth reading before you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
