/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  Runs a six-query workload against a table with no nonclustered indexes,
  captures what the missing-index DMVs suggest, then measures three designs
  against the same workload:

     none   no nonclustered indexes -- the baseline
     dmv    every suggestion, created exactly as the DMVs describe it
     hand   three indexes designed for the workload as a whole

  Scenarios
    A  what the DMVs suggest   -> five suggestions for six queries
    B  overlap                 -> three suggestions lead with CustomerID; one
                                  index serves all four of those queries
    C  the wide INCLUDE        -> a suggestion that copies the whole table
    D  ORDER BY is invisible   -> the suggestion for a TOP ... ORDER BY query
                                  still has to sort
    E  the bill                -> index count and size, design against design

  Every index the demo creates, it drops again at the end, so the file can be
  re-run without re-running setup.

  Expected runtime: under a minute.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers.
==============================================================================*/

USE MissingIndexDemo;
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

EXEC Demo.usp_DropNonclustered;
TRUNCATE TABLE Demo.Suggestions;
TRUNCATE TABLE Demo.Measures;
DROP TABLE IF EXISTS Demo.Designs, Demo.Verdicts;
CREATE TABLE Demo.Designs (Design varchar(20) NOT NULL, IndexCount int, IndexMB decimal(10,1), TableMB decimal(10,1));
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
  SCENARIO A -- what the DMVs suggest

  Run the workload five times with no nonclustered index in place, measure
  each query, then read sys.dm_db_missing_index_details / _groups /
  _group_stats for this database.

  Capture happens BEFORE any index is created: creating an index on a table
  discards that table's missing-index entries, so measuring first and
  reading the DMVs second would read nothing.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO A: run the workload, read the suggestions ---';
GO

DECLARE @i int = 0;
WHILE @i < 5 BEGIN EXEC Demo.usp_RunWorkload; SET @i += 1; END
GO

INSERT Demo.Suggestions (EqualityCols, InequalityCols, IncludedCols, UserSeeks, AvgUserImpact, CreateStmt)
SELECT  d.equality_columns, d.inequality_columns, d.included_columns, s.user_seeks, s.avg_user_impact,
        N'CREATE INDEX IX_DMV_' + CAST(ROW_NUMBER() OVER (ORDER BY d.index_handle) AS nvarchar(10))
      + N' ON Demo.Orders ('
      + ISNULL(d.equality_columns, N'')
      + CASE WHEN d.equality_columns IS NOT NULL AND d.inequality_columns IS NOT NULL THEN N', ' ELSE N'' END
      + ISNULL(d.inequality_columns, N'') + N')'
      + ISNULL(N' INCLUDE (' + d.included_columns + N')', N'') + N';'
FROM    sys.dm_db_missing_index_details     AS d
JOIN    sys.dm_db_missing_index_groups      AS g ON g.index_handle = d.index_handle
JOIN    sys.dm_db_missing_index_group_stats AS s ON s.group_handle = g.index_group_handle
WHERE   d.database_id = DB_ID()
  AND   d.object_id   = OBJECT_ID('Demo.Orders');
GO

DECLARE @q varchar(4);
DECLARE qs CURSOR LOCAL FAST_FORWARD FOR SELECT q FROM (VALUES ('Q1'),('Q2'),('Q3'),('Q4'),('Q5'),('Q6')) AS x(q);
OPEN qs; FETCH NEXT FROM qs INTO @q;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC Demo.usp_Measure 'none', @q; FETCH NEXT FROM qs INTO @q; END
CLOSE qs; DEALLOCATE qs;

INSERT Demo.Designs SELECT 'none', 0, 0,
       (SELECT SUM(used_page_count) * 8 / 1024.0 FROM sys.dm_db_partition_stats
        WHERE object_id = OBJECT_ID('Demo.Orders') AND index_id = 1);
GO

DECLARE @n int = (SELECT COUNT(*) FROM Demo.Suggestions);
INSERT Demo.Verdicts VALUES ('A. Suggestions', 'missing-index suggestions for six queries',
    CAST(@n AS nvarchar(10)) + N' suggestions', 'fewer than six: some queries share one',
    CASE WHEN @n BETWEEN 3 AND 6 THEN 'CAPTURED' ELSE 'unexpected' END);
GO


