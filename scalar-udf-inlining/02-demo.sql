/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed, on SQL Server 2019 or later.

  Every query runs through Demo.usp_Run, which recompiles its procedure,
  runs it twice and records the second execution in Demo.Runs. Verdicts land
  in Demo.Verdicts. The summary at the bottom is the payoff.

  Scenarios
    A  a calculation         -> the same function, inlined and not: one runs
                                like hand-written SQL, the other is called
                                for every row, serially
    B  a lookup              -> a function that reads a table: 500,000 calls,
                                a seek each, unless inlined into a join
    C  not inlineable        -> GETDATE() in the body: WITH INLINE cannot help
    D  the same answer?      -> inlining keeps the function's answer; the
                                "equivalent" hand-written SQL does not

  Expected runtime: about fifteen seconds. Most of it is the three
  non-inlined runs, which is the point.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers,
  MAXDOP 0, cost threshold for parallelism 5, compatibility level 160.
==============================================================================*/

USE UdfInliningDemo;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('Demo.usp_Run') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

TRUNCATE TABLE Demo.Runs;
DROP TABLE IF EXISTS Demo.Verdicts;
CREATE TABLE Demo.Verdicts
(
    Scenario  varchar(60)   NOT NULL,
    Item      varchar(90)   NOT NULL,
    Detail    nvarchar(200) NULL,
    Expected  nvarchar(140) NULL,
    Verdict   varchar(24)   NULL
);
GO


/*==============================================================================
  RUN EVERY QUERY

  Seven procedures. The explicit-SQL ones are the baselines: the function's
  logic typed straight into the query, which is what inlining aims to
  produce on its own.
==============================================================================*/
PRINT '';
PRINT '--- running the queries (the non-inlined ones take a few seconds each) ---';
GO

EXEC Demo.usp_Run 'Demo.usp_Tax_ExplicitSql';
EXEC Demo.usp_Run 'Demo.usp_Tax_Inline',         'Demo.fn_TaxInline';
EXEC Demo.usp_Run 'Demo.usp_Tax_NoInline',       'Demo.fn_TaxNoInline';
EXEC Demo.usp_Run 'Demo.usp_Tax_NotInlineable',  'Demo.fn_TaxNow';
EXEC Demo.usp_Run 'Demo.usp_Region_ExplicitSql';
EXEC Demo.usp_Run 'Demo.usp_Region_Inline',      'Demo.fn_RegionInline';
EXEC Demo.usp_Run 'Demo.usp_Region_NoInline',    'Demo.fn_RegionNoInline';
GO


/*==============================================================================
  SCENARIO A -- a calculation

  fn_TaxInline and fn_TaxNoInline have the same body. The only difference is
  WITH INLINE = ON / OFF.

  What to look for:
    - inlined: no UDF left in the plan, the query goes parallel, and it runs
      in about the time of the hand-written baseline
    - not inlined: the function is called for every row -- the function
      stats count the calls -- and the plan is forced serial, with
      NonParallelPlanReason = TSQLUserDefinedFunctionsNotParallelizable.
      Before SQL Server 2019 that was the only way a scalar UDF could run.

  The parallelism checks only mean something if the instance will go
  parallel at all, so the baseline's DOP is checked first.
==============================================================================*/
DECLARE @baseDop int = (SELECT Dop FROM Demo.Runs WHERE ProcName = 'Demo.usp_Tax_ExplicitSql');
DECLARE @baseMs int  = (SELECT ElapsedMs FROM Demo.Runs WHERE ProcName = 'Demo.usp_Tax_ExplicitSql');
DECLARE @rows bigint = (SELECT COUNT_BIG(*) FROM Demo.Orders);

