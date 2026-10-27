/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  Five scenarios, run end to end, each recording its own evidence into
  Demo.DemoResults and Demo.ReportRuns. The summary at the bottom is the
  payoff -- you should not have to read a single execution plan by hand.

  Scenarios
    A  what the statistics know        -> a histogram that ends on
                                          2025-12-31, on a table that
                                          now runs to 2026-01-07
    B  the estimate for the new rows   -> legacy CE: 1 row. New CE: a guess.
                                          The control week: accurate.
    C  why nothing updated them        -> 21,000 changes; the threshold is
                                          31,623. Cross it and it fires.
    D  what the bad estimate costs     -> legacy CE: seek + 21,000 lookups
                                          instead of one scan
    E  what actually fixes it          -> which REBUILD refreshes the
                                          statistics, which does not, and a
                                          query hint that needs no refresh

  Expected runtime: under a minute. Scenarios C and E reset the statistics
  with Demo.usp_MakeStale between steps, so this file can be re-run without
  re-running setup.

  Object-scoped cache operations only: every recompile is sp_recompile on one
  procedure. Nothing here flushes the instance's plan cache.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers,
  MAXDOP 0, cost threshold for parallelism 5, database compatibility level 160.
==============================================================================*/

USE AscendingKeyDemo;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;   -- XML methods below; sqlcmd defaults it OFF
GO

IF OBJECT_ID('Demo.usp_RunReport') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

TRUNCATE TABLE Demo.DemoResults;
TRUNCATE TABLE Demo.ReportRuns;
GO

-- Start from a known state, whatever a previous run left behind.
EXEC Demo.usp_MakeStale @NewRows = 21000;
GO