/*==============================================================================
  THE TWO DESIGNS

  dmv   every suggestion, verbatim: equality columns, then inequality columns,
        then INCLUDE -- the CREATE INDEX statements the DMVs imply, and the
        ones many "missing index" scripts generate.

  hand  three indexes, designed for the workload as a whole:
          (CustomerID, Status, OrderDate) INCLUDE (Amount)   Q1, Q2, Q3, Q4
          (Status, OrderDate) INCLUDE (Amount)               Q6 -- key order
                                                             matches its ORDER BY
          (OrderDate)                                        Q5 -- narrow, and
                                                             accepts lookups
==============================================================================*/
PRINT '';
PRINT '--- creating the DMV design ---';
GO

DECLARE @sql nvarchar(max) = N'';
SELECT @sql += CreateStmt FROM Demo.Suggestions ORDER BY SuggestionID;
EXEC sys.sp_executesql @sql;
GO

DECLARE @q varchar(4);
DECLARE qs CURSOR LOCAL FAST_FORWARD FOR SELECT q FROM (VALUES ('Q1'),('Q2'),('Q3'),('Q4'),('Q5'),('Q6')) AS x(q);
OPEN qs; FETCH NEXT FROM qs INTO @q;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC Demo.usp_Measure 'dmv', @q; FETCH NEXT FROM qs INTO @q; END
CLOSE qs; DEALLOCATE qs;

INSERT Demo.Designs
SELECT 'dmv', COUNT(DISTINCT index_id), SUM(used_page_count) * 8 / 1024.0,
       (SELECT SUM(used_page_count) * 8 / 1024.0 FROM sys.dm_db_partition_stats
        WHERE object_id = OBJECT_ID('Demo.Orders') AND index_id = 1)
FROM   sys.dm_db_partition_stats
WHERE  object_id = OBJECT_ID('Demo.Orders') AND index_id > 1;

-- Scenario C needs the size of the one suggestion that INCLUDEs Notes.
DECLARE @wideMB decimal(10,1) =
    (SELECT SUM(ps.used_page_count) * 8 / 1024.0
     FROM   sys.dm_db_partition_stats AS ps
     JOIN   sys.indexes AS i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
     JOIN   Demo.Suggestions AS s ON i.name = 'IX_DMV_' + CAST(s.SuggestionID AS varchar(10))
     WHERE  ps.object_id = OBJECT_ID('Demo.Orders') AND s.IncludedCols LIKE '%Notes%');
INSERT Demo.Verdicts (Scenario, Item, Detail) VALUES ('C. size', 'wide', CAST(@wideMB AS nvarchar(20)));
GO

EXEC Demo.usp_DropNonclustered;
GO

PRINT '--- creating the hand design ---';
GO

CREATE INDEX IX_Hand_Customer   ON Demo.Orders (CustomerID, Status, OrderDate) INCLUDE (Amount);
CREATE INDEX IX_Hand_StatusDate ON Demo.Orders (Status, OrderDate) INCLUDE (Amount);
CREATE INDEX IX_Hand_Date       ON Demo.Orders (OrderDate);
GO

DECLARE @q varchar(4);
DECLARE qs CURSOR LOCAL FAST_FORWARD FOR SELECT q FROM (VALUES ('Q1'),('Q2'),('Q3'),('Q4'),('Q5'),('Q6')) AS x(q);
OPEN qs; FETCH NEXT FROM qs INTO @q;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC Demo.usp_Measure 'hand', @q; FETCH NEXT FROM qs INTO @q; END
CLOSE qs; DEALLOCATE qs;

INSERT Demo.Designs
SELECT 'hand', COUNT(DISTINCT index_id), SUM(used_page_count) * 8 / 1024.0,
       (SELECT SUM(used_page_count) * 8 / 1024.0 FROM sys.dm_db_partition_stats
        WHERE object_id = OBJECT_ID('Demo.Orders') AND index_id = 1)
FROM   sys.dm_db_partition_stats
WHERE  object_id = OBJECT_ID('Demo.Orders') AND index_id > 1;
GO

EXEC Demo.usp_DropNonclustered;
GO

/*------------------------------------------------------------------------------
  Q6's own suggestion, ALONE. With all five suggestions in place, Q6 can pick
  a different suggestion's index (on the tested build it used Q5's wide
  OrderDate index, read backwards), which hides what its own suggestion does.
  Scenario D needs that suggestion measured on its own.
------------------------------------------------------------------------------*/
DECLARE @sql nvarchar(max) = (SELECT TOP (1) CreateStmt FROM Demo.Suggestions WHERE EqualityCols = '[Status]');
IF @sql IS NOT NULL
BEGIN
    EXEC sys.sp_executesql @sql;
    EXEC Demo.usp_Measure 'dmv-alone', 'Q6';
END
GO

EXEC Demo.usp_DropNonclustered;
GO


