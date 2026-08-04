/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  Six scenarios, run end to end, each recording its own evidence into
  Demo.DemoResults. The summary at the bottom is the payoff -- you should not
  have to read a single execution plan by hand.

  Scenarios
    A  a CTE is a macro, not a materialisation   -> referenced twice, scanned twice
    B  estimates under skew                      -> #temp is exact, @tablevar guesses
                                                    the same number either way
    C  parallelism                               -> table variable WRITES are serial,
                                                    table variable READS are not
    D  temp table caching                        -> which DDL shapes break reuse
    E  the 8 MB caching cliff                    -> where reuse stops entirely
    F  collation, and the two hard stops         -> the bug that only bites elsewhere

  Expected runtime: two to four minutes. Scenario D executes 500 procedure
  calls and scenario E another 180; both are trivial calls.

  ############################################################################
  #  RUN THIS ON A SCRATCH INSTANCE                                          #
  #                                                                          #
  #  Scenario D measures the "Temp Tables Creation Rate" performance          #
  #  counter, which is INSTANCE-WIDE. Any other session on this instance      #
  #  creating temp tables during the run inflates the deltas and can make a   #
  #  genuinely cached variant report as NOT cached. There is no per-session   #
  #  equivalent of this counter, so isolation is the only control available.  #
  ############################################################################

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 15 schedulers,
  MAXDOP 0, cost threshold for parallelism 5.
==============================================================================*/

USE TempdbDemo;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('Demo.usp_Record') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

TRUNCATE TABLE Demo.DemoResults;
GO


