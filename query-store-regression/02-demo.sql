/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  A query regresses, and Query Store is used to see it, fix it, and watch the
  fix break. Evidence lands in Demo.Calls, Demo.QsPlans and Demo.Verdicts;
  the summary at the bottom is the payoff.

  Scenarios
    A  the good plan          -> small customers, a seek: a few dozen reads
    B  the regression         -> one recompile at the wrong moment, and every
                                 small customer now scans
    C  forcing the good plan  -> sp_query_store_force_plan: back to a seek,
                                 whoever is asked for first
    D  forcing breaks         -> drop the index the forced plan needs: the
                                 query still runs, Query Store records why
                                 forcing failed
    E  a Query Store hint     -> SQL Server 2022+: add OPTION (RECOMPILE) to
                                 the query without touching its code

  This file clears QueryStoreDemo's own Query Store at the start, and puts
  the index, forcing and hints back as setup left them at the end.

  Expected runtime: about ten seconds.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), compatibility
  level 160.
==============================================================================*/

USE QueryStoreDemo;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('Demo.usp_QsSnapshot') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- Back to setup's state, whatever a previous run left: index present,
-- nothing forced, no hints, an empty Query Store.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('Demo.Orders') AND name = 'IX_Orders_CustomerID')
    CREATE INDEX IX_Orders_CustomerID ON Demo.Orders (CustomerID);
ALTER DATABASE CURRENT SET QUERY_STORE CLEAR;
GO
TRUNCATE TABLE Demo.Calls;
TRUNCATE TABLE Demo.QsPlans;
DROP TABLE IF EXISTS Demo.Verdicts;
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
  SCENARIO A -- the good plan

  Compiled for a small customer (45, 15 orders): seek on IX_Orders_CustomerID
  and look up each row. Twenty calls, a few dozen reads each.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO A: the good plan ---';
GO

EXEC sys.sp_recompile N'Demo.usp_CustomerSummary';
EXEC Demo.usp_Call 'A. Good plan', 45, 20;
EXEC Demo.usp_QsSnapshot 'A. good plan';
GO