/*==============================================================================
  SCENARIO B -- overlap

  The DMVs record a suggestion per distinct shape of missing index, and know
  nothing about the others. Four queries about one customer produce several
  suggestions that all start with CustomerID. One index keyed (CustomerID,
  Status, OrderDate) with Amount included serves all four.

  What to look for: on Q1-Q4 the hand design reads no more than the DMV
  design (within 20%), with one index where the DMVs asked for several.
==============================================================================*/
DECLARE @custSuggestions int = (SELECT COUNT(*) FROM Demo.Suggestions WHERE EqualityCols LIKE '[[]CustomerID]%');
DECLARE @dmvReads bigint  = (SELECT SUM(LogicalReads) FROM Demo.Measures WHERE Design = 'dmv'  AND QueryName IN ('Q1','Q2','Q3','Q4'));
DECLARE @handReads bigint = (SELECT SUM(LogicalReads) FROM Demo.Measures WHERE Design = 'hand' AND QueryName IN ('Q1','Q2','Q3','Q4'));
DECLARE @noneReads bigint = (SELECT SUM(LogicalReads) FROM Demo.Measures WHERE Design = 'none' AND QueryName IN ('Q1','Q2','Q3','Q4'));
DECLARE @d nvarchar(300) = CAST(@custSuggestions AS nvarchar(10)) + N' suggestions lead with CustomerID; Q1-Q4 reads: none '
    + CAST(@noneReads AS nvarchar(20)) + N', dmv ' + CAST(@dmvReads AS nvarchar(20)) + N', hand (1 index) ' + CAST(@handReads AS nvarchar(20));

INSERT Demo.Verdicts VALUES ('B. Overlap', 'four customer queries', @d, 'several overlapping suggestions; one index does as well',
    CASE WHEN @custSuggestions >= 2 AND @handReads <= @dmvReads * 1.2 THEN 'ONE INDEX IS ENOUGH' ELSE 'unexpected' END);
GO


/*==============================================================================
  SCENARIO C -- the wide INCLUDE

  Q5 reads every column of one day's orders. The DMVs suggest an index on
  OrderDate that INCLUDEs every other column -- including the 200-byte Notes
  -- which is a second copy of the table, sorted by date, to be maintained on
  every insert and update.

  The hand design indexes OrderDate alone and accepts a lookup per row: about
  457 rows a day. More reads for this one query; a fraction of the storage.
==============================================================================*/
DECLARE @wideMB decimal(10,1) = (SELECT CAST(Detail AS decimal(10,1)) FROM Demo.Verdicts WHERE Scenario = 'C. size');
DELETE Demo.Verdicts WHERE Scenario = 'C. size';
DECLARE @tableMB decimal(10,1) = (SELECT TableMB FROM Demo.Designs WHERE Design = 'none');
DECLARE @dmvQ5 bigint  = (SELECT LogicalReads FROM Demo.Measures WHERE Design = 'dmv'  AND QueryName = 'Q5');
DECLARE @handQ5 bigint = (SELECT LogicalReads FROM Demo.Measures WHERE Design = 'hand' AND QueryName = 'Q5');
DECLARE @inc nvarchar(400) = (SELECT TOP (1) IncludedCols FROM Demo.Suggestions WHERE IncludedCols LIKE '%Notes%');
DECLARE @d nvarchar(300) = N'suggested INCLUDE (' + ISNULL(@inc, N'none') + N'): ' + CAST(@wideMB AS nvarchar(20))
    + N' MB vs table ' + CAST(@tableMB AS nvarchar(20)) + N' MB; Q5 reads dmv ' + CAST(@dmvQ5 AS nvarchar(20))
    + N', hand ' + CAST(@handQ5 AS nvarchar(20));

INSERT Demo.Verdicts VALUES ('C. The wide INCLUDE', 'the suggestion for Q5', @d, 'an index nearly the size of the table',
    CASE WHEN @wideMB >= @tableMB * 0.8 THEN 'A COPY OF THE TABLE' ELSE 'unexpected' END);
GO


/*==============================================================================
  SCENARIO D -- ORDER BY is invisible

  Q6 wants the 50 most recent Open orders. The missing-index machinery records
  the WHERE clause -- Status -- and the columns read, but not the ORDER BY.
  Its suggestion keys on Status and merely INCLUDEs OrderDate, so every Open
  row (20,000 of them) is read and sorted to find the top 50.

  Keyed (Status, OrderDate), the index returns Open rows already in date
  order: read the last 50, stop. No sort.

  The suggestion is measured ALONE here ('dmv-alone'). In the full DMV design
  Q6 may borrow another suggestion's index -- result set 2 shows which.
==============================================================================*/
DECLARE @dSort bit, @dReads bigint, @hSort bit, @hReads bigint;
SELECT @dSort = HasSort, @dReads = LogicalReads FROM Demo.Measures WHERE Design = 'dmv-alone' AND QueryName = 'Q6';
SELECT @hSort = HasSort, @hReads = LogicalReads FROM Demo.Measures WHERE Design = 'hand' AND QueryName = 'Q6';
DECLARE @sugg nvarchar(400) =
    (SELECT TOP (1) CreateStmt FROM Demo.Suggestions WHERE EqualityCols = '[Status]');