/*==============================================================================
  SCENARIO A -- a CTE is a macro, not a materialisation

  The single most common reason to reach for a #temp table, and the one that is
  easiest to prove. A common table expression is a naming construct. Reference
  it twice and the optimizer expands it twice, which means the base table is
  read twice.

  What to look for in the summary:
    - "CTE referenced twice" logical reads are almost exactly double
      "CTE referenced once"
    - "#temp referenced twice" is back down at the once figure, plus a few
      dozen reads for the temp table itself

  No sp_recompile and no cache reset is needed here: last_logical_reads is the
  reads of the MOST RECENT execution, which is the one we just performed.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO A: is a CTE materialised? ---';
GO

EXEC Demo.usp_A_CteOnce;
GO
DECLARE @reads bigint =
(
    SELECT SUM(qs.last_logical_reads)
    FROM   sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
    WHERE  st.objectid = OBJECT_ID('Demo.usp_A_CteOnce') AND st.dbid = DB_ID()
);
EXEC Demo.usp_Record 'A. CTE is a macro', 1, 'CTE referenced once',
     'logical reads', @reads, NULL, 'baseline: one pass over Demo.Big', 'BASELINE';
GO

EXEC Demo.usp_A_CteTwice;
GO
DECLARE @reads bigint =
(
    SELECT SUM(qs.last_logical_reads)
    FROM   sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
    WHERE  st.objectid = OBJECT_ID('Demo.usp_A_CteTwice') AND st.dbid = DB_ID()
);
DECLARE @once bigint =
    (SELECT NumericValue FROM Demo.DemoResults
     WHERE Scenario = 'A. CTE is a macro' AND StepNo = 1);

-- A tolerance, not an equality: read-ahead and parallel scan counts vary
-- slightly between executions.
--
-- The verdict is computed into a variable FIRST. An EXEC argument must be a
-- variable or a constant -- never an expression -- so writing
-- '@Verdict = CASE WHEN ... END' directly in the call is a syntax error.
-- Same rule that bites people with RAISERROR arguments.
DECLARE @verdict varchar(24) =
    CASE WHEN @reads >= @once * 1.8 THEN 'SCANNED TWICE' ELSE 'unexpected' END;

EXEC Demo.usp_Record 'A. CTE is a macro', 2, 'CTE referenced twice',
     'logical reads', @reads, NULL, 'roughly 2x the once figure', @verdict;
GO

EXEC Demo.usp_A_TempTwice;
GO
DECLARE @reads bigint =
(
    SELECT SUM(qs.last_logical_reads)
    FROM   sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
    WHERE  st.objectid = OBJECT_ID('Demo.usp_A_TempTwice') AND st.dbid = DB_ID()
);
DECLARE @once bigint =
    (SELECT NumericValue FROM Demo.DemoResults
     WHERE Scenario = 'A. CTE is a macro' AND StepNo = 1);

DECLARE @verdict varchar(24) =
    CASE WHEN @reads < @once * 1.5 THEN 'SCANNED ONCE' ELSE 'unexpected' END;

EXEC Demo.usp_Record 'A. CTE is a macro', 3, '#temp referenced twice',
     'logical reads', @reads, NULL, 'back down to the once figure', @verdict;
GO


/*==============================================================================
  SCENARIO B -- estimates under skew

  Demo.Skewed holds 10,000 rows. grp 1 has 9,000 of them; grp 2 has 10. The
  same four-statement procedure asks the same two questions of a #temp table
  and of a table variable holding identical data, both with the same
  non-clustered index, so the ONLY difference between them is statistics.

  What to look for:
    - #temp estimates land on 9000 and 10 -- it has a histogram
    - @tablevar produces the SAME estimate for both predicates, even though the
      true answers differ by a factor of 900 -- it has none

  Both tables carry the same non-clustered index, so this is not a "the table
  variable had no index" result. An index gives the optimizer a structure to
  seek on; it does not give it a distribution to reason about. The table
  variable's number is a fixed guess derived from the row count, and it does
  not move when the predicate does.

  ---------------------------------------------------------------------------
  READING ESTIMATES OUT OF A PROCEDURE PLAN -- the one subtle bit in this file

  sys.dm_exec_query_plan returns the plan for an entire plan handle. For a
  stored procedure that means ALL of its statements in one XML document. An
  XQuery beginning '//RelOp' therefore matches the first qualifying operator
  in the WHOLE PROCEDURE, not in the statement you filtered the DMV row down
  to -- so every row comes back carrying the same estimate and the result
  looks stable and authoritative while being entirely wrong.

  The fix is to select the StmtSimple node first and then use a RELATIVE path
  inside it, which is what the query below does. Note also
  './/RelOp[IndexScan or TableScan]': that picks the operator that actually
  touches the table, rather than a Compute Scalar or the aggregate above it,
  both of which carry EstimateRows of their own.
  ---------------------------------------------------------------------------
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO B: estimates under skew ---';
GO

-- Object scoped, so the next execution compiles fresh against current data.
-- Not DBCC FREEPROCCACHE: there is no reason to flush the whole instance.
EXEC sys.sp_recompile N'Demo.usp_B_Estimates';
GO

EXEC Demo.usp_B_Estimates;
GO

SET QUOTED_IDENTIFIER ON;   -- required for XML methods; sqlcmd defaults it OFF
GO

DECLARE @plan xml;

SELECT TOP (1) @plan = qp.query_plan
FROM   sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)  AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE  st.objectid = OBJECT_ID('Demo.usp_B_Estimates')
  AND  st.dbid     = DB_ID()
  AND  qp.query_plan IS NOT NULL;

IF @plan IS NULL
    RAISERROR('  no plan retrievable for Demo.usp_B_Estimates -- scenario B skipped', 0, 1) WITH NOWAIT;
ELSE
BEGIN
    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
     stmts AS
     (
        SELECT  StatementText = n.value('@StatementText', 'nvarchar(400)'),
                Operator      = n.value('(.//RelOp[IndexScan or TableScan]/@PhysicalOp)[1]', 'varchar(40)'),
                EstimateRows  = n.value('(.//RelOp[IndexScan or TableScan]/@EstimateRows)[1]', 'float')
        FROM    @plan.nodes('//StmtSimple') AS x(n)
     ),
     tagged AS
     (
        SELECT  Marker = CASE WHEN StatementText LIKE '%B1%' THEN 'B1'
                              WHEN StatementText LIKE '%B2%' THEN 'B2'
                              WHEN StatementText LIKE '%B3%' THEN 'B3'
                              WHEN StatementText LIKE '%B4%' THEN 'B4' END,
                Operator, EstimateRows
        FROM    stmts
        WHERE   StatementText LIKE '%COUNT_BIG%'
     )
     INSERT Demo.DemoResults (Scenario, StepNo, Item, Measure, NumericValue, TextValue, Expected, Verdict)
     SELECT  'B. Estimates under skew',
             CASE Marker WHEN 'B1' THEN 1 WHEN 'B2' THEN 2 WHEN 'B3' THEN 3 ELSE 4 END,
             CASE Marker
                  WHEN 'B1' THEN '#temp      WHERE grp = 1  (true 9000)'
                  WHEN 'B2' THEN '#temp      WHERE grp = 2  (true 10)'
                  WHEN 'B3' THEN '@tablevar  WHERE grp = 1  (true 9000)'
                  ELSE           '@tablevar  WHERE grp = 2  (true 10)' END,
             'estimated rows',
             EstimateRows,
             Operator,
             CASE WHEN Marker IN ('B1','B3') THEN '9000' ELSE '10' END,
             -- Thresholds are keyed to each statement's TRUE row count, so a
             -- verdict means "close to the truth" rather than "close to some
             -- number we saw once on one build".
             CASE WHEN Marker = 'B1' AND EstimateRows BETWEEN 8000 AND 10000 THEN 'ACCURATE'
                  WHEN Marker = 'B2' AND EstimateRows BETWEEN    1 AND    50 THEN 'ACCURATE'
                  WHEN Marker IN ('B1','B2')                                 THEN 'inaccurate'
                  WHEN Marker = 'B3' AND EstimateRows < 5000                 THEN 'GUESS'
                  WHEN Marker = 'B4' AND EstimateRows > 50                   THEN 'GUESS'
                  ELSE 'unexpectedly accurate' END
     FROM    tagged
     WHERE   Marker IS NOT NULL;
END
GO


/*==============================================================================
  SCENARIO C -- parallelism

  last_dop in sys.dm_exec_query_stats is recorded per statement, so this
  scenario needs no plan parsing at all.

  What to look for:
    - the control statement goes parallel        <- proves the instance will
    - INSERT ... INTO #temp goes parallel
    - INSERT ... INTO @tablevar is DOP 1         <- writes to a table variable
                                                    cannot go parallel
    - SELECT joining @tablevar goes parallel     <- reads can

  That last row is the one worth remembering. "Table variables are serial" is
  the usual shorthand and it is half wrong: the restriction is on modification,
  not on reading.

  If the control comes back serial, this instance will not parallelise the
  workload at all (MAXDOP 1, a low core count, or a high cost threshold) and
  every row below it is meaningless. The scenario says so rather than letting
  you read four DOP 1 rows as a finding.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO C: parallelism ---';
GO

EXEC sys.sp_recompile N'Demo.usp_C_Control';
EXEC sys.sp_recompile N'Demo.usp_C_IntoTemp';
EXEC sys.sp_recompile N'Demo.usp_C_IntoTableVar';
EXEC sys.sp_recompile N'Demo.usp_C_ReadTableVar';
GO

EXEC Demo.usp_C_Control;
EXEC Demo.usp_C_IntoTemp;
EXEC Demo.usp_C_IntoTableVar;
EXEC Demo.usp_C_ReadTableVar;
GO

;WITH s AS
(
    SELECT  ObjName = OBJECT_NAME(st.objectid),
            Stmt    = LTRIM(SUBSTRING(st.text, qs.statement_start_offset/2 + 1,
                       (CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
                             ELSE qs.statement_end_offset END - qs.statement_start_offset)/2 + 1)),
            qs.last_dop,
            qs.statement_start_offset
    FROM    sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
    WHERE   st.dbid = DB_ID()
      AND   st.objectid IN (OBJECT_ID('Demo.usp_C_Control'),
                            OBJECT_ID('Demo.usp_C_IntoTemp'),
                            OBJECT_ID('Demo.usp_C_IntoTableVar'),
                            OBJECT_ID('Demo.usp_C_ReadTableVar'))
)
INSERT Demo.DemoResults (Scenario, StepNo, Item, Measure, NumericValue, TextValue, Expected, Verdict)
SELECT  'C. Parallelism',
        CASE WHEN ObjName = 'usp_C_Control'      THEN 1
             WHEN ObjName = 'usp_C_IntoTemp'     THEN 2
             WHEN ObjName = 'usp_C_IntoTableVar' THEN 3
             WHEN Stmt LIKE 'INSERT%'            THEN 4
             ELSE 5 END,
        CASE WHEN ObjName = 'usp_C_Control'      THEN 'control: plain SELECT ... GROUP BY'
             WHEN ObjName = 'usp_C_IntoTemp'     THEN 'INSERT INTO #temp ... SELECT'
             WHEN ObjName = 'usp_C_IntoTableVar' THEN 'INSERT INTO @tablevar ... SELECT'
             WHEN Stmt LIKE 'INSERT%'            THEN 'INSERT INTO @tablevar (write)'
             ELSE                                     'SELECT joining @tablevar (read)' END,
        'DOP', last_dop, NULL,
        CASE WHEN ObjName = 'usp_C_IntoTableVar' THEN 'serial: writes cannot parallelise'
             WHEN ObjName = 'usp_C_ReadTableVar' AND Stmt LIKE 'INSERT%'
                                                 THEN 'serial: writes cannot parallelise'
             ELSE 'parallel, if the instance allows it' END,
        CASE WHEN last_dop > 1 THEN 'PARALLEL' ELSE 'serial' END
FROM    s
ORDER BY 2;
GO

-- Guard: if the control never went parallel, say so loudly.
DECLARE @controlDop int =
    (SELECT NumericValue FROM Demo.DemoResults
     WHERE Scenario = 'C. Parallelism' AND StepNo = 1);

IF @controlDop IS NULL OR @controlDop <= 1
BEGIN
    RAISERROR('  CONTROL WAS SERIAL. This instance will not parallelise this workload;', 0, 1) WITH NOWAIT;
    RAISERROR('  scenario C proves nothing here. Check MAXDOP and cost threshold.', 0, 1) WITH NOWAIT;

    UPDATE Demo.DemoResults
    SET    Verdict = 'INCONCLUSIVE'
    WHERE  Scenario = 'C. Parallelism';
END
GO


/*==============================================================================
  SCENARIO D -- temp table caching

  When a temp table is created inside a stored procedure, SQL Server normally
  does not really drop it at the end. It truncates it and keeps the metadata,
  so the next call reuses the same object. That is temp table caching, and it
  is what keeps a busy procedure from hammering tempdb's system catalogs.

  Certain DDL shapes make the table ineligible. This scenario runs each shape
  50 times and watches the Temp Tables Creation Rate counter.

    delta ~= 0    the table was cached and reused
    delta ~= 50   a brand new table was built on every single call

  Two results here contradict widely repeated advice, which is why the demo
  measures rather than asserts:
    - explicitly DROPping your temp table does NOT break caching
    - SELECT INTO is cached

  And two more that catch people who carried habits over from permanent
  tables:
    - NAMING a constraint breaks it
    - CREATE INDEX after the CREATE TABLE breaks it; an inline INDEX does not
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO D: temp table caching (500 calls, be patient) ---';
GO

DECLARE @procs TABLE (Seq int PRIMARY KEY, ProcName sysname, Label varchar(90), Expected nvarchar(140));
INSERT @procs VALUES
 ( 1, 'Demo.usp_D_a_Plain',           'plain CREATE TABLE #t',                'cached'),
 ( 2, 'Demo.usp_D_b_ExplicitDrop',    'plain + explicit DROP TABLE #t',       'cached (the DROP is harmless)'),
 ( 3, 'Demo.usp_D_c_UnnamedPk',       'unnamed PRIMARY KEY',                  'cached'),
 ( 4, 'Demo.usp_D_d_InlineIndex',     'inline INDEX in the CREATE TABLE',     'cached'),
 ( 5, 'Demo.usp_D_e_SelectInto',      'SELECT INTO #t',                       'cached'),
 ( 6, 'Demo.usp_D_f_NamedConstraint', 'NAMED constraint',                     'NOT cached'),
 ( 7, 'Demo.usp_D_g_IndexAfter',      'CREATE INDEX after the CREATE TABLE',  'NOT cached'),
 ( 8, 'Demo.usp_D_h_AlterAfter',      'ALTER TABLE after the CREATE TABLE',   'NOT cached'),
 ( 9, 'Demo.usp_D_i_DynamicSql',      'temp table created in dynamic SQL',    'NOT cached'),
 (10, 'Demo.usp_D_j_Large',           'large table, about 12 MB',             'NOT cached (see scenario E)');

DECLARE @seq int = 1, @nm sysname, @lbl varchar(90), @exp nvarchar(140),
        @before bigint, @after bigint, @i int, @sql nvarchar(200);

WHILE @seq <= 10
BEGIN
    SELECT @nm = ProcName, @lbl = Label, @exp = Expected FROM @procs WHERE Seq = @seq;
    SET @sql = N'EXEC ' + @nm + N';';

    -- Warm-up. The FIRST execution always creates the table; caching can only
    -- show up from the second execution onwards.
    EXEC sys.sp_executesql @sql;

    SELECT @before = cntr_value FROM sys.dm_os_performance_counters
    WHERE  counter_name = 'Temp Tables Creation Rate';

    SET @i = 0;
    WHILE @i < 50
    BEGIN
        EXEC sys.sp_executesql @sql;
        SET @i += 1;
    END

    SELECT @after = cntr_value FROM sys.dm_os_performance_counters
    WHERE  counter_name = 'Temp Tables Creation Rate';

    -- Both the value and the verdict go into variables before the call. An
    -- EXEC argument must be a variable or a constant; '@after - @before' and a
    -- CASE expression are both syntax errors in an argument position.
    DECLARE @delta bigint = @after - @before;
    DECLARE @verdict varchar(24) =
        -- A small allowance: the counter is instance-wide, so a couple of
        -- stray creations from elsewhere should not flip a cached verdict.
        CASE WHEN @delta <= 5  THEN 'CACHED'
             WHEN @delta >= 45 THEN 'NOT cached'
             ELSE 'INTERMITTENT' END;

    EXEC Demo.usp_Record 'D. Temp table caching', @seq, @lbl,
         'creations per 50 calls', @delta, NULL, @exp, @verdict;

    SET @seq += 1;
END
GO


/*==============================================================================
  SCENARIO E -- the 8 MB caching cliff

  Scenario D's last row showed a large temp table failing to cache. This one
  finds the boundary by sweeping the row count across it.

  char(2000) rows are about 2,008 bytes each, so the data size is easy to read
  off the row count. Watch the verdict flip between roughly 4,000 and 4,500
  rows -- right around 8 MB.

  Why this matters in practice: nothing about your code changes when a
  procedure's temp table crosses this line. The procedure simply starts
  rebuilding its temp table on every call, and gets slower, with no plan
  regression to find.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO E: the 8 MB caching cliff ---';
GO

DECLARE @sizes TABLE (Seq int IDENTITY(1,1) PRIMARY KEY, Rows int);
INSERT @sizes (Rows) VALUES (1000),(2000),(3000),(3500),(4000),(4200),(4500),(5000),(6000);

DECLARE @seq int = 1, @rows int, @before bigint, @after bigint, @i int, @mb decimal(18,3);

WHILE @seq <= (SELECT MAX(Seq) FROM @sizes)
BEGIN
    SELECT @rows = Rows FROM @sizes WHERE Seq = @seq;
    SET @mb = @rows * 2008.0 / 1048576.0;

    EXEC Demo.usp_E_Size @Rows = @rows;          -- warm-up

    SELECT @before = cntr_value FROM sys.dm_os_performance_counters
    WHERE  counter_name = 'Temp Tables Creation Rate';

    SET @i = 0;
    WHILE @i < 20
    BEGIN
        EXEC Demo.usp_E_Size @Rows = @rows;
        SET @i += 1;
    END

    SELECT @after = cntr_value FROM sys.dm_os_performance_counters
    WHERE  counter_name = 'Temp Tables Creation Rate';

    -- Variables, not expressions -- see the note in scenario D.
    DECLARE @delta bigint = @after - @before;
    DECLARE @verdict varchar(24) =
        CASE WHEN @delta <= 2  THEN 'CACHED'
             WHEN @delta >= 18 THEN 'NOT cached'
             ELSE 'INTERMITTENT' END;
    DECLARE @item  varchar(90)   = CAST(@rows AS varchar(10)) + ' rows';
    DECLARE @sizeText nvarchar(200) = CAST(CAST(@mb AS decimal(6,2)) AS nvarchar(20)) + ' MB';

    EXEC Demo.usp_Record 'E. The 8 MB cliff', @seq, @item,
         'creations per 20 calls', @delta, @sizeText, NULL, @verdict;

    SET @seq += 1;
END
GO


/*==============================================================================
  SCENARIO F -- collation, and the two hard stops

  F1. COLLATION

  A hand-written CREATE TABLE #t takes TEMPDB's collation for its character
  columns. SELECT INTO inherits the SOURCE column's collation. In a database
  whose collation matches tempdb's -- which is most development machines --
  both work identically and you never find out. Deploy to an instance where
  they differ and the hand-written one throws Msg 468 on the join.

  01-setup.sql created TempdbDemo with a collation chosen to differ from
  tempdb's precisely so this reproduces. If it could not find one, the
  scenario reports that instead of showing a false pass.

  F2 and F3 are the two categorical rules, the ones that are not tradeoffs:
     - no temp table can be referenced inside a function, at all
     - a table variable survives ROLLBACK; a temp table does not
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO F: collation and the hard stops ---';
GO

DECLARE @viable varchar(10) =
    (SELECT SettingValue FROM Demo.DemoState WHERE SettingName = 'CollationScenarioViable');

IF @viable <> 'YES'
BEGIN
    RAISERROR('  tempdb and TempdbDemo share a collation -- F1 cannot demonstrate anything.', 0, 1) WITH NOWAIT;
    EXEC Demo.usp_Record 'F. Collation and hard stops', 1,
         'collation conflict repro', NULL, NULL,
         'skipped: no differing collation available on this instance',
         'a collation conflict', 'SKIPPED';
END
GO

-- F1a. The two ways of creating the temp table, and the collation each lands on.
CREATE TABLE #explicit (code varchar(20));
INSERT #explicit (code) VALUES ('ACME');
GO

SELECT code INTO #into FROM Demo.Customer;
GO

DECLARE @explicitColl sysname =
    (SELECT collation_name FROM tempdb.sys.columns
     WHERE object_id = OBJECT_ID('tempdb..#explicit') AND name = 'code');
DECLARE @intoColl sysname =
    (SELECT collation_name FROM tempdb.sys.columns
     WHERE object_id = OBJECT_ID('tempdb..#into') AND name = 'code');
DECLARE @dbColl sysname = CAST(DATABASEPROPERTYEX(DB_NAME(),'Collation') AS sysname);

DECLARE @vExplicit varchar(24) =
    CASE WHEN @explicitColl = @dbColl THEN 'matches this db' ELSE 'MISMATCH' END;
DECLARE @vInto varchar(24) =
    CASE WHEN @intoColl = @dbColl THEN 'matches this db' ELSE 'MISMATCH' END;

EXEC Demo.usp_Record 'F. Collation and hard stops', 2,
     'CREATE TABLE #t (code varchar(20))', 'column collation', NULL,
     @explicitColl, 'takes TEMPDB collation', @vExplicit;

EXEC Demo.usp_Record 'F. Collation and hard stops', 3,
     'SELECT code INTO #t FROM Demo.Customer', 'column collation', NULL,
     @intoColl, 'inherits SOURCE collation', @vInto;
GO

/*------------------------------------------------------------------------------
  F1b. Now join each one and see which survives.

  Each join runs through sp_executesql, and that is not decoration.

  A collation conflict is raised when the statement is BOUND, not when it runs.
  A compile error in a statement that sits directly inside a TRY block belongs
  to the same batch as the TRY itself, so it aborts the batch instead of
  transferring to CATCH -- the error goes to the client and the recording code
  below it never executes. Pushing the statement into dynamic SQL makes it a
  separate batch, whose compile error the outer CATCH can then handle.

  Dynamic SQL runs in a child scope, so it still sees temp tables created by
  this session.
------------------------------------------------------------------------------*/
BEGIN TRY
    DECLARE @n int;
    EXEC sys.sp_executesql
         N'SELECT @cnt = COUNT_BIG(*) FROM Demo.Customer AS c JOIN #into AS t ON c.code = t.code;',
         N'@cnt int OUTPUT', @cnt = @n OUTPUT;
    EXEC Demo.usp_Record 'F. Collation and hard stops', 4,
         'JOIN the SELECT INTO temp table', 'rows', @n, NULL,
         'succeeds: collation inherited from source', 'OK';