DECLARE @iUdf bit, @iDop int, @iMs int;
SELECT @iUdf = UdfInPlan, @iDop = Dop, @iMs = ElapsedMs FROM Demo.Runs WHERE ProcName = 'Demo.usp_Tax_Inline';
DECLARE @nUdf bit, @nDop int, @nMs int, @nCalls bigint, @nReason nvarchar(100);
SELECT @nUdf = UdfInPlan, @nDop = Dop, @nMs = ElapsedMs, @nCalls = FnCalls, @nReason = SerialReason
FROM   Demo.Runs WHERE ProcName = 'Demo.usp_Tax_NoInline';

DECLARE @d1 nvarchar(200) = N'no UDF in plan: ' + CASE @iUdf WHEN 0 THEN N'yes' ELSE N'NO' END
    + N'; DOP ' + CAST(@iDop AS nvarchar(10)) + N'; ' + CAST(@iMs AS nvarchar(10)) + N' ms vs baseline '
    + CAST(@baseMs AS nvarchar(10)) + N' ms';
DECLARE @v1 varchar(24) =
    CASE WHEN @baseDop <= 1                                              THEN 'INCONCLUSIVE'
         WHEN @iUdf = 0 AND @iDop > 1 AND @iMs <= @baseMs * 5 + 20       THEN 'RUNS LIKE PLAIN SQL'
         ELSE 'unexpected' END;

DECLARE @d2 nvarchar(200) = CAST(@nCalls AS nvarchar(20)) + N' calls for ' + CAST(@rows AS nvarchar(20))
    + N' rows; DOP ' + CAST(@nDop AS nvarchar(10)) + N' (' + ISNULL(@nReason, N'no reason given') + N'); '
    + CAST(@nMs AS nvarchar(10)) + N' ms';
DECLARE @v2 varchar(24) =
    CASE WHEN @nUdf = 1 AND @nDop = 1 AND @nCalls >= @rows
              AND @nReason = N'TSQLUserDefinedFunctionsNotParallelizable' THEN 'ROW BY ROW, SERIAL'
         ELSE 'unexpected' END;

DECLARE @ratio decimal(18,1) = @nMs * 1.0 / NULLIF(@iMs, 0);
DECLARE @d3 nvarchar(200) = CAST(@nMs AS nvarchar(10)) + N' ms vs ' + CAST(@iMs AS nvarchar(10)) + N' ms: '
    + CAST(@ratio AS nvarchar(20)) + N'x';
DECLARE @v3 varchar(24) = CASE WHEN @ratio >= 20 THEN 'ORDERS OF MAGNITUDE' ELSE 'unexpected' END;

INSERT Demo.Verdicts VALUES
 ('A. A calculation', 'fn_TaxInline (WITH INLINE = ON)',  @d1, 'no UDF in plan; parallel; near baseline', @v1),
 ('A. A calculation', 'fn_TaxNoInline (WITH INLINE = OFF)', @d2, 'called per row; forced serial', @v2),
 ('A. A calculation', 'not inlined / inlined, elapsed',    @d3, 'far slower', @v3);
GO


/*==============================================================================
  SCENARIO B -- a lookup

  fn_Region* reads Demo.Customers. Not inlined, every row of Demo.Orders
  calls it, and every call is a seek into Demo.Customers: 500,000 calls,
  about a million reads, one row at a time.

  Inlined, the optimizer turns the function into a join against
  Demo.Customers -- the same shape as the hand-written JOIN -- and processes
  it set-based, in parallel.

  On the tested build sys.dm_exec_query_stats DID charge the function's
  reads to the calling query. SET STATISTICS IO is the tool known for
  leaving them out, so the reads are reported from both places here rather
  than claimed to be hidden.
==============================================================================*/
DECLARE @iUdf bit, @iDop int, @iMs int, @iReads bigint;
SELECT @iUdf = UdfInPlan, @iDop = Dop, @iMs = ElapsedMs, @iReads = QueryReads FROM Demo.Runs WHERE ProcName = 'Demo.usp_Region_Inline';
DECLARE @nCalls bigint, @nFnReads bigint, @nMs int, @nReads bigint;
SELECT @nCalls = FnCalls, @nFnReads = FnReads, @nMs = ElapsedMs, @nReads = QueryReads FROM Demo.Runs WHERE ProcName = 'Demo.usp_Region_NoInline';
DECLARE @rows bigint = (SELECT COUNT_BIG(*) FROM Demo.Orders);

