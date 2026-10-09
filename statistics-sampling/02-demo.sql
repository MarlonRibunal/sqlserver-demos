/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  The same six estimates under four statistics states:

     default sample        UPDATE STATISTICS, no options
     fullscan              WITH FULLSCAN
     auto, not persisted   after an automatic update, following a manual
                           FULLSCAN
     auto, persisted       the same, after FULLSCAN, PERSIST_SAMPLE_PERCENT

  Evidence lands in Demo.Estimates, Demo.StatsStates and Demo.Verdicts.

  Scenarios
    A  the default sample     -> fine for the big values, wrong for the tail
                                 and for values that do not exist
    B  FULLSCAN               -> exact, for every value that has a step
    C  the 200-step limit     -> values that share a step are averaged, even
                                 with FULLSCAN
    D  the automatic update   -> silently goes back to sampling, unless the
                                 sample rate was persisted

  This file deletes the rows it adds and resets the persisted sample rate at
  the start, so it can be re-run without re-running setup.

  Expected runtime: about fifteen seconds.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), compatibility
  level 160.
==============================================================================*/

USE StatsSamplingDemo;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('Demo.usp_Capture') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- Back to setup's state: no extra rows, no persisted sample rate.
DELETE Demo.Orders WHERE OrderID > 5000000;
UPDATE STATISTICS Demo.Orders IX_Orders_CustomerID WITH FULLSCAN, PERSIST_SAMPLE_PERCENT = OFF;
TRUNCATE TABLE Demo.Estimates;
TRUNCATE TABLE Demo.StatsStates;
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
  CAPTURE THE FOUR STATES
==============================================================================*/
PRINT '';
PRINT '--- default sample ---';
GO
UPDATE STATISTICS Demo.Orders IX_Orders_CustomerID;
GO
EXEC Demo.usp_Capture 'default sample';
GO

PRINT '--- fullscan ---';
GO
UPDATE STATISTICS Demo.Orders IX_Orders_CustomerID WITH FULLSCAN;
GO
EXEC Demo.usp_Capture 'fullscan';
GO

/*------------------------------------------------------------------------------
  Scenario D. 80,000 new orders is more than the automatic-update threshold
  for a 5,000,000-row table at compatibility level 130+ (about 70,711; see
  the ascending-key topic), so the next compile that loads these statistics
  updates them automatically -- at the DEFAULT sample rate, whatever the
  last manual update used. Unless that rate was persisted.
------------------------------------------------------------------------------*/
PRINT '--- automatic update after FULLSCAN, not persisted ---';
GO
INSERT Demo.Orders (OrderID, CustomerID, Amount)
SELECT TOP (80000) 5000000 + ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 3000000, 1
FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b;
GO
EXEC Demo.usp_Capture 'auto, not persisted';
GO

PRINT '--- automatic update after FULLSCAN, PERSIST_SAMPLE_PERCENT = ON ---';
GO
DELETE Demo.Orders WHERE OrderID > 5000000;
UPDATE STATISTICS Demo.Orders IX_Orders_CustomerID WITH FULLSCAN, PERSIST_SAMPLE_PERCENT = ON;
GO
INSERT Demo.Orders (OrderID, CustomerID, Amount)
SELECT TOP (80000) 5000000 + ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 3000000, 1
FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b;
GO
EXEC Demo.usp_Capture 'auto, persisted';
GO

-- Leave the table as setup left it.
DELETE Demo.Orders WHERE OrderID > 5000000;
UPDATE STATISTICS Demo.Orders IX_Orders_CustomerID WITH FULLSCAN, PERSIST_SAMPLE_PERCENT = OFF;
GO


/*==============================================================================
  VERDICTS
==============================================================================*/
DECLARE @a TABLE (Marker varchar(4), Label varchar(60), Actual bigint);
INSERT @a VALUES ('S1', 'the whale (customer 1)', 1000000), ('S2', 'a big customer (7)', 50000),
                 ('S3', 'a medium, even id (50500)', 1900), ('S4', 'a medium, odd id (50501)', 100),
                 ('S5', 'a tail customer (600000)', 2), ('S6', 'nobody (2000000)', 0);

DECLARE @pct decimal(6,2) = (SELECT SamplePct FROM Demo.StatsStates WHERE StatsState = 'default sample');

-- A. The default sample.
INSERT Demo.Verdicts (Scenario, Item, Detail, Expected, Verdict)
SELECT  'A. Default sample', a.Label,
        N'estimated ' + CAST(e.EstimateRows AS nvarchar(20)) + N', actual ' + CAST(a.Actual AS nvarchar(20))
            + N' (' + CAST(@pct AS nvarchar(10)) + N'% of rows sampled)',
        CASE WHEN a.Marker IN ('S1', 'S2') THEN 'within 5%' WHEN a.Marker = 'S5' THEN 'several times too high'
             WHEN a.Marker = 'S6' THEN 'well above 1' ELSE 'see scenario C' END,
        CASE WHEN a.Marker IN ('S1', 'S2') AND ABS(e.EstimateRows - a.Actual) <= a.Actual * 0.05 THEN 'CLOSE ENOUGH'
             WHEN a.Marker = 'S5' AND e.EstimateRows >= a.Actual * 3                         THEN 'TAIL OVERESTIMATED'
             WHEN a.Marker = 'S6' AND e.EstimateRows >= 5                                     THEN 'PHANTOM ROWS'
             WHEN a.Marker IN ('S3', 'S4')                                                   THEN 'INFO'
             ELSE 'unexpected' END
FROM    @a AS a JOIN Demo.Estimates AS e ON e.Marker = a.Marker AND e.StatsState = 'default sample';