END TRY
BEGIN CATCH
    DECLARE @e1 nvarchar(200) = ERROR_MESSAGE();
    EXEC Demo.usp_Record 'F. Collation and hard stops', 4,
         'JOIN the SELECT INTO temp table', NULL, NULL, @e1,
         'succeeds: collation inherited from source', 'FAILED';
END CATCH
GO

BEGIN TRY
    DECLARE @n int;
    EXEC sys.sp_executesql
         N'SELECT @cnt = COUNT_BIG(*) FROM Demo.Customer AS c JOIN #explicit AS t ON c.code = t.code;',
         N'@cnt int OUTPUT', @cnt = @n OUTPUT;
    EXEC Demo.usp_Record 'F. Collation and hard stops', 5,
         'JOIN the CREATE TABLE temp table', 'rows', @n, NULL,
         'Msg 468 collation conflict', 'no conflict here';
END TRY
BEGIN CATCH
    DECLARE @e2 nvarchar(200) = ERROR_MESSAGE();
    EXEC Demo.usp_Record 'F. Collation and hard stops', 5,
         'JOIN the CREATE TABLE temp table', NULL, NULL, @e2,
         'Msg 468 collation conflict', 'CONFLICT (as predicted)';
END CATCH
GO

-- F1c. The fix: say what collation you mean, and the problem disappears.
CREATE TABLE #fixed (code varchar(20) COLLATE DATABASE_DEFAULT);
INSERT #fixed (code) VALUES ('ACME');
GO

