/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  The same query -- total Amount for the first N customers' orders -- run at
  a range of N, against a narrow table and a wide one, three ways each: as
  the optimizer chooses, forced to seek + look up, and forced to scan.
  Evidence lands in Demo.Runs and Demo.Verdicts; the summary is the payoff.

  Scenarios
    A  the sweep             -> where the optimizer stops looking rows up
    B  the flip point        -> found by bisection, compared with where the
                                reads of the two plans actually cross
    C  pages, not percent    -> the wide table, five times the pages, tips
                                about four times later
    D  warm cache            -> CPU says the lookups stay cheaper well past
                                the flip
    E  the covering index    -> no lookups, no tipping point

  Expected runtime: about half a minute.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers.
==============================================================================*/

USE TippingPointDemo;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;   -- XML methods in the harness; sqlcmd defaults it OFF
GO

IF OBJECT_ID('Demo.usp_Measure') IS NULL
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
    Value     decimal(18,3) NULL,
    Detail    nvarchar(200) NULL,
    Expected  nvarchar(140) NULL,
    Verdict   varchar(24)   NULL
);
-- Scenario E creates this index; a run interrupted before E finished could
-- leave it behind, and it would turn every lookup in A into a covered seek.
DROP INDEX IF EXISTS IX_Wide_CustomerID_Covering ON Demo.Wide;
GO