DECLARE @d nvarchar(300) = ISNULL(@sugg, N'(no Status suggestion)') + N' -> sort: ' + CASE @dSort WHEN 1 THEN N'yes' ELSE N'no' END
    + N', ' + CAST(@dReads AS nvarchar(20)) + N' reads; (Status, OrderDate) -> sort: ' + CASE @hSort WHEN 1 THEN N'yes' ELSE N'no' END
    + N', ' + CAST(@hReads AS nvarchar(20)) + N' reads';

INSERT Demo.Verdicts VALUES ('D. ORDER BY is invisible', 'Q6: TOP (50) ... ORDER BY OrderDate DESC', @d,
    'suggestion still sorts; keyed index does not',
    CASE WHEN @dSort = 1 AND @hSort = 0 AND @hReads * 5 < @dReads THEN 'SORT AVOIDED BY HAND' ELSE 'unexpected' END);
GO


/*==============================================================================
  SCENARIO E -- the bill
==============================================================================*/
DECLARE @dc int, @dm decimal(10,1), @hc int, @hm decimal(10,1);
SELECT @dc = IndexCount, @dm = IndexMB FROM Demo.Designs WHERE Design = 'dmv';
SELECT @hc = IndexCount, @hm = IndexMB FROM Demo.Designs WHERE Design = 'hand';
DECLARE @d nvarchar(300) = N'dmv: ' + CAST(@dc AS nvarchar(10)) + N' indexes, ' + CAST(@dm AS nvarchar(20))
    + N' MB; hand: ' + CAST(@hc AS nvarchar(10)) + N' indexes, ' + CAST(@hm AS nvarchar(20)) + N' MB';

INSERT Demo.Verdicts VALUES ('E. The bill', 'nonclustered indexes to store and maintain', @d, 'hand design: fewer and smaller',
    CASE WHEN @hc < @dc AND @hm < @dm THEN 'FEWER, SMALLER' ELSE 'unexpected' END);
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. WHAT THE DMVs SUGGESTED ===';
GO
SELECT SuggestionID, EqualityCols, InequalityCols, IncludedCols, UserSeeks, AvgUserImpact, CreateStmt
FROM   Demo.Suggestions ORDER BY SuggestionID;
GO

PRINT '';
PRINT '=== 2. EACH QUERY UNDER EACH DESIGN ===';
GO
SELECT  QueryName,
        NoIndexReads = MAX(CASE WHEN Design = 'none' THEN LogicalReads END),
        DmvReads     = MAX(CASE WHEN Design = 'dmv'  THEN LogicalReads END),
        DmvIndex     = MAX(CASE WHEN Design = 'dmv'  THEN AccessIndex END),
        DmvSort      = MAX(CASE WHEN Design = 'dmv'  THEN CAST(HasSort AS int) END),
        HandReads    = MAX(CASE WHEN Design = 'hand' THEN LogicalReads END),
        HandIndex    = MAX(CASE WHEN Design = 'hand' THEN AccessIndex END),
        HandSort     = MAX(CASE WHEN Design = 'hand' THEN CAST(HasSort AS int) END),
        HandLookup   = MAX(CASE WHEN Design = 'hand' THEN CAST(HasLookup AS int) END),
        OwnSuggestionAloneReads = MAX(CASE WHEN Design = 'dmv-alone' THEN LogicalReads END),
        OwnSuggestionAloneSort  = MAX(CASE WHEN Design = 'dmv-alone' THEN CAST(HasSort AS int) END)
FROM    Demo.Measures
GROUP BY QueryName
ORDER BY QueryName;
GO

PRINT '';
PRINT '=== 3. THE DESIGNS ===';
GO
SELECT Design, IndexCount, IndexMB, TableMB FROM Demo.Designs;
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
PRINT ' Result set 5 should be EMPTY. Anything in it is either';
PRINT ' a genuine difference on your build, or suggestions';
PRINT ' that differ from the tested build -- result set 1';
PRINT ' shows exactly what yours were.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
