/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  One session plays both parts. "The app" is this session with ARITHABORT
  OFF -- the default for ADO.NET, ODBC, JDBC and most other drivers. "SSMS"
  is this session with ARITHABORT ON -- the SSMS default. Every change of
  the setting is a SET statement in this file, affecting this session only.

  Scenarios
    A  the complaint         -> the same call, slow from the app, fast in SSMS
    B  why                   -> two cached plans, keyed by set_options, each
                                sniffed for a different customer
    C  ARITHABORT is innocent -> sniff the same values in the same order and
                                SSMS is just as slow; reverse the order and
                                the app is fast
    D  finding it            -> the plan cache query that shows it

  Expected runtime: a few seconds.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4555.1), 8 schedulers.
==============================================================================*/

USE SetOptionsDemo;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('Demo.usp_Call') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

TRUNCATE TABLE Demo.Calls;
TRUNCATE TABLE Demo.CachedPlans;
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

-- Start clean: every cached plan for the procedure, under any SET options,
-- is discarded. Object scoped -- nothing else in the plan cache is touched.
EXEC sys.sp_recompile N'Demo.usp_CustomerSummary';
GO


/*==============================================================================
  SCENARIO A -- the complaint

  Overnight, the app ran the procedure for customer 1 (300,000 orders): the
  first call after the plan was evicted. Its plan is a scan -- right for
  customer 1.

  This morning a user complains that customer 45's page is slow. The app
  calls the procedure for customer 45 and reuses the scan.

  A developer opens SSMS, runs EXEC Demo.usp_CustomerSummary 45, and it is
  instant. "It's fast for me."
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO A: slow in the app, fast in SSMS ---';
GO

SET ARITHABORT OFF;      -- the app's connection
GO
EXEC Demo.usp_Call 'A. The complaint', 1, 1;     -- overnight: customer 1, compiles
EXEC Demo.usp_Call 'A. The complaint', 2, 45;    -- this morning: customer 45, reuses
GO

SET ARITHABORT ON;       -- SSMS
GO
EXEC Demo.usp_Call 'A. The complaint', 3, 45;    -- the developer tries it
GO

EXEC Demo.usp_SnapshotPlans 'A. The complaint', 3;
GO

DECLARE @app bigint  = (SELECT LogicalReads FROM Demo.Calls WHERE Scenario = 'A. The complaint' AND StepNo = 2);
DECLARE @ssms bigint = (SELECT LogicalReads FROM Demo.Calls WHERE Scenario = 'A. The complaint' AND StepNo = 3);
DECLARE @d nvarchar(300) = N'customer 45: app ' + CAST(@app AS nvarchar(20)) + N' reads, SSMS ' + CAST(@ssms AS nvarchar(20))
    + N' reads (' + CAST(CAST(@app * 1.0 / NULLIF(@ssms, 0) AS decimal(10,0)) AS nvarchar(20)) + N'x)';
INSERT Demo.Verdicts VALUES ('A. The complaint', 'the same call for customer 45', @d, 'app far slower than SSMS',
    CASE WHEN @app >= @ssms * 20 THEN 'SLOW IN APP' ELSE 'unexpected' END);
GO


/*==============================================================================
  SCENARIO B -- why

  SET options are part of the plan cache key. A connection with ARITHABORT
  OFF and one with ARITHABORT ON cannot share a plan, so when SSMS ran the
  procedure it did not find the app's plan at all. It compiled its own --
  sniffing customer 45, and choosing a seek.

  The cache now holds the procedure twice: one plan per set_options value,
  each compiled for a different customer.
==============================================================================*/
DECLARE @plans int = (SELECT COUNT(*) FROM Demo.CachedPlans WHERE Scenario = 'A. The complaint');
DECLARE @offFor nvarchar(40), @offShape varchar(30), @onFor nvarchar(40), @onShape varchar(30);
SELECT @offFor = CompiledFor, @offShape = PlanShape FROM Demo.CachedPlans WHERE Scenario = 'A. The complaint' AND ArithAbortOn = 0;
SELECT @onFor  = CompiledFor, @onShape  = PlanShape FROM Demo.CachedPlans WHERE Scenario = 'A. The complaint' AND ArithAbortOn = 1;