/*==============================================================================
  SCENARIO B -- the regression

  The plan is evicted (here: sp_recompile; in real life: a restart, memory
  pressure, a statistics update), and the next call happens to be for
  customer 1, with 300,000 orders. That call compiles a scan -- right for
  customer 1 -- and every small customer after it gets the scan too.

  Query Store now holds two plans for the same query, with the evidence: the
  same query, the same small customers, and one plan costs hundreds of times
  the reads of the other. That is the comparison the "Regressed Queries"
  report in SSMS makes.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO B: the regression ---';
GO

EXEC sys.sp_recompile N'Demo.usp_CustomerSummary';
EXEC Demo.usp_Call 'B. Regression', 1, 1;        -- the unlucky first call
EXEC Demo.usp_Call 'B. Regression', 45, 20;
EXEC Demo.usp_QsSnapshot 'B. regressed';
GO

DECLARE @plans int = (SELECT COUNT(*) FROM Demo.QsPlans WHERE Label = 'B. regressed');
DECLARE @goodReads decimal(18,1) = (SELECT AVG(LogicalReads * 1.0) FROM Demo.Calls WHERE Scenario = 'A. Good plan');
DECLARE @badReads  decimal(18,1) = (SELECT AVG(LogicalReads * 1.0) FROM Demo.Calls WHERE Scenario = 'B. Regression' AND CustomerID = 45);
DECLARE @d nvarchar(300) = CAST(@plans AS nvarchar(10)) + N' plans in Query Store; customer 45 averaged '
    + CAST(@goodReads AS nvarchar(20)) + N' reads before, ' + CAST(@badReads AS nvarchar(20)) + N' after';
INSERT Demo.Verdicts VALUES ('B. Regression', 'the same calls for customer 45, before and after', @d,
    'two plans; the new one costs far more',
    CASE WHEN @plans = 2 AND @badReads >= @goodReads * 20 THEN 'REGRESSED' ELSE 'unexpected' END);
GO


/*==============================================================================
  SCENARIO C -- forcing the good plan

  sys.sp_query_store_force_plan pins the query to the plan Query Store has
  recorded. From then on, whatever compiles it, it gets that plan -- even if
  the first call after the next recompile is customer 1 again.

  That is the trade forcing makes: small customers are fast again, and
  customer 1 now pays for a seek plus 300,000 lookups. Forcing fixes the
  common case at the expense of the rare one; the parameter-sniffing topic
  covers the alternatives.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO C: forcing the good plan ---';
GO

DECLARE @q bigint, @good bigint;
EXEC Demo.usp_QueryId @q OUTPUT;
SELECT @good = PlanID FROM Demo.QsPlans WHERE Label = 'A. good plan';
EXEC sys.sp_query_store_force_plan @query_id = @q, @plan_id = @good;
GO

EXEC sys.sp_recompile N'Demo.usp_CustomerSummary';
EXEC Demo.usp_Call 'C. Forced', 1, 1;            -- the same unlucky first call
EXEC Demo.usp_Call 'C. Forced', 45, 20;
EXEC Demo.usp_QsSnapshot 'C. forced';
GO

-- Counted by plan SHAPE, not plan_id: on the tested build the forced
-- executions were recorded under a NEW plan_id with the same shape -- the
-- plan recompiled under forcing, not the stored one byte for byte.
DECLARE @good bigint = (SELECT PlanID FROM Demo.QsPlans WHERE Label = 'A. good plan');
DECLARE @forced bit = (SELECT IsForced FROM Demo.QsPlans WHERE Label = 'C. forced' AND PlanID = @good);
DECLARE @runsBefore bigint = (SELECT SUM(Executions) FROM Demo.QsPlans WHERE Label = 'B. regressed' AND PlanShape = 'seek + lookups');
DECLARE @runsAfter  bigint = (SELECT SUM(Executions) FROM Demo.QsPlans WHERE Label = 'C. forced'    AND PlanShape = 'seek + lookups');
DECLARE @small decimal(18,1) = (SELECT AVG(LogicalReads * 1.0) FROM Demo.Calls WHERE Scenario = 'C. Forced' AND CustomerID = 45);
DECLARE @whale bigint        = (SELECT MAX(LogicalReads) FROM Demo.Calls WHERE Scenario = 'C. Forced' AND CustomerID = 1);
DECLARE @d nvarchar(300) = N'plan ' + CAST(@good AS nvarchar(10)) + N' forced: ' + CASE @forced WHEN 1 THEN N'yes' ELSE N'NO' END
    + N'; seek + lookups ran ' + CAST(@runsAfter - ISNULL(@runsBefore, 0) AS nvarchar(10)) + N' more times; customer 45 averaged '
    + CAST(@small AS nvarchar(20)) + N' reads; customer 1 cost ' + CAST(@whale AS nvarchar(20));
INSERT Demo.Verdicts VALUES ('C. Forcing', 'force the good plan, then recompile with customer 1 first', @d,
    'all 21 calls use the forced plan; small customers fast again',
    CASE WHEN @forced = 1 AND @runsAfter - ISNULL(@runsBefore, 0) = 21
              AND @small <= (SELECT AVG(LogicalReads * 1.0) FROM Demo.Calls WHERE Scenario = 'A. Good plan') * 1.5
         THEN 'PLAN FORCED' ELSE 'unexpected' END);
GO


/*==============================================================================
  SCENARIO D -- forcing breaks

  A forced plan is a recipe that names specific objects. Drop the index it
  uses and the recipe can no longer be followed. The query does not fail --
  SQL Server compiles a plan of its own and runs it -- but forcing has
  silently stopped working, and the only record of it is in Query Store:
  force_failure_count and last_force_failure_reason_desc on the plan.

  Worth checking after any index change on a database that forces plans.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO D: forcing breaks ---';
GO

DROP INDEX IX_Orders_CustomerID ON Demo.Orders;
GO
EXEC Demo.usp_Call 'D. Forcing broken', 45, 5;
EXEC Demo.usp_QsSnapshot 'D. index dropped';
GO

DECLARE @good bigint = (SELECT PlanID FROM Demo.QsPlans WHERE Label = 'A. good plan');
DECLARE @fails bigint, @reason nvarchar(60);
SELECT @fails = ForceFailures, @reason = LastFailure FROM Demo.QsPlans WHERE Label = 'D. index dropped' AND PlanID = @good;
DECLARE @ok int = (SELECT SUM(CAST(Succeeded AS int)) FROM Demo.Calls WHERE Scenario = 'D. Forcing broken');
DECLARE @d nvarchar(300) = CAST(@ok AS nvarchar(10)) + N' of 5 calls succeeded; force_failure_count '
    + CAST(ISNULL(@fails, 0) AS nvarchar(10)) + N', last_force_failure_reason_desc ' + ISNULL(@reason, N'none');
INSERT Demo.Verdicts VALUES ('D. Forcing breaks', 'drop the index the forced plan uses', @d,
    'the query still runs; Query Store records NO_INDEX',
    CASE WHEN @ok = 5 AND @fails > 0 AND @reason = N'NO_INDEX' THEN 'SILENT FAILURE' ELSE 'unexpected' END);
GO

CREATE INDEX IX_Orders_CustomerID ON Demo.Orders (CustomerID);
GO
DECLARE @q bigint, @good bigint;
EXEC Demo.usp_QueryId @q OUTPUT;
SELECT @good = PlanID FROM Demo.QsPlans WHERE Label = 'A. good plan';
EXEC sys.sp_query_store_unforce_plan @query_id = @q, @plan_id = @good;
GO


/*==============================================================================
  SCENARIO E -- a Query Store hint (SQL Server 2022+)

  sys.sp_query_store_set_hints attaches query hints to a query by its
  query_id -- no change to the procedure, which matters when the code
  belongs to a vendor. Here: OPTION (RECOMPILE), so every call is compiled
  for its own customer. Customer 1 first, then customer 45: each gets its
  own plan, and customer 45 is fast again without any plan being forced.

  On SQL Server 2019 and earlier the procedure does not exist; the scenario
  reports SKIPPED.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO E: a Query Store hint ---';
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) < 16
    INSERT Demo.Verdicts VALUES ('E. Query Store hint', 'OPTION (RECOMPILE) attached by query_id',
        N'Query Store hints need SQL Server 2022 or later', 'not available before 2022', 'SKIPPED');
ELSE
BEGIN
    DECLARE @q bigint;
    EXEC Demo.usp_QueryId @q OUTPUT;
    EXEC sys.sp_query_store_set_hints @query_id = @q, @query_hints = N'OPTION (RECOMPILE)';
END
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16
BEGIN
    EXEC sys.sp_recompile N'Demo.usp_CustomerSummary';
    EXEC Demo.usp_Call 'E. Hinted', 1, 1;
    EXEC Demo.usp_Call 'E. Hinted', 45, 20;

END
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16
BEGIN
    DECLARE @q bigint;
    EXEC Demo.usp_QueryId @q OUTPUT;
    DECLARE @hint nvarchar(200);
    EXEC sys.sp_executesql N'SELECT @h = query_hint_text FROM sys.query_store_query_hints WHERE query_id = @q',
         N'@q bigint, @h nvarchar(200) OUTPUT', @q = @q, @h = @hint OUTPUT;
    DECLARE @small decimal(18,1) = (SELECT AVG(LogicalReads * 1.0) FROM Demo.Calls WHERE Scenario = 'E. Hinted' AND CustomerID = 45);
    DECLARE @whale bigint        = (SELECT MAX(LogicalReads) FROM Demo.Calls WHERE Scenario = 'E. Hinted' AND CustomerID = 1);
    DECLARE @scan  bigint        = (SELECT MAX(LogicalReads) FROM Demo.Calls WHERE Scenario = 'B. Regression' AND CustomerID = 1);
    DECLARE @good  decimal(18,1) = (SELECT AVG(LogicalReads * 1.0) FROM Demo.Calls WHERE Scenario = 'A. Good plan');
    DECLARE @d nvarchar(300) = N'hint "' + ISNULL(@hint, N'none') + N'"; customer 45 averaged ' + CAST(@small AS nvarchar(20))
        + N' reads; customer 1 cost ' + CAST(@whale AS nvarchar(20)) + N' (a scan: ' + CAST(@scan AS nvarchar(20)) + N')';
    INSERT Demo.Verdicts VALUES ('E. Query Store hint', 'OPTION (RECOMPILE) attached by query_id', @d,
        'each call planned for its own customer; no code change',
        CASE WHEN @hint LIKE N'%RECOMPILE%' AND @small <= @good * 3 AND @whale <= @scan * 1.5 THEN 'HINT APPLIED' ELSE 'unexpected' END);

    EXEC sys.sp_query_store_clear_hints @query_id = @q;
END
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. QUERY STORE PLANS AT EACH STEP ===';
GO
SELECT Label, PlanID, PlanShape, Executions, AvgReads, IsForced, ForceFailures, LastFailure
FROM   Demo.QsPlans ORDER BY CapturedAt, PlanID;
GO

PRINT '';
PRINT '=== 2. AVERAGE READS PER CALL ===';
GO
SELECT Scenario, CustomerID, Calls = COUNT(*), AvgReads = AVG(LogicalReads), Failed = SUM(1 - CAST(Succeeded AS int))
FROM   Demo.Calls GROUP BY Scenario, CustomerID ORDER BY MIN(CallID);
GO

PRINT '';
PRINT '=== 3. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario;
GO

PRINT '';
PRINT '=== 4. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Detail, Verdict FROM Demo.Verdicts WHERE Verdict IN ('unexpected', 'SKIPPED');
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 4 should be EMPTY. On SQL Server 2019 or';
PRINT ' earlier, scenario E appears there as SKIPPED: Query Store';
PRINT ' hints arrived in 2022. Anything else in it is a genuine';
PRINT ' difference on your build.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
