/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  What a parallel plan buys, what it costs, when it goes wrong, and what
  stops one from happening. Every query sets its own DOP by hint (MAXDOP 4
  or MAXDOP 1) except one, which shows what this instance's settings decide.
  Evidence lands in Demo.Runs and Demo.Verdicts; the summary at the bottom
  is the payoff.

  Scenarios
    A  a big scan, serial vs parallel       -> faster, but no less CPU
    B  rows repartitioned by a skewed key   -> one thread does 90% of the
                                               work; parallel is no faster
                                               than serial
    C  the same query in batch mode         -> no repartitioning, no skew
    D  a query just over the cost threshold -> faster in parallel, at the
                                               same or more CPU per run
    E  why a plan stayed serial             -> NonParallelPlanReason

  Needs at least two schedulers; on one, A-D report SKIPPED.

  Expected runtime: about a minute.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers,
  Linux container.
==============================================================================*/

USE ParallelDemo;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('Demo.usp_Measure') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

DELETE Demo.Runs;
IF OBJECT_ID('Demo.Verdicts') IS NOT NULL DROP TABLE Demo.Verdicts;
CREATE TABLE Demo.Verdicts
(
    Scenario  char(1)       NOT NULL,
    Item      varchar(70)   NOT NULL,
    Detail    varchar(300)  NOT NULL,
    Expected  varchar(100)  NOT NULL,
    Verdict   varchar(30)   NOT NULL
);
GO

