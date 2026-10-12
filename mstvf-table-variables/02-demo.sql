/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Five scenarios about multi-statement table-valued functions (MSTVFs) and
  table variables, the two places SQL Server has long estimated rows with a
  fixed guess instead of statistics:

     A  an MSTVF returning 199,697 rows: estimated as 1 (legacy CE), 100
        (newer CE), then exactly (interleaved execution); and the inline
        function
     B  a filter outside an MSTVF: the function builds every row first
     C  interleaved execution doesn't apply to INSERT ... SELECT
     D  table variables: the row count (deferred compilation fixes it),
        the distribution (it doesn't), and a plan reused for a different
        row count
     E  a table variable keeps its rows through ROLLBACK

  Each measured query is a procedure in 01-setup.sql, run once after
  sp_recompile. Its actual plan comes from sys.dm_exec_query_plan_stats.

  WHAT THIS CHANGES: nothing outside TvfDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE TvfDemo;
GO
SET NOCOUNT ON;
GO

TRUNCATE TABLE Demo.Runs;
TRUNCATE TABLE Demo.Verdicts;
GO


/*==============================================================================
  The measurements.
==============================================================================*/
PRINT '=== A: the MSTVF''s estimate ===';
EXEC Demo.usp_Run 'A', 'MSTVF, legacy CE, no interleaved execution', 'q_A_Legacy',      N'[fn_Orders]';
EXEC Demo.usp_Run 'A', 'MSTVF, no interleaved execution',            'q_A_Fixed',       N'[fn_Orders]';
EXEC Demo.usp_Run 'A', 'MSTVF, interleaved execution',               'q_A_Interleaved', N'[fn_Orders]';
EXEC Demo.usp_Run 'A', 'inline TVF',                                 'q_A_Inline',      N'none';
GO
PRINT '=== B: a filter outside the function ===';
EXEC Demo.usp_Run 'B', 'MSTVF, WHERE CustomerID = 42 outside it',    'q_B_Mstvf',       N'[fn_Orders]';
EXEC Demo.usp_Run 'B', 'inline TVF, WHERE CustomerID = 42 outside it', 'q_B_Inline',    N'none';
GO
PRINT '=== C: INSERT ... SELECT ===';
EXEC Demo.usp_Run 'C', 'MSTVF, INSERT ... SELECT',                   'q_C_InsertMstvf',  N'[fn_Orders]';
EXEC Demo.usp_Run 'C', 'inline TVF, INSERT ... SELECT',              'q_C_InsertInline', N'none';
GO
PRINT '=== D: table variables ===';
EXEC Demo.usp_Run 'D', 'table variable, no deferred compilation',    'q_D_TvLegacy',    N'[@t]';
EXEC Demo.usp_Run 'D', 'table variable, deferred compilation',       'q_D_TvDeferred',  N'[@t]';
EXEC Demo.usp_Run 'D', 'table variable, WHERE Status = ''Open''',    'q_D_TvOpen',      N'[@t]';
EXEC Demo.usp_Run 'D', 'temp table, WHERE Status = ''Open''',        'q_D_TempOpen',    N'[#t]';
-- The same procedure twice: compiled for 2 days of orders, then reused for 2 years.
EXEC Demo.usp_Run 'D', 'table variable, 1st call: since 28 Dec 2024', 'q_D_TvReuse',    N'[@t]', @Since = '20241228';
EXEC Demo.usp_Run 'D', 'table variable, 2nd call: since 1 Jan 2023', 'q_D_TvReuse',     N'[@t]', @Since = '20230101', @Recompile = 0;
GO


/*==============================================================================
  E. ROLLBACK and a table variable. Three rows into a table variable and a
     temp table inside a transaction, then ROLLBACK.
==============================================================================*/
PRINT '=== E: ROLLBACK ===';
GO
DECLARE @log TABLE (Step varchar(40));
CREATE TABLE #log (Step varchar(40));

BEGIN TRANSACTION;
    INSERT @log VALUES ('step 1'), ('step 2'), ('step 3');
    INSERT #log VALUES ('step 1'), ('step 2'), ('step 3');
ROLLBACK;

DECLARE @tv int = (SELECT COUNT(*) FROM @log), @tt int = (SELECT COUNT(*) FROM #log);
INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('E', 'a table variable keeps its rows through ROLLBACK',
 'rows after ROLLBACK: table variable ' + CAST(@tv AS varchar(10)) + ', temp table ' + CAST(@tt AS varchar(10)),
 CASE WHEN @tv = 3 AND @tt = 0 THEN 'CONFIRMED' ELSE 'unexpected' END);
DROP TABLE #log;
GO


/*==============================================================================
  Verdicts.
==============================================================================*/
DECLARE @legacy_est float, @legacy_reads bigint, @fixed_est float, @fixed_reads bigint,
        @int_est float, @int_act bigint, @int_reads bigint, @inl_reads bigint,
        @bm_reads bigint, @bm_act bigint, @bi_reads bigint,
        @cm_est float, @cm_reads bigint, @ci_reads bigint,
        @tl_est float, @tl_act bigint, @tl_reads bigint,
        @td_est float, @td_act bigint, @td_reads bigint,
        @to_est float, @to_act bigint, @to_join varchar(40), @to_spill bit, @to_reads bigint,
        @tt_est float, @tt_act bigint, @tt_reads bigint,
        @r1_act bigint, @r2_est float, @r2_act bigint, @r2_join varchar(40), @r2_spill bit;

SELECT @legacy_est = EstRows, @legacy_reads = Reads FROM Demo.Runs WHERE Proc_ = 'q_A_Legacy';
SELECT @fixed_est  = EstRows, @fixed_reads  = Reads FROM Demo.Runs WHERE Proc_ = 'q_A_Fixed';
SELECT @int_est = EstRows, @int_act = ActualRows, @int_reads = Reads FROM Demo.Runs WHERE Proc_ = 'q_A_Interleaved';
SELECT @inl_reads = Reads FROM Demo.Runs WHERE Proc_ = 'q_A_Inline';
SELECT @bm_reads = Reads, @bm_act = FnRows FROM Demo.Runs WHERE Proc_ = 'q_B_Mstvf';
SELECT @bi_reads = Reads FROM Demo.Runs WHERE Proc_ = 'q_B_Inline';
SELECT @cm_est = EstRows, @cm_reads = Reads FROM Demo.Runs WHERE Proc_ = 'q_C_InsertMstvf';
SELECT @ci_reads = Reads FROM Demo.Runs WHERE Proc_ = 'q_C_InsertInline';
SELECT @tl_est = EstRows, @tl_act = ActualRows, @tl_reads = Reads FROM Demo.Runs WHERE Proc_ = 'q_D_TvLegacy';
SELECT @td_est = EstRows, @td_act = ActualRows, @td_reads = Reads FROM Demo.Runs WHERE Proc_ = 'q_D_TvDeferred';
SELECT @to_est = EstRows, @to_act = ActualRows, @to_join = JoinType, @to_spill = Spilled, @to_reads = Reads FROM Demo.Runs WHERE Proc_ = 'q_D_TvOpen';
SELECT @tt_est = EstRows, @tt_act = ActualRows, @tt_reads = Reads FROM Demo.Runs WHERE Proc_ = 'q_D_TempOpen';
SELECT @r1_act = ActualRows FROM Demo.Runs WHERE Proc_ = 'q_D_TvReuse' AND Label LIKE '%1st call%';
SELECT @r2_est = EstRows, @r2_act = ActualRows, @r2_join = JoinType, @r2_spill = Spilled FROM Demo.Runs WHERE Proc_ = 'q_D_TvReuse' AND Label LIKE '%2nd call%';

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('A', 'legacy CE guesses 1 row for an MSTVF, and the plan costs far more',
 'estimate ' + CAST(@legacy_est AS varchar(20)) + ' of ' + CAST(@int_act AS varchar(20)) + '; reads ' + CAST(@legacy_reads AS varchar(20)) + ' vs ' + CAST(@int_reads AS varchar(20)) + ' interleaved',
 CASE WHEN @legacy_est = 1 AND @legacy_reads >= 5 * @int_reads THEN 'CONFIRMED' ELSE 'unexpected' END),
('A', 'the newer CE guesses 100, no better here',
 'estimate ' + CAST(@fixed_est AS varchar(20)) + '; reads ' + CAST(@fixed_reads AS varchar(20)),
 CASE WHEN @fixed_est = 100 AND @fixed_reads >= 5 * @int_reads THEN 'CONFIRMED' ELSE 'unexpected' END),
('A', 'interleaved execution runs the function first and uses the real count',
 'estimate ' + CAST(@int_est AS varchar(20)) + ', actual ' + CAST(@int_act AS varchar(20)),
 CASE WHEN ABS(@int_est - @int_act) <= 0.01 * @int_act THEN 'CONFIRMED' ELSE 'unexpected' END),
('A', 'the inline function reads less still',
 'reads ' + CAST(@inl_reads AS varchar(20)) + ' vs ' + CAST(@int_reads AS varchar(20)),
 CASE WHEN @inl_reads < @int_reads THEN 'CONFIRMED' ELSE 'unexpected' END),

('B', 'an MSTVF builds every row before the outer WHERE filters them',
 'the function built ' + CAST(@bm_act AS varchar(20)) + ' rows for one customer''s 25; reads ' + CAST(@bm_reads AS varchar(20)) + ' vs ' + CAST(@bi_reads AS varchar(20)) + ' inline',
 CASE WHEN @bm_act = 500000 AND @bm_reads >= 100 * @bi_reads THEN 'CONFIRMED' ELSE 'unexpected' END),

('C', 'in INSERT ... SELECT, the MSTVF is back to the 100-row guess',
 'estimate ' + CAST(@cm_est AS varchar(20)) + '; reads ' + CAST(@cm_reads AS varchar(20)) + ' vs ' + CAST(@int_reads AS varchar(20)) + ' as a SELECT',
 CASE WHEN @cm_est = 100 AND @cm_reads >= 5 * @int_reads THEN 'CONFIRMED' ELSE 'unexpected' END),
('C', 'the inline function inserts as cheaply as it selects',
 'reads ' + CAST(@ci_reads AS varchar(20)) + ' vs ' + CAST(@inl_reads AS varchar(20)) + ' as a SELECT',
 CASE WHEN @ci_reads <= 2 * @inl_reads + 1000 THEN 'CONFIRMED' ELSE 'unexpected' END),

('D', 'without deferred compilation, a table variable is estimated at 1 row',
 'estimate ' + CAST(@tl_est AS varchar(20)) + ' of ' + CAST(@tl_act AS varchar(20)) + '; reads ' + CAST(@tl_reads AS varchar(20)) + ' vs ' + CAST(@td_reads AS varchar(20)),
 CASE WHEN @tl_est = 1 AND @tl_reads >= 5 * @td_reads THEN 'CONFIRMED' ELSE 'unexpected' END),
('D', 'deferred compilation uses the real row count',
 'estimate ' + CAST(@td_est AS varchar(20)) + ', actual ' + CAST(@td_act AS varchar(20)),
 CASE WHEN ABS(@td_est - @td_act) <= 0.01 * @td_act THEN 'CONFIRMED' ELSE 'unexpected' END),
('D', 'but not the distribution: a filter on a table variable column is a guess',
 'estimate ' + CAST(ROUND(@to_est, 0) AS varchar(20)) + ', actual ' + CAST(@to_act AS varchar(20)) + '; ' + ISNULL(@to_join, '?')
     + CASE WHEN @to_spill = 1 THEN ', sort spilled' ELSE '' END + '; reads ' + CAST(@to_reads AS varchar(20)) + ' vs ' + CAST(@tt_reads AS varchar(20)) + ' temp table',
 CASE WHEN @to_est * 10 < @to_act AND @to_reads >= 5 * @tt_reads THEN 'CONFIRMED' ELSE 'unexpected' END),
('D', 'a temp table has statistics on the column',
 'estimate ' + CAST(@tt_est AS varchar(20)) + ', actual ' + CAST(@tt_act AS varchar(20)),
 CASE WHEN ABS(@tt_est - @tt_act) <= 0.05 * @tt_act THEN 'CONFIRMED' ELSE 'unexpected' END),
('D', 'the deferred estimate is reused for the next call, whatever its size',
 '2nd call: estimate ' + CAST(@r2_est AS varchar(20)) + ' (the 1st call''s ' + CAST(@r1_act AS varchar(20)) + '), actual ' + CAST(@r2_act AS varchar(20)) + '; ' + ISNULL(@r2_join, '?')
     + CASE WHEN @r2_spill = 1 THEN ', sort spilled' ELSE '' END,
 CASE WHEN ABS(@r2_est - @r1_act) <= 0.01 * @r1_act AND @r2_act >= 50 * @r1_act THEN 'CONFIRMED' ELSE 'unexpected' END);
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. EVERY MEASURED RUN ===';
GO
SELECT Scenario, Label, EstRows = CAST(ROUND(EstRows, 0) AS bigint), ActualRows, JoinType,
       Spilled = CASE Spilled WHEN 1 THEN 'yes' ELSE 'no' END, Reads, CpuMs, FunctionBuilt = FnRows
FROM   Demo.Runs ORDER BY Seq;
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
PRINT ' genuine difference on your build, worth reading';
PRINT ' before you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