BEGIN TRY
    DECLARE @n int;
    EXEC sys.sp_executesql
         N'SELECT @cnt = COUNT_BIG(*) FROM Demo.Customer AS c JOIN #fixed AS t ON c.code = t.code;',
         N'@cnt int OUTPUT', @cnt = @n OUTPUT;
    EXEC Demo.usp_Record 'F. Collation and hard stops', 6,
         'JOIN #t declared COLLATE DATABASE_DEFAULT', 'rows', @n, NULL,
         'succeeds -- this is the fix', 'OK';
END TRY
BEGIN CATCH
    DECLARE @e3 nvarchar(200) = ERROR_MESSAGE();
    EXEC Demo.usp_Record 'F. Collation and hard stops', 6,
         'JOIN #t declared COLLATE DATABASE_DEFAULT', NULL, NULL, @e3,
         'succeeds -- this is the fix', 'FAILED';
END CATCH
GO

DROP TABLE IF EXISTS #explicit;
DROP TABLE IF EXISTS #into;
DROP TABLE IF EXISTS #fixed;
GO

-- F2. A temp table inside a function. Not a tradeoff -- a hard stop.
BEGIN TRY
    EXEC ('CREATE FUNCTION Demo.fn_Illegal() RETURNS @r TABLE (x int) AS
           BEGIN CREATE TABLE #t (x int); INSERT @r VALUES (1); RETURN; END');
    EXEC Demo.usp_Record 'F. Collation and hard stops', 7,
         'CREATE FUNCTION containing a #temp table', NULL, NULL, NULL,
         'blocked by the engine', 'ALLOWED (unexpected)';
    DROP FUNCTION IF EXISTS Demo.fn_Illegal;
END TRY
BEGIN CATCH
    DECLARE @e4 nvarchar(200) = ERROR_MESSAGE();
    EXEC Demo.usp_Record 'F. Collation and hard stops', 7,
         'CREATE FUNCTION containing a #temp table', NULL, NULL, @e4,
         'blocked by the engine', 'BLOCKED (as predicted)';
END CATCH
GO

-- F3. Rollback. The one case where a table variable is not a weaker #temp.
CREATE TABLE #audit (msg varchar(50));
DECLARE @audit_var TABLE (msg varchar(50));

BEGIN TRAN;
    INSERT #audit     (msg) VALUES ('logged to #temp');
    INSERT @audit_var (msg) VALUES ('logged to @tablevar');
ROLLBACK;

DECLARE @tempRows int = (SELECT COUNT_BIG(*) FROM #audit);
DECLARE @varRows  int = (SELECT COUNT_BIG(*) FROM @audit_var);

DECLARE @vTemp varchar(24) = CASE WHEN @tempRows = 0 THEN 'ROLLED BACK' ELSE 'unexpected' END;
DECLARE @vVar  varchar(24) = CASE WHEN @varRows  = 1 THEN 'SURVIVED'    ELSE 'unexpected' END;

EXEC Demo.usp_Record 'F. Collation and hard stops', 8,
     '#temp rows surviving ROLLBACK', 'rows', @tempRows, NULL,
     '0 -- rolled back with the transaction', @vTemp;

EXEC Demo.usp_Record 'F. Collation and hard stops', 9,
     '@tablevar rows surviving ROLLBACK', 'rows', @varRows, NULL,
     '1 -- table variables ignore rollback', @vVar;

DROP TABLE IF EXISTS #audit;
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. SCENARIO A: is a CTE materialised? ===';
GO
SELECT StepNo, Item, LogicalReads = CAST(NumericValue AS bigint), Expected, Verdict
FROM   Demo.DemoResults WHERE Scenario = 'A. CTE is a macro' ORDER BY StepNo;
GO

PRINT '';
PRINT '=== 2. SCENARIO B: estimates under skew (#temp has a histogram) ===';
GO
SELECT StepNo, Item, Operator = TextValue, EstimatedRows = CAST(NumericValue AS bigint),
       TrueRows = Expected, Verdict
FROM   Demo.DemoResults WHERE Scenario = 'B. Estimates under skew' ORDER BY StepNo;
GO

PRINT '';
PRINT '=== 3. SCENARIO C: parallelism (writes serial, reads not) ===';
GO
SELECT StepNo, Item, DOP = CAST(NumericValue AS int), Expected, Verdict
FROM   Demo.DemoResults WHERE Scenario = 'C. Parallelism' ORDER BY StepNo;
GO

PRINT '';
PRINT '=== 4. SCENARIO D: what breaks temp table caching ===';
GO
SELECT StepNo, Item, CreationsPer50Calls = CAST(NumericValue AS int), Expected, Verdict
FROM   Demo.DemoResults WHERE Scenario = 'D. Temp table caching' ORDER BY StepNo;
GO

PRINT '';
PRINT '=== 5. SCENARIO E: the 8 MB cliff ===';
GO
SELECT StepNo, Rows = Item, DataSize = TextValue,
       CreationsPer20Calls = CAST(NumericValue AS int), Verdict
FROM   Demo.DemoResults WHERE Scenario = 'E. The 8 MB cliff' ORDER BY StepNo;
GO

PRINT '';
PRINT '=== 6. SCENARIO F: collation and the hard stops ===';
GO
SELECT StepNo, Item, Rows = CAST(NumericValue AS int), Detail = TextValue, Expected, Verdict
FROM   Demo.DemoResults WHERE Scenario = 'F. Collation and hard stops' ORDER BY StepNo;
GO

PRINT '';
PRINT '=== 7. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, StepNo, Item, NumericValue, TextValue, Expected, Verdict
FROM   Demo.DemoResults
WHERE  Verdict IN ('unexpected', 'INTERMITTENT', 'INCONCLUSIVE', 'FAILED',
                   'ALLOWED (unexpected)', 'no conflict here', 'inaccurate', 'SKIPPED')
ORDER BY ResultID;
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 7 should be EMPTY. Anything in it is either';
PRINT ' a genuine difference on your build, or an instance';
PRINT ' setting the scenario could not work around -- both are';
PRINT ' worth reading before you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