-- What this instance gives a query to work with. Read only.
IF OBJECT_ID('Demo.Instance') IS NOT NULL DROP TABLE Demo.Instance;
SELECT Schedulers         = (SELECT COUNT(*) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE'),
       MaxDop             = (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'max degree of parallelism'),
       CostThreshold      = (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'cost threshold for parallelism'),
       DbMaxDop           = (SELECT CAST(value AS int) FROM sys.database_scoped_configurations WHERE name = 'MAXDOP'),
       CompatibilityLevel = (SELECT compatibility_level FROM sys.databases WHERE database_id = DB_ID())
INTO   Demo.Instance;
GO


/*==============================================================================
  A -- a big scan and aggregate, serial and at DOP 4. Parallelism divides the
  elapsed time, not the work: the same rows are read and aggregated, by four
  threads instead of one, plus the cost of coordinating them.
==============================================================================*/
PRINT '=== A: a big scan, serial vs parallel ===';
EXEC Demo.usp_Measure 'A: serial',   'usp_Big_Serial',   3;
EXEC Demo.usp_Measure 'A: parallel', 'usp_Big_Parallel', 3;
GO

/*==============================================================================
  B -- ROW_NUMBER() OVER (PARTITION BY key). A row-mode parallel plan sends
  each row to a thread chosen by hashing the key, so that each partition is
  numbered by one thread. With 90% of rows on one key, 90% of rows go to one
  thread, and the other three finish early and wait (CXPACKET/CXCONSUMER).
==============================================================================*/
PRINT '=== B: a skewed key ===';
EXEC Demo.usp_Measure 'B: skewed key, DOP 4',  'usp_Window_Skewed',        3;
EXEC Demo.usp_Measure 'B: skewed key, serial', 'usp_Window_Skewed_Serial', 3;
EXEC Demo.usp_Measure 'B: even key, DOP 4',    'usp_Window_Even',          3;
GO

/*==============================================================================
  C -- the skewed query again with batch mode allowed (compatibility level
  150+ on Enterprise or Developer edition, batch mode on rowstore). Batch
  mode's sort and window aggregate don't repartition by the key.
==============================================================================*/
PRINT '=== C: the same, batch mode allowed ===';
EXEC Demo.usp_Measure 'C: skewed key, batch mode allowed', 'usp_Window_Skewed_Batch', 3;
GO

/*==============================================================================
  D -- a query just over the default cost threshold of 5. Run 50 times
  serial and 50 times at DOP 4: per run, parallel is quicker but saves no
  CPU -- it spends the same or more, sooner. Then once with no hint, to see what this instance would choose.
==============================================================================*/
PRINT '=== D: just over the cost threshold ===';
EXEC Demo.usp_Measure 'D: serial',  'usp_Small_Serial',   50;
EXEC Demo.usp_Measure 'D: DOP 4',   'usp_Small_Parallel', 50;
EXEC Demo.usp_Measure 'D: no hint', 'usp_Small_Default',  5;
GO

/*==============================================================================
  E -- four queries that ask for DOP 4 and don't get it. Compile each and
  read the plan.
==============================================================================*/
PRINT '=== E: why a plan stayed serial ===';
EXEC Demo.usp_Measure 'E: scalar UDF',          'usp_Blocker_ScalarUdf',     1;
EXEC Demo.usp_Measure 'E: table variable',      'usp_Blocker_TableVariable', 1;
EXEC Demo.usp_Measure 'E: MAXDOP 1',            'usp_Blocker_Maxdop1',       1;
EXEC Demo.usp_Measure 'E: cheap',               'usp_Blocker_Cheap',         1;
GO


/*==============================================================================
  Verdicts
==============================================================================*/
DECLARE @sched int = (SELECT Schedulers FROM Demo.Instance), @ctfp int = (SELECT CostThreshold FROM Demo.Instance),
        @maxdop int = (SELECT MaxDop FROM Demo.Instance), @dbmaxdop int = (SELECT DbMaxDop FROM Demo.Instance);
DECLARE @d varchar(300);

-- A
DECLARE @sCpu decimal(12,2), @sEl decimal(12,2), @pCpu decimal(12,2), @pEl decimal(12,2), @pDop bigint;
SELECT @sCpu = CpuMsPer, @sEl = ElapsedMsPer FROM Demo.Runs WHERE Label = 'A: serial';
SELECT @pCpu = CpuMsPer, @pEl = ElapsedMsPer, @pDop = LastDop FROM Demo.Runs WHERE Label = 'A: parallel';
SET @d = CONCAT('serial ', @sEl, ' ms elapsed, ', @sCpu, ' ms CPU; DOP ', @pDop, ': ', @pEl, ' ms elapsed, ', @pCpu, ' ms CPU');
INSERT Demo.Verdicts VALUES ('A', 'parallel divides elapsed time, not work', @d, 'parallel elapsed < 60% of serial; CPU not lower',
    CASE WHEN @sched < 2 THEN 'SKIPPED'
         WHEN @pDop > 1 AND @pEl < @sEl * 0.6 AND @pCpu >= @sCpu * 0.9 THEN 'FASTER, SAME WORK'
         ELSE 'unexpected' END);

-- B
DECLARE @thr varchar(200), @share decimal(5,1), @mode varchar(10), @thrE varchar(200), @shareE decimal(5,1),
        @kEl decimal(12,2), @kSerEl decimal(12,2), @eEl decimal(12,2), @kCx decimal(12,2), @eCx decimal(12,2), @kDop bigint;
EXEC Demo.usp_ThreadRows 'usp_Window_Skewed', 'Sort', @thr OUTPUT, @share OUTPUT, @mode OUTPUT;
EXEC Demo.usp_ThreadRows 'usp_Window_Even',   'Sort', @thrE OUTPUT, @shareE OUTPUT, @mode OUTPUT;
SELECT @kEl = ElapsedMsPer, @kCx = CxWaitMsPer, @kDop = LastDop FROM Demo.Runs WHERE Label = 'B: skewed key, DOP 4';
SELECT @kSerEl = ElapsedMsPer FROM Demo.Runs WHERE Label = 'B: skewed key, serial';
SELECT @eEl = ElapsedMsPer, @eCx = CxWaitMsPer FROM Demo.Runs WHERE Label = 'B: even key, DOP 4';
SET @d = CONCAT('rows per thread at the Sort: ', @thr, ' (busiest ', @share, '%); ', @kEl, ' ms vs ', @kSerEl, ' ms serial');
INSERT Demo.Verdicts VALUES ('B', 'skewed key: one thread does the work', @d, 'busiest thread > 80%; barely faster than serial',
    CASE WHEN @sched < 2 THEN 'SKIPPED'
         WHEN @kDop > 1 AND @share > 80 AND @kEl > @kSerEl * 0.6 THEN 'SKEWED'
         ELSE 'unexpected' END);
SET @d = CONCAT('rows per thread at the Sort: ', @thrE, ' (busiest ', @shareE, '%); ', @eEl, ' ms vs ', @kEl, ' ms skewed');
INSERT Demo.Verdicts VALUES ('B', 'even key: the work is shared', @d, 'busiest thread < 40%; well under half the skewed time',
    CASE WHEN @sched < 2 THEN 'SKIPPED'
         WHEN @shareE < 40 AND @eEl < @kEl * 0.5 THEN 'BALANCED'
         ELSE 'unexpected' END);
SET @d = CONCAT('parallelism waits per run: skewed ', @kCx, ' ms (in ', @kEl, ' ms), even ', @eCx, ' ms (in ', @eEl, ' ms)');
INSERT Demo.Verdicts VALUES ('B', 'skew shows up as parallelism waits', @d, 'skewed waits > 2x even',
    CASE WHEN @sched < 2 THEN 'SKIPPED'
         WHEN @kCx > @eCx * 2 THEN 'WAITING'
         ELSE 'unexpected' END);

-- C
DECLARE @cEl decimal(12,2);
EXEC Demo.usp_ThreadRows 'usp_Window_Skewed_Batch', 'Sort', @thr OUTPUT, @share OUTPUT, @mode OUTPUT;
SELECT @cEl = ElapsedMsPer FROM Demo.Runs WHERE Label = 'C: skewed key, batch mode allowed';
SET @d = CONCAT('Sort ran in ', ISNULL(@mode, '?'), ' mode; rows per thread ', ISNULL(@thr, '?'), '; ', @cEl, ' ms vs ', @kEl, ' ms in row mode');
INSERT Demo.Verdicts VALUES ('C', 'batch mode: no repartitioning, no skew', @d, 'batch mode; busiest < 40%; faster than row mode',
    CASE WHEN @sched < 2 THEN 'SKIPPED'
         WHEN ISNULL(@mode, 'Row') <> 'Batch' THEN 'SKIPPED'     -- no batch mode on rowstore here (edition or level)
         WHEN @share < 40 AND @cEl < @kEl THEN 'BALANCED'
         ELSE 'unexpected' END);

-- D
DECLARE @dsCpu decimal(12,2), @dsEl decimal(12,2), @dpCpu decimal(12,2), @dpEl decimal(12,2), @dpDop bigint,
        @ndDop bigint, @sDopC int, @sCost decimal(12,3), @r varchar(120);
SELECT @dsCpu = CpuMsPer, @dsEl = ElapsedMsPer FROM Demo.Runs WHERE Label = 'D: serial';
SELECT @dpCpu = CpuMsPer, @dpEl = ElapsedMsPer, @dpDop = LastDop FROM Demo.Runs WHERE Label = 'D: DOP 4';
SELECT @ndDop = LastDop FROM Demo.Runs WHERE Label = 'D: no hint';
EXEC Demo.usp_PlanFacts 'usp_Small_Serial', @sDopC OUTPUT, @sCost OUTPUT, @r OUTPUT;
SET @d = CONCAT('serial cost ', @sCost, '; serial ', @dsEl, ' ms / ', @dsCpu, ' ms CPU per run; DOP ', @dpDop, ' ',
                @dpEl, ' ms / ', @dpCpu, ' ms CPU per run');
INSERT Demo.Verdicts VALUES ('D', 'a cheap query: faster in parallel, no cheaper', @d, 'parallel elapsed lower; no CPU saved',
    CASE WHEN @sched < 2 THEN 'SKIPPED'
         WHEN @dpDop > 1 AND @dpEl < @dsEl AND @dpCpu >= @dsCpu * 0.95 THEN 'CPU FOR SPEED'
         ELSE 'unexpected' END);
-- With no hint, the optimizer considers a parallel plan only when the serial
-- plan costs more than the cost threshold, and only when MAXDOP allows it.
DECLARE @shouldGoParallel bit = CASE WHEN @sCost > @ctfp AND @maxdop <> 1 AND ISNULL(@dbmaxdop, 0) <> 1 AND @sched > 1 THEN 1 ELSE 0 END;
SET @d = CONCAT('cost threshold ', @ctfp, ', MAXDOP ', @maxdop, ' (database ', ISNULL(@dbmaxdop, 0), '); serial cost ', @sCost,
                '; with no hint it ran at DOP ', @ndDop);
INSERT Demo.Verdicts VALUES ('D', 'this instance''s own choice', @d,
    CASE WHEN @shouldGoParallel = 1 THEN 'parallel: cost is over the threshold' ELSE 'serial: under the threshold, or MAXDOP 1' END,
    CASE WHEN (@ndDop > 1 AND @shouldGoParallel = 1) OR (@ndDop = 1 AND @shouldGoParallel = 0) THEN 'AS CONFIGURED'
         WHEN @ndDop = 1 AND @shouldGoParallel = 1 THEN 'INCONCLUSIVE'   -- considered, but the parallel plan wasn't cheaper
         ELSE 'unexpected' END);

-- E
DECLARE @eDop int, @eCost decimal(12,3), @eR varchar(120);
EXEC Demo.usp_PlanFacts 'usp_Blocker_ScalarUdf', @eDop OUTPUT, @eCost OUTPUT, @eR OUTPUT;
INSERT Demo.Verdicts VALUES ('E', 'a scalar UDF that can''t be inlined',
    CONCAT('DOP ', @eDop, '; NonParallelPlanReason ', ISNULL(@eR, 'none')), 'serial; a UDF reason',
    CASE WHEN @eDop = 1 AND @eR IN ('TSQLUserDefinedFunctionsNotParallelizable', 'CouldNotGenerateValidParallelPlan') THEN 'SERIAL' ELSE 'unexpected' END);
EXEC Demo.usp_PlanFacts 'usp_Blocker_TableVariable', @eDop OUTPUT, @eCost OUTPUT, @eR OUTPUT;
INSERT Demo.Verdicts VALUES ('E', 'inserting into a table variable',
    CONCAT('DOP ', @eDop, '; NonParallelPlanReason ', ISNULL(@eR, 'none')), 'serial; a table variable reason',
    CASE WHEN @eDop = 1 AND (@eR LIKE '%TableVariable%' OR @eR = 'CouldNotGenerateValidParallelPlan') THEN 'SERIAL' ELSE 'unexpected' END);
EXEC Demo.usp_PlanFacts 'usp_Blocker_Maxdop1', @eDop OUTPUT, @eCost OUTPUT, @eR OUTPUT;
INSERT Demo.Verdicts VALUES ('E', 'OPTION (MAXDOP 1)',
    CONCAT('DOP ', @eDop, '; cost ', @eCost, '; NonParallelPlanReason ', ISNULL(@eR, 'none')), 'serial; MaxDOPSetToOne',
    CASE WHEN @eDop = 1 AND @eR = 'MaxDOPSetToOne' THEN 'SERIAL' ELSE 'unexpected' END);
EXEC Demo.usp_PlanFacts 'usp_Blocker_Cheap', @eDop OUTPUT, @eCost OUTPUT, @eR OUTPUT;
INSERT Demo.Verdicts VALUES ('E', 'cheaper than the cost threshold',
    CONCAT('DOP ', @eDop, '; cost ', @eCost, ' vs threshold ', @ctfp, '; NonParallelPlanReason ', ISNULL(@eR, 'none')),
    'serial; no reason given at all',
    CASE WHEN @eDop = 1 AND @eR IS NULL AND @eCost < @ctfp THEN 'SERIAL' ELSE 'unexpected' END);
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. THIS INSTANCE ===';
GO
SELECT * FROM Demo.Instance;
GO

PRINT '';
PRINT '=== 2. EACH MEASURED QUERY, PER RUN ===';
GO
SELECT Label, Executions, LastDop, CpuMsPer, ElapsedMsPer, CxWaitMsPer FROM Demo.Runs ORDER BY CapturedAt;
GO

PRINT '';
PRINT '=== 3. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario;
GO

PRINT '';
PRINT '=== 4. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Detail, Verdict FROM Demo.Verdicts WHERE Verdict IN ('unexpected', 'INCONCLUSIVE', 'SKIPPED');
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 4 should be EMPTY. SKIPPED means this';
PRINT ' instance cannot show that scenario (one scheduler, or';
PRINT ' no batch mode on rowstore). Anything marked unexpected';
PRINT ' is a genuine difference on your build.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