/*==============================================================================
  SCENARIO A -- what the statistics know

  The statistics on IX_Orders_OrderDate were built with a FULL SCAN. By every
  measure SQL Server applies they are healthy: they sampled every row, and
  the table has changed by about 2% since. They are also blind to a week of
  data, because every one of the new rows is later than the histogram's last
  step.

  That is the ascending-key problem in one sentence: new rows always land
  past the end of the histogram, and the queries most likely to ask about
  them -- "today", "this week", "since the last load" -- ask about nothing
  else.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO A: what the statistics know ---';
GO

DECLARE @lastStep date =
    (SELECT TOP (1) CAST(range_high_key AS date)
     FROM   sys.dm_db_stats_histogram(OBJECT_ID('Demo.Orders'),
                                      (SELECT stats_id FROM sys.stats
                                       WHERE  object_id = OBJECT_ID('Demo.Orders')
                                         AND  name = 'IX_Orders_OrderDate'))
     ORDER BY step_number DESC);
DECLARE @maxDate date   = (SELECT MAX(OrderDate) FROM Demo.Orders);
DECLARE @rowsAt  bigint, @sampled bigint, @mods bigint;

SELECT @rowsAt = sp.[rows], @sampled = sp.rows_sampled, @mods = sp.modification_counter
FROM   sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE  s.object_id = OBJECT_ID('Demo.Orders') AND s.name = 'IX_Orders_OrderDate';

DECLARE @beyond bigint = (SELECT COUNT_BIG(*) FROM Demo.Orders WHERE OrderDate > @lastStep);

DECLARE @lastStepTxt nvarchar(200) = CONVERT(nvarchar(10), @lastStep, 23);
DECLARE @maxDateTxt  nvarchar(200) = CONVERT(nvarchar(10), @maxDate, 23);
DECLARE @vSample varchar(24) = CASE WHEN @sampled = @rowsAt THEN 'FULL SCAN' ELSE 'sampled' END;
DECLARE @vBlind  varchar(24) = CASE WHEN @maxDate > @lastStep THEN 'BLIND SPOT' ELSE 'unexpected' END;

EXEC Demo.usp_Record 'A. What the statistics know', 1, 'rows when the statistics were built',
     'rows', @rowsAt, NULL, 'every row sampled', @vSample;
EXEC Demo.usp_Record 'A. What the statistics know', 2, 'modifications since',
     'rows', @mods, NULL, '21,000 -- about 2% of the table', 'INFO';
EXEC Demo.usp_Record 'A. What the statistics know', 3, 'last histogram step',
     NULL, NULL, @lastStepTxt, '2025-12-31', 'INFO';
EXEC Demo.usp_Record 'A. What the statistics know', 4, 'latest OrderDate in the table',
     NULL, NULL, @maxDateTxt, '2026-01-07', 'INFO';
EXEC Demo.usp_Record 'A. What the statistics know', 5, 'rows past the last histogram step',
     'rows', @beyond, NULL, 'all 21,000 new rows', @vBlind;
GO


/*==============================================================================
  SCENARIO B -- the estimate for rows the histogram has never seen

  Three questions, each asked of both cardinality estimators, all compiled
  together in Demo.usp_B_Estimates:

     B1/B2  everything since 2026-01-01   21,000 rows, all past the histogram
     B3/B4  one day, 2026-01-03            3,000 rows, all past the histogram
     B5/B6  the last week of 2025         ~19,000 rows, inside the histogram

  What to look for:
    - the LEGACY estimator says 1 row for both questions about 2026. Past the
      last step, as far as it is concerned, there is nothing.
    - the NEW estimator (SQL Server 2014+, compatibility level 120 and up)
      assumes rows do exist out there, and guesses. On the tested build its
      range guess was exactly 30% of the modification counter (6,300 of
      21,000), and its single-day guess was the square root of the table's
      row count (1,010). Better than 1. Still 3x short.
    - both estimators are accurate for the control week, which proves the
      statistics themselves are sound. They are just out of date.

  Plans are read with the per-statement pattern explained in the tempdb
  topic: select each StmtSimple first, then a relative path inside it.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO B: estimates past the histogram ---';
GO

EXEC sys.sp_recompile N'Demo.usp_B_Estimates';
GO
EXEC Demo.usp_B_Estimates;
GO

DECLARE @plan xml;

SELECT TOP (1) @plan = qp.query_plan
FROM   sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE  st.objectid = OBJECT_ID('Demo.usp_B_Estimates')
  AND  st.dbid     = DB_ID()
  AND  qp.query_plan IS NOT NULL;

DECLARE @all  bigint = (SELECT COUNT_BIG(*) FROM Demo.Orders WHERE OrderDate >= '20260101');
DECLARE @day  bigint = (SELECT COUNT_BIG(*) FROM Demo.Orders WHERE OrderDate =  '20260103');
DECLARE @ctrl bigint = (SELECT COUNT_BIG(*) FROM Demo.Orders WHERE OrderDate >= '20251225' AND OrderDate < '20260101');

IF @plan IS NULL
    RAISERROR('  no plan retrievable for Demo.usp_B_Estimates -- scenario B skipped', 0, 1) WITH NOWAIT;
ELSE
BEGIN
    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
     stmts AS
     (
        SELECT  StatementText = n.value('@StatementText', 'nvarchar(600)'),
                CeVersion     = n.value('@CardinalityEstimationModelVersion', 'int'),
                EstimateRows  = n.value('(.//RelOp[IndexScan]/@EstimateRows)[1]', 'float')
        FROM    @plan.nodes('//StmtSimple') AS x(n)
     ),
     tagged AS
     (
        SELECT  Marker = CASE WHEN StatementText LIKE '%B1 */%' THEN 1
                              WHEN StatementText LIKE '%B2 */%' THEN 2
                              WHEN StatementText LIKE '%B3 */%' THEN 3
                              WHEN StatementText LIKE '%B4 */%' THEN 4
                              WHEN StatementText LIKE '%B5 */%' THEN 5
                              WHEN StatementText LIKE '%B6 */%' THEN 6 END,
                CeVersion, EstimateRows
        FROM    stmts
     ),
     judged AS
     (
        SELECT  Marker, CeVersion, EstimateRows,
                Actual = CASE WHEN Marker IN (1,2) THEN @all
                              WHEN Marker IN (3,4) THEN @day
                              ELSE @ctrl END
        FROM    tagged
        WHERE   Marker IS NOT NULL
     )
     INSERT Demo.DemoResults (Scenario, StepNo, Item, Measure, NumericValue, TextValue, Expected, Verdict)
     SELECT  'B. Estimates past the histogram',
             Marker,
             CASE Marker
                  WHEN 1 THEN 'since 2026-01-01         new CE'
                  WHEN 2 THEN 'since 2026-01-01         legacy CE'
                  WHEN 3 THEN 'on 2026-01-03            new CE'
                  WHEN 4 THEN 'on 2026-01-03            legacy CE'
                  WHEN 5 THEN 'last week of 2025 (ctrl) new CE'
                  ELSE        'last week of 2025 (ctrl) legacy CE' END,
             'estimated rows',
             EstimateRows,
             N'actual ' + CAST(Actual AS nvarchar(20)) + N'; CE model ' + CAST(CeVersion AS nvarchar(10)),
             CASE WHEN Marker IN (2,4) THEN '1 -- nothing past the last step'
                  WHEN Marker IN (1,3) THEN 'a guess, well short of actual'
                  ELSE 'close to actual' END,
             CASE WHEN Marker IN (2,4) AND EstimateRows <= 1                          THEN 'ONE ROW'
                  WHEN Marker IN (1,3) AND EstimateRows > 1 AND EstimateRows < Actual * 0.5 THEN 'UNDERESTIMATE'
                  WHEN Marker IN (5,6) AND ABS(EstimateRows - Actual) <= Actual * 0.1 THEN 'ACCURATE'
                  ELSE 'unexpected' END
     FROM    judged;