DECLARE @d nvarchar(300) = CAST(@plans AS nvarchar(10)) + N' plans cached. ARITHABORT OFF: compiled for '
    + ISNULL(@offFor, N'?') + N', ' + ISNULL(@offShape, N'?') + N'. ARITHABORT ON: compiled for '
    + ISNULL(@onFor, N'?') + N', ' + ISNULL(@onShape, N'?') + N'.';
INSERT Demo.Verdicts VALUES ('B. Why', 'cached plans for Demo.usp_CustomerSummary', @d,
    'two plans, one per set_options, sniffed for 1 and 45',
    CASE WHEN @plans = 2 AND @offFor = N'(1)' AND @onFor = N'(45)'
              AND @offShape = 'clustered scan' AND @onShape = 'seek + lookups' THEN 'TWO PLANS' ELSE 'unexpected' END);
GO


/*==============================================================================
  SCENARIO C -- ARITHABORT is innocent

  The tempting fix is "set ARITHABORT ON in the app". This scenario shows
  why that only moves the lottery.

     C1  SSMS (ARITHABORT ON), after a recompile, sniffs customer 1 FIRST,
         then runs 45: just as slow as the app was.
     C2  the app (ARITHABORT OFF), after a recompile, sniffs customer 45
         FIRST, then runs 45 again: fast. Then customer 1 arrives and gets a
         seek plus 300,000 lookups -- now THAT is slow.

  The setting decides only which cache entry a call lands in. What makes a
  call slow is the parameter value its plan was compiled for. The fixes
  are the ones in the parameter-sniffing topic: OPTION (RECOMPILE),
  OPTIMIZE FOR, Query Store hints, or Parameter Sensitive Plan optimization
  on SQL Server 2022.

  And to reproduce the app's plan from SSMS, do not look for a magic
  setting: SET ARITHABORT OFF in the query window lands on the app's cached
  plan, which is the one actually running.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO C: it is the sniff, not the setting ---';
GO

EXEC sys.sp_recompile N'Demo.usp_CustomerSummary';
GO
SET ARITHABORT ON;       -- SSMS, this time sniffing the giant first
GO
EXEC Demo.usp_Call 'C. ARITHABORT is innocent', 1, 1;
EXEC Demo.usp_Call 'C. ARITHABORT is innocent', 2, 45;
GO

EXEC sys.sp_recompile N'Demo.usp_CustomerSummary';
GO
SET ARITHABORT OFF;      -- the app, this time sniffing the small customer first
GO
EXEC Demo.usp_Call 'C. ARITHABORT is innocent', 3, 45;
EXEC Demo.usp_Call 'C. ARITHABORT is innocent', 4, 45;
EXEC Demo.usp_Call 'C. ARITHABORT is innocent', 5, 1;
GO
SET ARITHABORT ON;
GO

DECLARE @ssmsSlow bigint = (SELECT LogicalReads FROM Demo.Calls WHERE Scenario LIKE 'C.%' AND StepNo = 2);
DECLARE @appSlowA bigint = (SELECT LogicalReads FROM Demo.Calls WHERE Scenario = 'A. The complaint' AND StepNo = 2);
DECLARE @appFast  bigint = (SELECT LogicalReads FROM Demo.Calls WHERE Scenario LIKE 'C.%' AND StepNo = 4);
DECLARE @appBig   bigint = (SELECT LogicalReads FROM Demo.Calls WHERE Scenario LIKE 'C.%' AND StepNo = 5);
DECLARE @bigScan  bigint = (SELECT LogicalReads FROM Demo.Calls WHERE Scenario = 'A. The complaint' AND StepNo = 1);

DECLARE @d1 nvarchar(300) = N'SSMS, customer 1 sniffed first: customer 45 costs ' + CAST(@ssmsSlow AS nvarchar(20))
    + N' reads (the app paid ' + CAST(@appSlowA AS nvarchar(20)) + N')';
DECLARE @d2 nvarchar(300) = N'app, customer 45 sniffed first: customer 45 costs ' + CAST(@appFast AS nvarchar(20))
    + N' reads; customer 1 then costs ' + CAST(@appBig AS nvarchar(20)) + N' (a scan was ' + CAST(@bigScan AS nvarchar(20)) + N')';

INSERT Demo.Verdicts VALUES
 ('C. ARITHABORT is innocent', 'same sniff, ARITHABORT ON', @d1, 'SSMS exactly as slow as the app',
  CASE WHEN ABS(@ssmsSlow - @appSlowA) <= @appSlowA * 0.05 THEN 'SLOW IN SSMS TOO' ELSE 'unexpected' END),
 ('C. ARITHABORT is innocent', 'reverse sniff, ARITHABORT OFF', @d2, 'app fast for 45, and now slow for 1',
  CASE WHEN @appFast * 20 <= @appSlowA AND @appBig > @bigScan THEN 'THE LOTTERY MOVES' ELSE 'unexpected' END);
GO


/*==============================================================================
  SCENARIO D -- finding it

  The query to run when someone says "it's fast in SSMS": every cached plan
  for the object, its set_options, whether ARITHABORT was on, and which
  parameter value it was compiled for. Two rows with different set_options
  and different compiled values is the whole diagnosis.
==============================================================================*/
EXEC Demo.usp_SnapshotPlans 'D. Finding it', 1;
GO