DECLARE @d1 nvarchar(200) = N'no UDF in plan: ' + CASE @iUdf WHEN 0 THEN N'yes' ELSE N'NO' END
    + N'; DOP ' + CAST(@iDop AS nvarchar(10)) + N'; ' + CAST(@iReads AS nvarchar(20)) + N' reads; '
    + CAST(@iMs AS nvarchar(10)) + N' ms';
DECLARE @v1 varchar(24) = CASE WHEN @iUdf = 0 AND @iReads < @rows THEN 'BECOMES A JOIN' ELSE 'unexpected' END;

DECLARE @d2 nvarchar(200) = CAST(@nCalls AS nvarchar(20)) + N' calls; function reads ' + CAST(@nFnReads AS nvarchar(20))
    + N'; query reads ' + CAST(@nReads AS nvarchar(20)) + N'; ' + CAST(@nMs AS nvarchar(10)) + N' ms';
DECLARE @v2 varchar(24) = CASE WHEN @nCalls = @rows AND @nFnReads >= @rows THEN 'A SEEK PER ROW' ELSE 'unexpected' END;

INSERT Demo.Verdicts VALUES
 ('B. A lookup', 'fn_RegionInline (WITH INLINE = ON)',    @d1, 'rewritten as a join; set-based', @v1),
 ('B. A lookup', 'fn_RegionNoInline (WITH INLINE = OFF)', @d2, 'one call and one seek per order row', @v2);
GO


/*==============================================================================
  SCENARIO C -- not inlineable

  fn_TaxNow calls GETDATE(). Time-dependent functions are one of several
  documented constructs that make a scalar UDF ineligible for inlining;
  referencing a table variable is another. The engine records which
  functions qualify in sys.sql_modules.is_inlineable, and no hint changes it.
==============================================================================*/
DECLARE @inl bit = (SELECT is_inlineable FROM sys.sql_modules WHERE object_id = OBJECT_ID('Demo.fn_TaxNow'));
DECLARE @udf bit, @dop int, @ms int;
SELECT @udf = UdfInPlan, @dop = Dop, @ms = ElapsedMs FROM Demo.Runs WHERE ProcName = 'Demo.usp_Tax_NotInlineable';
DECLARE @d nvarchar(200) = N'is_inlineable = ' + CAST(@inl AS nvarchar(1)) + N'; UDF in plan: '
    + CASE @udf WHEN 1 THEN N'yes' ELSE N'no' END + N'; DOP ' + CAST(@dop AS nvarchar(10)) + N'; '
    + CAST(@ms AS nvarchar(10)) + N' ms';
DECLARE @v varchar(24) = CASE WHEN @inl = 0 AND @udf = 1 AND @dop = 1 THEN 'BEHAVES LIKE OFF' ELSE 'unexpected' END;

INSERT Demo.Verdicts VALUES ('C. Not inlineable', 'fn_TaxNow (calls GETDATE())', @d, 'is_inlineable 0; runs like WITH INLINE = OFF', @v);
GO