-- B. FULLSCAN.
INSERT Demo.Verdicts (Scenario, Item, Detail, Expected, Verdict)
SELECT  'B. FULLSCAN', a.Label,
        N'estimated ' + CAST(e.EstimateRows AS nvarchar(20)) + N', actual ' + CAST(a.Actual AS nvarchar(20)),
        CASE WHEN a.Marker IN ('S3', 'S4') THEN 'see scenario C' ELSE 'exact (1 for a value that does not exist)' END,
        CASE WHEN a.Marker IN ('S3', 'S4')                                                     THEN 'INFO'
             WHEN a.Marker = 'S6' AND e.EstimateRows <= 1                                      THEN 'EXACT'
             WHEN a.Marker <> 'S6' AND ABS(e.EstimateRows - a.Actual) <= a.Actual * 0.01        THEN 'EXACT'
             ELSE 'unexpected' END
FROM    @a AS a JOIN Demo.Estimates AS e ON e.Marker = a.Marker AND e.StatsState = 'fullscan';

-- C. The 200-step limit.
DECLARE @even decimal(18,1) = (SELECT EstimateRows FROM Demo.Estimates WHERE StatsState = 'fullscan' AND Marker = 'S3');
DECLARE @odd  decimal(18,1) = (SELECT EstimateRows FROM Demo.Estimates WHERE StatsState = 'fullscan' AND Marker = 'S4');
DECLARE @steps int = (SELECT Steps FROM Demo.StatsStates WHERE StatsState = 'fullscan');
DECLARE @d nvarchar(300) = N'FULLSCAN, ' + CAST(@steps AS nvarchar(10)) + N' steps: customer 50500 (1,900 rows) estimated '
    + CAST(@even AS nvarchar(20)) + N', customer 50501 (100 rows) estimated ' + CAST(@odd AS nvarchar(20));
INSERT Demo.Verdicts VALUES ('C. The 200-step limit', 'neighbours of very different sizes', @d,
    'both get the same averaged estimate',
    CASE WHEN @steps <= 200 AND @even = @odd THEN 'AVERAGED' ELSE 'unexpected' END);

-- D. The automatic update.
DECLARE @np decimal(6,2), @p decimal(6,2), @pp decimal(6,2), @npRows bigint, @pRows bigint;
SELECT @np = SamplePct, @npRows = RowsInTable FROM Demo.StatsStates WHERE StatsState = 'auto, not persisted';
SELECT @p = SamplePct, @pp = PersistedPct, @pRows = RowsInTable FROM Demo.StatsStates WHERE StatsState = 'auto, persisted';
SET @d = N'after FULLSCAN, then 80,000 new rows: the automatic update sampled ' + CAST(@np AS nvarchar(10)) + N'% ('
       + CAST(@npRows AS nvarchar(20)) + N' rows in the statistics)';
INSERT Demo.Verdicts VALUES ('D. Automatic update', 'FULLSCAN, not persisted', @d, 'back to the default sample',
    CASE WHEN @npRows > 5000000 AND @np < 50 THEN 'SAMPLING AGAIN' ELSE 'unexpected' END);
SET @d = N'after FULLSCAN, PERSIST_SAMPLE_PERCENT = ON, then 80,000 new rows: sampled ' + CAST(@p AS nvarchar(10))
       + N'% (persisted ' + CAST(@pp AS nvarchar(10)) + N'%)';
INSERT Demo.Verdicts VALUES ('D. Automatic update', 'FULLSCAN, persisted', @d, 'the automatic update keeps FULLSCAN',
    CASE WHEN @pRows > 5000000 AND @p = 100 THEN 'FULLSCAN KEPT' ELSE 'unexpected' END);
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. ESTIMATES BY STATISTICS STATE ===';
GO
SELECT  Marker,
        Value = CASE Marker WHEN 'S1' THEN 'customer 1 (whale)' WHEN 'S2' THEN 'customer 7 (big)'
                            WHEN 'S3' THEN 'customer 50500 (even)' WHEN 'S4' THEN 'customer 50501 (odd)'
                            WHEN 'S5' THEN 'customer 600000 (tail)' ELSE 'customer 2000000 (nobody)' END,
        Actual = CASE Marker WHEN 'S1' THEN 1000000 WHEN 'S2' THEN 50000 WHEN 'S3' THEN 1900
                             WHEN 'S4' THEN 100 WHEN 'S5' THEN 2 ELSE 0 END,
        DefaultSample     = MAX(CASE WHEN StatsState = 'default sample'      THEN EstimateRows END),
        Fullscan          = MAX(CASE WHEN StatsState = 'fullscan'            THEN EstimateRows END),
        AutoNotPersisted  = MAX(CASE WHEN StatsState = 'auto, not persisted' THEN EstimateRows END),
        AutoPersisted     = MAX(CASE WHEN StatsState = 'auto, persisted'     THEN EstimateRows END)
FROM    Demo.Estimates GROUP BY Marker ORDER BY Marker;
GO

PRINT '';
PRINT '=== 2. THE STATISTICS AT EACH STATE ===';
GO
SELECT StatsState, RowsInTable, RowsSampled, SamplePct, Steps, PersistedPct FROM Demo.StatsStates ORDER BY CapturedAt;
GO

PRINT '';
PRINT '=== 3. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario, Item;
GO

PRINT '';
PRINT '=== 4. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Detail, Verdict FROM Demo.Verdicts WHERE Verdict = 'unexpected';
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 4 should be EMPTY. Anything in it is a';
PRINT ' genuine difference on your build, worth reading before';
PRINT ' you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