DECLARE @n int = (SELECT COUNT(*) FROM Demo.CachedPlans WHERE Scenario = 'D. Finding it');
DECLARE @d nvarchar(300) = CAST(@n AS nvarchar(10)) + N' cached plan(s) after scenario C';
INSERT Demo.Verdicts VALUES ('D. Finding it', 'plans visible in the cache', @d, 'at least one; see result set 3',
    CASE WHEN @n >= 1 THEN 'VISIBLE' ELSE 'unexpected' END);
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. EVERY CALL ===';
GO
SELECT Scenario, StepNo, WhoCalls, CustomerID, LogicalReads, CpuMs FROM Demo.Calls ORDER BY CallID;
GO

PRINT '';
PRINT '=== 2. THE PLAN CACHE AFTER SCENARIO A ===';
GO
SELECT SetOptions, ArithAbortOn, CompiledFor, PlanShape, ExecutionCount
FROM   Demo.CachedPlans WHERE Scenario = 'A. The complaint' ORDER BY ArithAbortOn;
GO

PRINT '';
PRINT '=== 3. THE DIAGNOSTIC QUERY (run this on your own instance) ===';
GO
;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT  ObjectName   = OBJECT_SCHEMA_NAME(st.objectid, st.dbid) + '.' + OBJECT_NAME(st.objectid, st.dbid),
        SetOptions   = so.v,
        ArithAbortOn = CASE WHEN so.v & 4096 = 4096 THEN 1 ELSE 0 END,
        CompiledFor  = qp.query_plan.value('(//ParameterList/ColumnReference/@ParameterCompiledValue)[1]', 'nvarchar(100)'),
        qs.execution_count,
        AvgReads     = qs.total_logical_reads / NULLIF(qs.execution_count, 0)
FROM    sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
CROSS APPLY (SELECT v = CAST(pa.value AS int) FROM sys.dm_exec_plan_attributes(qs.plan_handle) AS pa
             WHERE pa.attribute = 'set_options') AS so
WHERE   st.objectid = OBJECT_ID('Demo.usp_CustomerSummary')   -- your procedure here
  AND   st.dbid     = DB_ID();
GO

PRINT '';
PRINT '=== 4. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario;
GO

PRINT '';
PRINT '=== 5. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Detail, Verdict FROM Demo.Verdicts WHERE Verdict = 'unexpected';
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 5 should be EMPTY. Anything in it is a';
PRINT ' genuine difference on your build, worth reading before';
PRINT ' you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