END
GO


/*==============================================================================
  SCENARIO C -- why the automatic update never fired

  AUTO_UPDATE_STATISTICS is ON, so why are the statistics still blind? Because
  "stale" is defined by a threshold, and 21,000 changes to a million-row table
  is under it.

     compatibility level < 130    500 + 20% of rows          = 200,500
     compatibility level 130+     MIN(that, SQRT(1000 x rows)) =  31,623

  (The second formula is what trace flag 2371 used to enable. From 2016 it is
  the default at compatibility level 130 and above.)

  The check happens when a query that USES the statistics is compiled -- not
  when the rows are written. So this scenario sets the modification counter
  just under the threshold, compiles the report, and checks whether the
  statistics changed; then sets it just over and does the same.

  What to look for:
    - just under: statistics untouched
    - just over:  AUTO-UPDATED by the compile
    - a busy week is nowhere near the 20% rule, and two-thirds of the way to
      the dynamic one. On a 100-million-row table the dynamic threshold is
      316,228 changes; on a billion rows, a million.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO C: the automatic update threshold ---';
GO

DECLARE @compat int =
    (SELECT CAST(SettingValue AS int) FROM Demo.DemoState WHERE SettingName = 'CompatibilityLevel');
DECLARE @auto nvarchar(10) =
    (SELECT SettingValue FROM Demo.DemoState WHERE SettingName = 'AutoUpdateStats');
DECLARE @async nvarchar(10) =
    (SELECT SettingValue FROM Demo.DemoState WHERE SettingName = 'AutoUpdateAsync');
DECLARE @rows bigint =
    (SELECT sp.[rows] FROM sys.stats AS s
     CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
     WHERE s.object_id = OBJECT_ID('Demo.Orders') AND s.name = 'IX_Orders_OrderDate');

DECLARE @legacyThreshold  decimal(18,3) = 500 + 0.2 * @rows;
DECLARE @dynamicThreshold decimal(18,3) =
    CASE WHEN @compat >= 130 AND SQRT(1000.0 * @rows) < @legacyThreshold
         THEN SQRT(1000.0 * @rows) ELSE @legacyThreshold END;

EXEC Demo.usp_Record 'C. Auto-update threshold', 1, 'threshold: 500 + 20% (compat < 130)',
     'modifications', @legacyThreshold, NULL, '200,500', 'INFO';
EXEC Demo.usp_Record 'C. Auto-update threshold', 2, 'threshold in force on this database',
     'modifications', @dynamicThreshold, NULL, '31,623 at compat 130+', 'INFO';

DECLARE @mods bigint =
    (SELECT sp.modification_counter FROM sys.stats AS s
     CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
     WHERE s.object_id = OBJECT_ID('Demo.Orders') AND s.name = 'IX_Orders_OrderDate');
DECLARE @vWeek varchar(24) = CASE WHEN @mods < @dynamicThreshold THEN 'BELOW THRESHOLD' ELSE 'unexpected' END;

EXEC Demo.usp_Record 'C. Auto-update threshold', 3, 'a busy week: modifications so far',
     'modifications', @mods, NULL, 'under the threshold', @vWeek;

-- The two probes, either side of the line. Async auto-update would apply the
-- update in the background after the compile, and AUTO_UPDATE_STATISTICS OFF
-- would never apply it -- either makes this probe meaningless, so say so.
DECLARE @below int = CAST(FLOOR(@dynamicThreshold) AS int) - 100;
DECLARE @above int = CAST(CEILING(@dynamicThreshold) AS int) + 100;
DECLARE @probe TABLE (Seq int, NewRows int);
INSERT @probe VALUES (4, @below), (5, @above);

DECLARE @seq int = 4, @n int, @before datetime2(7), @after datetime2(7), @label varchar(90);
WHILE @seq <= 5
BEGIN
    SELECT @n = NewRows FROM @probe WHERE Seq = @seq;
    EXEC Demo.usp_MakeStale @NewRows = @n;

    SELECT @before = sp.last_updated FROM sys.stats AS s
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
    WHERE s.object_id = OBJECT_ID('Demo.Orders') AND s.name = 'IX_Orders_OrderDate';

    -- The compile is what checks the threshold.
    EXEC Demo.usp_RunReport 'C. Auto-update threshold', @seq, 'threshold probe', 'Demo.usp_Report';

    SELECT @after = sp.last_updated FROM sys.stats AS s
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
    WHERE s.object_id = OBJECT_ID('Demo.Orders') AND s.name = 'IX_Orders_OrderDate';

    DECLARE @upd varchar(24) = CASE WHEN @after > @before THEN 'AUTO-UPDATED' ELSE 'not updated' END;
    DECLARE @verdict varchar(24) =
        CASE WHEN @auto <> N'ON' OR @async <> N'OFF'      THEN 'INCONCLUSIVE'
             WHEN @seq = 4 AND @upd = 'not updated'       THEN 'NOT UPDATED'
             WHEN @seq = 5 AND @upd = 'AUTO-UPDATED'      THEN 'AUTO-UPDATED'
             ELSE 'unexpected' END;
    SET @label = CASE @seq WHEN 4 THEN 'compile with 100 changes under the threshold'
                           ELSE        'compile with 100 changes over the threshold' END;
    DECLARE @exp nvarchar(140) = CASE @seq WHEN 4 THEN 'statistics untouched' ELSE 'statistics refreshed by the compile' END;

    EXEC Demo.usp_Record 'C. Auto-update threshold', @seq, @label, 'modifications', @n, NULL, @exp, @verdict;

    SET @seq += 1;
END

EXEC Demo.usp_MakeStale @NewRows = 21000;
GO


/*==============================================================================
  SCENARIO D -- what the bad estimate costs

  The morning report -- top 100 customers since 2026-01-01 -- run four ways:
  stale and fresh statistics, legacy and new estimator. Each run recompiles
  its own procedure first (sp_recompile, object scoped).

  What to look for:
    - legacy CE, stale: estimate 1 row, so the optimizer seeks on OrderDate
      and plans one lookup into the clustered index. It gets 21,000 lookups,
      at about three page reads each, serial, with a memory grant sized for
      one row.
    - legacy CE, fresh: estimate 21,000, one parallel scan of the table, a
      fraction of the reads.
    - new CE, stale: its 6,300-row guess was already large enough to choose
      the scan, so on this query and this data it gets the same plan as
      fresh statistics. That is a real result, not a pass: the guess is still
      3x short, and a query whose tipping point fell between 6,300 and 21,000
      would not be so lucky. Plenty of databases still run the legacy
      estimator after an upgrade -- LEGACY_CARDINALITY_ESTIMATION = ON is a
      very common database scoped configuration -- and those get row 1.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO D: what the estimate costs ---';
GO

EXEC Demo.usp_RunReport 'D. Cost', 1, 'stale statistics, legacy CE', 'Demo.usp_Report_Legacy';
EXEC Demo.usp_RunReport 'D. Cost', 2, 'stale statistics, new CE',    'Demo.usp_Report';
GO

UPDATE STATISTICS Demo.Orders IX_Orders_OrderDate WITH FULLSCAN;
GO

EXEC Demo.usp_RunReport 'D. Cost', 3, 'fresh statistics, legacy CE', 'Demo.usp_Report_Legacy';
EXEC Demo.usp_RunReport 'D. Cost', 4, 'fresh statistics, new CE',    'Demo.usp_Report';
GO

DECLARE @staleLegacy bigint = (SELECT LogicalReads FROM Demo.ReportRuns WHERE Scenario = 'D. Cost' AND StepNo = 1);
DECLARE @freshLegacy bigint = (SELECT LogicalReads FROM Demo.ReportRuns WHERE Scenario = 'D. Cost' AND StepNo = 3);
DECLARE @staleNewOp  varchar(40) = (SELECT AccessOp FROM Demo.ReportRuns WHERE Scenario = 'D. Cost' AND StepNo = 2);
DECLARE @freshNewOp  varchar(40) = (SELECT AccessOp FROM Demo.ReportRuns WHERE Scenario = 'D. Cost' AND StepNo = 4);
DECLARE @staleLegOp  varchar(40) = (SELECT AccessOp FROM Demo.ReportRuns WHERE Scenario = 'D. Cost' AND StepNo = 1);

DECLARE @ratio decimal(18,3) = @staleLegacy * 1.0 / NULLIF(@freshLegacy, 0);
DECLARE @vRatio varchar(24) =
    CASE WHEN @ratio >= 2 AND @staleLegOp = 'Index Seek' THEN 'LOOKUPS COST MORE' ELSE 'unexpected' END;
DECLARE @vSame varchar(24) =
    CASE WHEN @staleNewOp = @freshNewOp THEN 'SAME PLAN' ELSE 'INTERMITTENT' END;  -- 6,300 sits close to the tipping point: CI once got the seek
DECLARE @opText nvarchar(200) = N'stale: ' + @staleNewOp + N'; fresh: ' + @freshNewOp;

EXEC Demo.usp_Record 'D. Cost', 1, 'legacy CE: stale reads / fresh reads', 'ratio', @ratio,
     NULL, 'well over 1 -- seek + lookups vs one scan', @vRatio;
EXEC Demo.usp_Record 'D. Cost', 2, 'new CE: plan shape stale vs fresh', NULL, NULL,
     @opText, 'the same here -- the 30% guess was enough for this query', @vSame;
GO


/*==============================================================================
  SCENARIO E -- what actually refreshes the statistics

  Every step starts from the same stale state, applies one maintenance
  operation, then compiles the LEGACY-estimator report. The legacy estimator
  is the sharp instrument here: it says 1 row until the histogram includes
  2026, and about 21,000 the moment it does.

     1  REBUILD the clustered index       -- what a fragmentation job most
                                             often rebuilds. It refreshes
                                             PK_Orders' statistics. Not
                                             IX_Orders_OrderDate's.
     2  REORGANIZE IX_Orders_OrderDate    -- never touches statistics
     3  REBUILD    IX_Orders_OrderDate    -- full-scan refresh, as a side
                                             effect
     4  UPDATE STATISTICS, default sample -- the targeted fix
     5  UPDATE STATISTICS WITH FULLSCAN   -- the targeted fix, thorough
     6  no maintenance at all; the query  -- ENABLE_HIST_AMENDMENT_FOR_ASC_KEYS
        hint instead                         lets the optimizer look past the
                                             last step at compile time

  This is the other half of the index-fragmentation topic. "We rebuilt the
  fragmented index and the query got fast" is very often a statistics
  refresh wearing a disguise -- and it only happens when the rebuild hits
  the index whose statistics were stale.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO E: what refreshes the statistics ---';
GO

DECLARE @ops TABLE (Seq int PRIMARY KEY, Label varchar(90), Cmd nvarchar(300), Proc_ sysname, Predicted varchar(24));
INSERT @ops VALUES
 (1, 'ALTER INDEX PK_Orders REBUILD (clustered)',            N'ALTER INDEX PK_Orders ON Demo.Orders REBUILD;',            'Demo.usp_Report_Legacy',  'STILL STALE'),
 (2, 'ALTER INDEX IX_Orders_OrderDate REORGANIZE',           N'ALTER INDEX IX_Orders_OrderDate ON Demo.Orders REORGANIZE;','Demo.usp_Report_Legacy',  'STILL STALE'),
 (3, 'ALTER INDEX IX_Orders_OrderDate REBUILD',              N'ALTER INDEX IX_Orders_OrderDate ON Demo.Orders REBUILD;',   'Demo.usp_Report_Legacy',  'FIXED'),
 (4, 'UPDATE STATISTICS ... IX_Orders_OrderDate',            N'UPDATE STATISTICS Demo.Orders IX_Orders_OrderDate;',        'Demo.usp_Report_Legacy',  'FIXED'),
 (5, 'UPDATE STATISTICS ... IX_Orders_OrderDate WITH FULLSCAN', N'UPDATE STATISTICS Demo.Orders IX_Orders_OrderDate WITH FULLSCAN;', 'Demo.usp_Report_Legacy', 'FIXED'),
 (6, 'no refresh; USE HINT ENABLE_HIST_AMENDMENT_FOR_ASC_KEYS', NULL,                                                     'Demo.usp_Report_Amended', 'FIXED');

DECLARE @seq int = 1, @label varchar(90), @cmd nvarchar(300), @proc sysname, @pred varchar(24),
        @before datetime2(7), @after datetime2(7), @sampled bigint, @t0 datetime2(7), @ms int;

WHILE @seq <= 6
BEGIN
    SELECT @label = Label, @cmd = Cmd, @proc = Proc_, @pred = Predicted FROM @ops WHERE Seq = @seq;

    EXEC Demo.usp_MakeStale @NewRows = 21000;

    SELECT @before = sp.last_updated FROM sys.stats AS s
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
    WHERE s.object_id = OBJECT_ID('Demo.Orders') AND s.name = 'IX_Orders_OrderDate';

    SET @t0 = SYSDATETIME();
    IF @cmd IS NOT NULL EXEC sys.sp_executesql @cmd;
    SET @ms = DATEDIFF(millisecond, @t0, SYSDATETIME());

    SELECT @after = sp.last_updated, @sampled = sp.rows_sampled FROM sys.stats AS s
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
    WHERE s.object_id = OBJECT_ID('Demo.Orders') AND s.name = 'IX_Orders_OrderDate';

    EXEC Demo.usp_RunReport 'E. What refreshes', @seq, @label, @proc;

    DECLARE @est decimal(18,1), @actual bigint, @op varchar(40);
    SELECT @est = EstimateRows, @actual = ActualRows, @op = AccessOp
    FROM   Demo.ReportRuns WHERE Scenario = 'E. What refreshes' AND StepNo = @seq;

    DECLARE @outcome varchar(24) = CASE WHEN @est >= @actual * 0.5 THEN 'FIXED' ELSE 'STILL STALE' END;
    DECLARE @verdict varchar(24) = CASE WHEN @outcome = @pred THEN @outcome ELSE 'unexpected' END;
    DECLARE @detail nvarchar(200) =
          CASE WHEN @after > @before
               THEN N'IX stats refreshed, ' + CAST(@sampled AS nvarchar(20)) + N' rows sampled'
               ELSE N'IX stats untouched' END
        + N'; op ' + CAST(@ms AS nvarchar(20)) + N' ms; plan: ' + @op;
    DECLARE @exp nvarchar(140) = @pred;

    EXEC Demo.usp_Record 'E. What refreshes', @seq, @label, 'legacy CE estimate', @est,
         @detail, @exp, @verdict;

    SET @seq += 1;
END

-- Leave the database as setup left it, so the next run starts the same way.
EXEC Demo.usp_MakeStale @NewRows = 21000;
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. SCENARIO A: what the statistics know ===';
GO
SELECT StepNo, Item, Value = COALESCE(CAST(CAST(NumericValue AS bigint) AS nvarchar(30)), TextValue), Expected, Verdict
FROM   Demo.DemoResults WHERE Scenario = 'A. What the statistics know' ORDER BY StepNo;
GO

PRINT '';
PRINT '=== 2. SCENARIO B: estimates past the histogram ===';
GO
SELECT StepNo, Item, EstimatedRows = CAST(NumericValue AS decimal(18,1)), Detail = TextValue, Expected, Verdict
FROM   Demo.DemoResults WHERE Scenario = 'B. Estimates past the histogram' ORDER BY StepNo;
GO

PRINT '';
PRINT '=== 3. SCENARIO C: why the automatic update never fired ===';
GO
SELECT StepNo, Item, Modifications = CAST(ROUND(NumericValue, 0) AS bigint), Expected, Verdict
FROM   Demo.DemoResults WHERE Scenario = 'C. Auto-update threshold' ORDER BY StepNo;
GO

PRINT '';
PRINT '=== 4. SCENARIO D: what the estimate costs ===';
GO
SELECT StepNo, Label, EstimateRows, ActualRows, AccessOp, LogicalReads, Dop, GrantKB, ElapsedMs
FROM   Demo.ReportRuns WHERE Scenario = 'D. Cost' ORDER BY StepNo;

SELECT StepNo, Item, Value = NumericValue, Detail = TextValue, Expected, Verdict
FROM   Demo.DemoResults WHERE Scenario = 'D. Cost' ORDER BY StepNo;
GO

PRINT '';
PRINT '=== 5. SCENARIO E: what refreshes the statistics ===';
GO
SELECT StepNo, Item, LegacyEstimate = CAST(NumericValue AS decimal(18,1)), Detail = TextValue, Expected, Verdict
FROM   Demo.DemoResults WHERE Scenario = 'E. What refreshes' ORDER BY StepNo;
GO

PRINT '';
PRINT '=== 6. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, StepNo, Item, NumericValue, TextValue, Expected, Verdict
FROM   Demo.DemoResults
WHERE  Verdict IN ('unexpected', 'INCONCLUSIVE', 'sampled', 'INTERMITTENT')
ORDER BY ResultID;
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 6 should be EMPTY. Anything in it is either';
PRINT ' a genuine difference on your build, or a database';
PRINT ' setting the scenario could not work around -- both are';
PRINT ' worth reading before you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