/*==============================================================================
  SCENARIO A -- the sweep

  Twelve row counts, from 100 rows (0.01% of the table) to 50,000 (5%), on
  both tables, run three ways:

     auto  the optimizer's choice
     seek  forced through IX_..._CustomerID: one seek, then one clustered
           index lookup for EVERY matching row
     scan  forced to read the clustered index end to end, once

  The seek's reads grow with the rows; the scan's are fixed at the table's
  page count. The optimizer should switch from one to the other somewhere
  in between.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO A: the sweep ---';
GO

DECLARE @points TABLE (n int);
INSERT @points VALUES (100),(500),(1000),(2000),(3000),(5000),(7500),(10000),(15000),(20000),(30000),(50000);

DECLARE @n int, @t sysname;
DECLARE sweep CURSOR LOCAL FAST_FORWARD FOR
    SELECT p.n, x.t FROM @points AS p CROSS JOIN (VALUES ('Demo.Narrow'), ('Demo.Wide')) AS x(t);
OPEN sweep;
FETCH NEXT FROM sweep INTO @n, @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC Demo.usp_Measure 'A. Sweep', @t, 'auto', @n;
    EXEC Demo.usp_Measure 'A. Sweep', @t, 'seek', @n;
    EXEC Demo.usp_Measure 'A. Sweep', @t, 'scan', @n;
    FETCH NEXT FROM sweep INTO @n, @t;
END
CLOSE sweep;
DEALLOCATE sweep;
GO


/*==============================================================================
  SCENARIO B -- the flip point, and where the reads cross

  For each table, bisect between the last sweep point the optimizer seeked
  and the first it scanned, down to 50 rows, to find where it changes its
  mind.

  Then work out where the two plans' READS are equal: the scan's reads are
  fixed, the seek's grow by a constant per row (one lookup = a walk down the
  clustered index), so the crossover is scan reads / seek reads per row.

  What to look for: the optimizer's flip lands close to the reads crossover
  -- on the tested build 10% past it on the narrow table and 14% short of it
  on the wide one. Its cost model is not literally counting pages, but pages
  are most of what it is weighing.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO B: the flip point ---';
GO

DECLARE @t sysname, @lo int, @hi int, @mid int, @shape varchar(40);
DECLARE tables CURSOR LOCAL FAST_FORWARD FOR SELECT t FROM (VALUES ('Demo.Narrow'), ('Demo.Wide')) AS x(t);
OPEN tables;
FETCH NEXT FROM tables INTO @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @lo = MAX(TargetRows) FROM Demo.Runs
    WHERE  Scenario = 'A. Sweep' AND TableName = @t AND Mode = 'auto' AND PlanShape = 'seek + lookups';
    SELECT @hi = MIN(TargetRows) FROM Demo.Runs
    WHERE  Scenario = 'A. Sweep' AND TableName = @t AND Mode = 'auto' AND PlanShape = 'clustered scan';

    WHILE @hi - @lo > 50
    BEGIN
        SET @mid = (@lo + @hi) / 20 * 10;          -- a whole number of customers
        EXEC Demo.usp_Measure 'B. Bisect', @t, 'auto', @mid;
        SELECT TOP (1) @shape = PlanShape FROM Demo.Runs
        WHERE  Scenario = 'B. Bisect' AND TableName = @t AND TargetRows = @mid ORDER BY RunID DESC;
        IF @shape = 'clustered scan' SET @hi = @mid ELSE SET @lo = @mid;
    END

    -- Reads crossover: scan reads / seek reads per row, taken from the sweep.
    DECLARE @scanReads decimal(18,3) =
        (SELECT AVG(LogicalReads * 1.0) FROM Demo.Runs WHERE Scenario = 'A. Sweep' AND TableName = @t AND Mode = 'scan');
    DECLARE @perRow decimal(18,3) =
        (SELECT LogicalReads * 1.0 / TargetRows FROM Demo.Runs
         WHERE  Scenario = 'A. Sweep' AND TableName = @t AND Mode = 'seek' AND TargetRows = 10000);
    DECLARE @cross decimal(18,3) = @scanReads / @perRow;
    DECLARE @detail nvarchar(200) =
          N'optimizer seeks at ' + CAST(@lo AS nvarchar(10)) + N', scans at ' + CAST(@hi AS nvarchar(10))
        + N'; reads cross at ' + CAST(CAST(@cross AS int) AS nvarchar(10))
        + N' (' + CAST(CAST(@scanReads AS int) AS nvarchar(10)) + N' / ' + CAST(CAST(@perRow AS decimal(6,2)) AS nvarchar(10)) + N' per row)';
    DECLARE @v varchar(24) =
        CASE WHEN ABS(@hi - @cross) <= @cross * 0.2 THEN 'NEAR THE READS' ELSE 'unexpected' END;
    DECLARE @item varchar(90) = @t + ': rows at which the optimizer switches to a scan';

    INSERT Demo.Verdicts VALUES ('B. Flip point', @item, @hi, @detail, 'within 20% of the reads crossover', @v);

    FETCH NEXT FROM tables INTO @t;
END
CLOSE tables;
DEALLOCATE tables;
GO


/*==============================================================================
  SCENARIO C -- pages, not percent

  "The tipping point is about 0.5% of the table" is the rule of thumb. The
  two tables hold the same rows; the wide one has about five times the
  pages. If the tipping point were a percentage of rows, both would flip at
  the same place.

  They do not. The wide table flips about four times later -- not quite the
  five-fold page ratio, because a scan is not priced on pages alone: part of
  its cost is per ROW, and both tables have the same million rows. So the
  tipping point grows with the page count, but less than in proportion.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO C: pages, not percent ---';
GO

DECLARE @flipN decimal(18,3) = (SELECT Value FROM Demo.Verdicts WHERE Item LIKE 'Demo.Narrow:%');
DECLARE @flipW decimal(18,3) = (SELECT Value FROM Demo.Verdicts WHERE Item LIKE 'Demo.Wide:%');
DECLARE @pagesN decimal(18,3) = (SELECT AVG(LogicalReads * 1.0) FROM Demo.Runs WHERE Scenario = 'A. Sweep' AND TableName = 'Demo.Narrow' AND Mode = 'scan');
DECLARE @pagesW decimal(18,3) = (SELECT AVG(LogicalReads * 1.0) FROM Demo.Runs WHERE Scenario = 'A. Sweep' AND TableName = 'Demo.Wide'   AND Mode = 'scan');

DECLARE @flipRatio  decimal(18,3) = @flipW / NULLIF(@flipN, 0);
DECLARE @pageRatio  decimal(18,3) = @pagesW / NULLIF(@pagesN, 0);
DECLARE @detail nvarchar(200) =
      N'narrow flips at ' + CAST(CAST(@flipN / 10000.0 AS decimal(6,3)) AS nvarchar(10)) + N'% of rows, wide at '
    + CAST(CAST(@flipW / 10000.0 AS decimal(6,3)) AS nvarchar(10)) + N'%; page ratio '
    + CAST(CAST(@pageRatio AS decimal(6,2)) AS nvarchar(10));
DECLARE @v varchar(24) =
    CASE WHEN @flipRatio >= 3 AND @flipRatio <= @pageRatio * 1.1 THEN 'GROWS WITH PAGES' ELSE 'unexpected' END;

INSERT Demo.Verdicts VALUES ('C. Pages, not percent', 'wide flip point / narrow flip point', @flipRatio, @detail,
                             'several times later; at most the page ratio', @v);
GO


/*==============================================================================
  SCENARIO D -- warm cache

  The optimizer costs a lookup as a random I/O -- a page it may have to
  fetch from disk. When the table is already in memory, a lookup is a few
  pointer-chasing page touches, and a scan still has to touch every page.

  At each table's flip point, compare the CPU the forced seek + lookups used
  with the CPU the scan used, both warm.

  What to look for: at the point the optimizer switches to the scan, the
  lookups were still the cheaper plan on CPU. The optimizer is pricing a
  cold cache. On a workload that is always warm, its tipping point is
  conservative -- which is the safe direction to be wrong in.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO D: warm cache ---';
GO

DECLARE @t sysname, @flip int, @seekCpu int, @scanCpu int;
DECLARE tables CURSOR LOCAL FAST_FORWARD FOR SELECT t FROM (VALUES ('Demo.Narrow'), ('Demo.Wide')) AS x(t);
OPEN tables;
FETCH NEXT FROM tables INTO @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @flip = (SELECT CAST(Value AS int) FROM Demo.Verdicts WHERE Item LIKE @t + ':%');
    EXEC Demo.usp_Measure 'D. Warm cache', @t, 'seek', @flip;
    EXEC Demo.usp_Measure 'D. Warm cache', @t, 'scan', @flip;

    SELECT @seekCpu = MAX(CASE WHEN Mode = 'seek' THEN CpuMs END),
           @scanCpu = MAX(CASE WHEN Mode = 'scan' THEN CpuMs END)
    FROM   Demo.Runs WHERE Scenario = 'D. Warm cache' AND TableName = @t AND TargetRows = @flip;

    DECLARE @detail nvarchar(200) = N'at ' + CAST(@flip AS nvarchar(10)) + N' rows: seek + lookups '
        + CAST(@seekCpu AS nvarchar(10)) + N' ms CPU, scan ' + CAST(@scanCpu AS nvarchar(10)) + N' ms CPU';
    DECLARE @v varchar(24) = CASE WHEN @seekCpu < @scanCpu THEN 'LOOKUPS STILL CHEAPER' ELSE 'unexpected' END;
    DECLARE @item varchar(90) = @t + ': CPU at the flip point';

    INSERT Demo.Verdicts VALUES ('D. Warm cache', @item, @seekCpu, @detail, 'lookups use less CPU than the scan', @v);

    FETCH NEXT FROM tables INTO @t;
END
CLOSE tables;
DEALLOCATE tables;
GO


/*==============================================================================
  SCENARIO E -- the covering index

  Add Amount to the nonclustered index as an INCLUDE column, and the index
  alone answers the query: no lookups, so nothing to tip. Measured at 50,000
  rows on the wide table -- four times past its flip point.

  The index is created here and dropped at the end, so scenarios A-D always
  run without it.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO E: the covering index ---';
GO

CREATE INDEX IX_Wide_CustomerID_Covering ON Demo.Wide (CustomerID) INCLUDE (Amount);
GO

EXEC Demo.usp_Measure 'E. Covering', 'Demo.Wide', 'covered', 50000;
GO

DECLARE @shape varchar(40), @reads bigint;
SELECT @shape = PlanShape, @reads = LogicalReads FROM Demo.Runs WHERE Scenario = 'E. Covering';
DECLARE @scan bigint =
    (SELECT LogicalReads FROM Demo.Runs WHERE Scenario = 'A. Sweep' AND TableName = 'Demo.Wide' AND Mode = 'auto' AND TargetRows = 50000);
DECLARE @detail nvarchar(200) = @shape + N'; ' + CAST(@reads AS nvarchar(20)) + N' reads vs '
                              + CAST(@scan AS nvarchar(20)) + N' for the scan it replaced';
DECLARE @v varchar(24) = CASE WHEN @shape = 'index seek only' AND @reads * 10 < @scan THEN 'NOTHING TO TIP' ELSE 'unexpected' END;

INSERT Demo.Verdicts VALUES ('E. Covering index', 'Demo.Wide, 50,000 rows, covering index', @reads, @detail,
                             'index seek only; a fraction of the reads', @v);
GO

DROP INDEX IF EXISTS IX_Wide_CustomerID_Covering ON Demo.Wide;
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. SCENARIO A: the sweep ===';
GO
SELECT  TableName,
        Rows        = TargetRows,
        PctOfTable,
        OptimizerPicks = MAX(CASE WHEN Mode = 'auto' THEN PlanShape END),
        SeekReads   = MAX(CASE WHEN Mode = 'seek' THEN LogicalReads END),
        ScanReads   = MAX(CASE WHEN Mode = 'scan' THEN LogicalReads END),
        SeekCpuMs   = MAX(CASE WHEN Mode = 'seek' THEN CpuMs END),
        ScanCpuMs   = MAX(CASE WHEN Mode = 'scan' THEN CpuMs END)
FROM    Demo.Runs
WHERE   Scenario = 'A. Sweep'
GROUP BY TableName, TargetRows, PctOfTable
ORDER BY TableName, TargetRows;
GO

PRINT '';
PRINT '=== 2. SCENARIOS B to E ===';
GO
SELECT Scenario, Item, Value, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario, Item;
GO

PRINT '';
PRINT '=== 3. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Value, Detail, Verdict FROM Demo.Verdicts WHERE Verdict = 'unexpected'
UNION ALL
SELECT Scenario, TableName + ' ' + Mode + ' ' + CAST(TargetRows AS varchar(10)), NULL, PlanShape, 'NO PLAN FOUND'
FROM   Demo.Runs WHERE PlanShape = 'NO PLAN FOUND';
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 3 should be EMPTY. Anything in it is a';
PRINT ' genuine difference on your build, worth reading before';
PRINT ' you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