/*==============================================================================
  SCENARIO D -- the same answer?

  fn_Tax* returns decimal(12,2). Every call therefore ROUNDS its result to
  two places before the SUM adds it up.

  The inlined version keeps that: inlining is a rewrite that must give the
  function's answer, rounding and all. The hand-written baseline, which
  looks equivalent, computes Amount * 0.2 at full precision and sums that --
  so it returns a slightly different total.

  The practical point: if you replace a scalar UDF by hand to get the
  performance inlining would have given you, check the answers match.
==============================================================================*/
DECLARE @inline decimal(18,2)   = (SELECT Answer FROM Demo.Runs WHERE ProcName = 'Demo.usp_Tax_Inline');
DECLARE @noinline decimal(18,2) = (SELECT Answer FROM Demo.Runs WHERE ProcName = 'Demo.usp_Tax_NoInline');
DECLARE @explicit decimal(18,2) = (SELECT Answer FROM Demo.Runs WHERE ProcName = 'Demo.usp_Tax_ExplicitSql');

DECLARE @d1 nvarchar(200) = N'inlined ' + CAST(@inline AS nvarchar(30)) + N', not inlined ' + CAST(@noinline AS nvarchar(30));
DECLARE @v1 varchar(24) = CASE WHEN @inline = @noinline THEN 'SAME ANSWER' ELSE 'unexpected' END;
DECLARE @d2 nvarchar(200) = N'hand-written ' + CAST(@explicit AS nvarchar(30)) + N' vs function ' + CAST(@noinline AS nvarchar(30))
    + N'; difference ' + CAST(@noinline - @explicit AS nvarchar(30));
DECLARE @v2 varchar(24) = CASE WHEN @explicit <> @noinline THEN 'HAND REWRITE DIFFERS' ELSE 'no difference here' END;

DECLARE @rInline bigint = (SELECT CAST(Answer AS bigint) FROM Demo.Runs WHERE ProcName = 'Demo.usp_Region_Inline');
DECLARE @rNo     bigint = (SELECT CAST(Answer AS bigint) FROM Demo.Runs WHERE ProcName = 'Demo.usp_Region_NoInline');
DECLARE @rExp    bigint = (SELECT CAST(Answer AS bigint) FROM Demo.Runs WHERE ProcName = 'Demo.usp_Region_ExplicitSql');
DECLARE @d3 nvarchar(200) = N'inlined ' + CAST(@rInline AS nvarchar(20)) + N', not inlined ' + CAST(@rNo AS nvarchar(20))
    + N', join ' + CAST(@rExp AS nvarchar(20));
DECLARE @v3 varchar(24) = CASE WHEN @rInline = @rNo AND @rNo = @rExp THEN 'SAME ANSWER' ELSE 'unexpected' END;

INSERT Demo.Verdicts VALUES
 ('D. The same answer?', 'fn_Tax: inlined vs not inlined',       @d1, 'identical', @v1),
 ('D. The same answer?', 'fn_Tax: function vs hand-written SQL', @d2, 'differs: the function rounds each row', @v2),
 ('D. The same answer?', 'fn_Region: inlined, not, and the join', @d3, 'identical', @v3);
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. EVERY QUERY ===';
GO
SELECT ProcName, Answer, ElapsedMs, CpuMs, Dop, QueryReads, FnCalls, FnReads, UdfInPlan, SerialReason
FROM   Demo.Runs ORDER BY RunID;
GO

PRINT '';
PRINT '=== 2. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario;
GO

PRINT '';
PRINT '=== 3. YOUR FUNCTIONS: which can be inlined ===';
GO
-- The query to run in your own databases. is_inlineable = 0 means the
-- engine will never inline it; inline_type = 0 means someone switched it off.
SELECT  FunctionName = OBJECT_SCHEMA_NAME(m.object_id) + '.' + OBJECT_NAME(m.object_id),
        m.is_inlineable,
        m.inline_type
FROM    sys.sql_modules AS m
JOIN    sys.objects     AS o ON o.object_id = m.object_id
WHERE   o.type = 'FN'
ORDER BY m.is_inlineable, FunctionName;
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
PRINT ' Result set 4 should be EMPTY. Anything in it is either';
PRINT ' a genuine difference on your build, or an instance that';
PRINT ' will not run this workload in parallel (MAXDOP 1, or a';
PRINT ' high cost threshold) -- check that before the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
