/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  Scenarios A to C build their own small columnstore tables from Demo.Source,
  so this file can be re-run without re-running setup. Evidence lands in
  Demo.RowGroups, Demo.ScanCosts and Demo.Verdicts; the summary at the
  bottom is the payoff.

  Scenarios
    A  the 102,400-row line   -> one row fewer and the load is not compressed
    B  trickle inserts        -> 200 small inserts: 200,000 rows sitting in an
                                 uncompressed delta store
    C  the fix                -> REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON)
    D  rowgroup elimination   -> the same rows, ordered by date or not: how
                                 much a one-day query has to read

  Expected runtime: about half a minute.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers.
==============================================================================*/

USE ColumnstoreDemo;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('Demo.usp_MeasureScan') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

TRUNCATE TABLE Demo.RowGroups;
TRUNCATE TABLE Demo.ScanCosts;
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
  SCENARIO A -- the 102,400-row line

  An INSERT into a clustered columnstore index that brings at least 102,400
  rows goes straight into a COMPRESSED rowgroup. Below that, the rows go into
  a delta store: an ordinary rowstore b-tree, uncompressed, waiting.

  Two empty columnstore tables, one INSERT ... SELECT each: 102,399 rows and
  102,400 rows.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO A: the 102,400-row line ---';
GO

DROP TABLE IF EXISTS Demo.Load102399, Demo.Load102400;
CREATE TABLE Demo.Load102399 (SaleID int, SaleDate date, Amount int, StoreID int, INDEX CCI CLUSTERED COLUMNSTORE);
CREATE TABLE Demo.Load102400 (SaleID int, SaleDate date, Amount int, StoreID int, INDEX CCI CLUSTERED COLUMNSTORE);
GO

INSERT Demo.Load102399 SELECT SaleID, SaleDate, Amount, StoreID FROM Demo.Source WHERE SaleID <= 102399;
INSERT Demo.Load102400 SELECT SaleID, SaleDate, Amount, StoreID FROM Demo.Source WHERE SaleID <= 102400;
GO

EXEC Demo.usp_SnapshotRowGroups 'A. 102,399 rows', 'Demo.Load102399';
EXEC Demo.usp_SnapshotRowGroups 'A. 102,400 rows', 'Demo.Load102400';
GO

DECLARE @s1 varchar(20), @k1 decimal(18,1), @s2 varchar(20), @k2 decimal(18,1);
SELECT @s1 = State, @k1 = SizeKB FROM Demo.RowGroups WHERE Label = 'A. 102,399 rows';
SELECT @s2 = State, @k2 = SizeKB FROM Demo.RowGroups WHERE Label = 'A. 102,400 rows';
DECLARE @d1 nvarchar(200) = @s1 + N', ' + CAST(@k1 AS nvarchar(20)) + N' KB';
DECLARE @d2 nvarchar(200) = @s2 + N', ' + CAST(@k2 AS nvarchar(20)) + N' KB -- '
    + CAST(CAST(@k1 / NULLIF(@k2, 0) AS decimal(6,1)) AS nvarchar(10)) + N'x smaller';

INSERT Demo.Verdicts VALUES
 ('A. The 102,400-row line', '102,399 rows, one INSERT', @d1, 'OPEN delta store, uncompressed',
  CASE WHEN @s1 = 'OPEN' THEN 'DELTA STORE' ELSE 'unexpected' END),
 ('A. The 102,400-row line', '102,400 rows, one INSERT', @d2, 'COMPRESSED directly',
  CASE WHEN @s2 = 'COMPRESSED' THEN 'COMPRESSED' ELSE 'unexpected' END);
GO


/*==============================================================================
  SCENARIO B -- trickle inserts

  The same 200,000 rows, loaded two ways:

     Demo.Trickle   200 INSERTs of 1,000 rows -- a feed, an application, an
                    ETL that commits every thousand rows. Every one of them
                    is under 102,400, so every one lands in the delta store.
     Demo.BulkLoaded      one INSERT of 200,000 rows -- compressed on arrival.

  A delta store stays OPEN until it holds 1,048,576 rows. Only then is it
  CLOSED and handed to the background tuple mover to compress. A table fed
  a few hundred thousand rows a day in small batches can spend its whole life
  as a rowstore wearing a columnstore's name.

  Both tables are scanned (total Amount over every row) to price the
  difference.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO B: trickle inserts ---';
GO

DROP TABLE IF EXISTS Demo.Trickle, Demo.BulkLoaded;
CREATE TABLE Demo.Trickle (SaleID int, SaleDate date, Amount int, StoreID int, INDEX CCI CLUSTERED COLUMNSTORE);
CREATE TABLE Demo.BulkLoaded    (SaleID int, SaleDate date, Amount int, StoreID int, INDEX CCI CLUSTERED COLUMNSTORE);
GO

DECLARE @b int = 0;
WHILE @b < 200
BEGIN
    INSERT Demo.Trickle SELECT SaleID, SaleDate, Amount, StoreID FROM Demo.Source
    WHERE  SaleID > @b * 1000 AND SaleID <= (@b + 1) * 1000;
    SET @b += 1;
END

INSERT Demo.BulkLoaded SELECT SaleID, SaleDate, Amount, StoreID FROM Demo.Source WHERE SaleID <= 200000;
GO

EXEC Demo.usp_SnapshotRowGroups 'B. trickle, 200 x 1,000', 'Demo.Trickle';
EXEC Demo.usp_SnapshotRowGroups 'B. bulk, 1 x 200,000',    'Demo.BulkLoaded';
EXEC Demo.usp_MeasureScan       'B. trickle, 200 x 1,000', 'Demo.Trickle';
EXEC Demo.usp_MeasureScan       'B. bulk, 1 x 200,000',    'Demo.BulkLoaded';
GO

DECLARE @tState varchar(20), @tRows bigint, @tKB decimal(18,1), @bKB decimal(18,1);
SELECT @tState = MAX(State), @tRows = SUM(TotalRows), @tKB = SUM(SizeKB) FROM Demo.RowGroups WHERE Label LIKE 'B. trickle%';
SELECT @bKB = SUM(SizeKB) FROM Demo.RowGroups WHERE Label LIKE 'B. bulk%';
DECLARE @tReads bigint = (SELECT LogicalReads FROM Demo.ScanCosts WHERE Label LIKE 'B. trickle%');
DECLARE @bReads bigint = (SELECT LogicalReads FROM Demo.ScanCosts WHERE Label LIKE 'B. bulk%');
DECLARE @openRows bigint = (SELECT SUM(TotalRows) FROM Demo.RowGroups WHERE Label LIKE 'B. trickle%' AND State = 'OPEN');

DECLARE @d1 nvarchar(200) = CAST(@openRows AS nvarchar(20)) + N' of ' + CAST(@tRows AS nvarchar(20))
    + N' rows in OPEN delta stores; ' + CAST(@tKB AS nvarchar(20)) + N' KB vs ' + CAST(@bKB AS nvarchar(20)) + N' KB bulk-loaded';
DECLARE @d2 nvarchar(200) = N'full scan: ' + CAST(@tReads AS nvarchar(20)) + N' reads vs ' + CAST(@bReads AS nvarchar(20))
    + N' (' + CAST(CAST(@tReads * 1.0 / NULLIF(@bReads, 0) AS decimal(8,1)) AS nvarchar(10)) + N'x)';

INSERT Demo.Verdicts VALUES
 ('B. Trickle inserts', '200 inserts of 1,000 rows', @d1, 'every row still in the delta store',
  CASE WHEN @openRows = @tRows THEN 'NEVER COMPRESSED' ELSE 'unexpected' END),
 ('B. Trickle inserts', 'scanning it', @d2, 'several times the reads of the compressed copy',
  CASE WHEN @tReads >= @bReads * 3 THEN 'ROWSTORE COST' ELSE 'unexpected' END);
GO


/*==============================================================================
  SCENARIO C -- the fix

  ALTER INDEX ... REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON) compresses
  OPEN and CLOSED delta stores now, instead of waiting for them to fill and
  for the tuple mover to find them. The old delta store is left as a
  TOMBSTONE rowgroup until background cleanup deallocates it.

  It is an online operation and cheap next to a REBUILD. Scheduled after a
  trickle-fed load window, it keeps the table a columnstore in fact.

  Note the compressed result is ONE rowgroup of 200,000 rows -- compressed,
  but smaller than the 1,048,576 a rowgroup can hold. Many small compressed
  rowgroups are better than delta stores, and worse than full ones.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO C: REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON) ---';
GO

ALTER INDEX CCI ON Demo.Trickle REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);
GO

EXEC Demo.usp_SnapshotRowGroups 'C. trickle, reorganized', 'Demo.Trickle';
EXEC Demo.usp_MeasureScan       'C. trickle, reorganized', 'Demo.Trickle';
GO

DECLARE @comp bigint = (SELECT SUM(TotalRows) FROM Demo.RowGroups WHERE Label LIKE 'C.%' AND State = 'COMPRESSED');
DECLARE @open bigint = (SELECT ISNULL(SUM(TotalRows), 0) FROM Demo.RowGroups WHERE Label LIKE 'C.%' AND State IN ('OPEN', 'CLOSED'));
DECLARE @tomb int    = (SELECT COUNT(*) FROM Demo.RowGroups WHERE Label LIKE 'C.%' AND State = 'TOMBSTONE');
DECLARE @before bigint = (SELECT LogicalReads FROM Demo.ScanCosts WHERE Label LIKE 'B. trickle%');
DECLARE @after  bigint = (SELECT LogicalReads FROM Demo.ScanCosts WHERE Label LIKE 'C.%');

DECLARE @d1 nvarchar(200) = CAST(@comp AS nvarchar(20)) + N' rows compressed, ' + CAST(@open AS nvarchar(20))
    + N' still in delta stores, ' + CAST(@tomb AS nvarchar(10)) + N' tombstone';
DECLARE @d2 nvarchar(200) = N'scan reads ' + CAST(@before AS nvarchar(20)) + N' -> ' + CAST(@after AS nvarchar(20));

INSERT Demo.Verdicts VALUES
 ('C. The fix', 'REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON)', @d1, 'all 200,000 rows compressed',
  CASE WHEN @comp = 200000 AND @open = 0 THEN 'COMPRESSED' ELSE 'unexpected' END),
 ('C. The fix', 'scanning it again', @d2, 'reads drop to the bulk-loaded level',
  CASE WHEN @after * 3 <= @before THEN 'COLUMNSTORE COST' ELSE 'unexpected' END);
GO


/*==============================================================================
  SCENARIO D -- rowgroup elimination

  Each compressed rowgroup records the minimum and maximum of every column.
  A query for one day can skip every rowgroup whose SaleDate range does not
  include that day -- IF the rows were loaded so that ranges do not overlap.

  Demo.Ordered and Demo.Unordered hold the same 6,000,000 rows in six
  rowgroups each (built in setup). The check reads the min/max metadata to
  count how many rowgroups COULD contain 2021-03-15, then measures what the
  query actually reads.

  For a date column, min_data_id and max_data_id in sys.column_store_segments
  are the day number counted from 0001-01-01, so the target day converts
  with DATEDIFF. The demo checks the conversion found at least one rowgroup
  in each table before it trusts the count.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO D: rowgroup elimination ---';
GO

DECLARE @day date = '20210315';
DECLARE @dayId bigint = DATEDIFF(day, CAST('00010101' AS date), @day);

DECLARE @ordTotal int, @ordCover int, @unTotal int, @unCover int;

SELECT @ordTotal = COUNT(*),
       @ordCover = SUM(CASE WHEN @dayId BETWEEN s.min_data_id AND s.max_data_id THEN 1 ELSE 0 END)
FROM   sys.column_store_segments AS s
JOIN   sys.partitions AS p ON p.hobt_id = s.hobt_id
JOIN   sys.columns    AS c ON c.object_id = p.object_id AND c.column_id = s.column_id
WHERE  p.object_id = OBJECT_ID('Demo.Ordered') AND c.name = 'SaleDate';

SELECT @unTotal = COUNT(*),
       @unCover = SUM(CASE WHEN @dayId BETWEEN s.min_data_id AND s.max_data_id THEN 1 ELSE 0 END)
FROM   sys.column_store_segments AS s
JOIN   sys.partitions AS p ON p.hobt_id = s.hobt_id
JOIN   sys.columns    AS c ON c.object_id = p.object_id AND c.column_id = s.column_id
WHERE  p.object_id = OBJECT_ID('Demo.Unordered') AND c.name = 'SaleDate';

EXEC Demo.usp_MeasureScan 'D. ordered, one day',   'Demo.Ordered',   @day;
EXEC Demo.usp_MeasureScan 'D. unordered, one day', 'Demo.Unordered', @day;

DECLARE @oReads bigint, @oAns bigint, @uReads bigint, @uAns bigint;
SELECT @oReads = LogicalReads, @oAns = Answer FROM Demo.ScanCosts WHERE Label = 'D. ordered, one day';
SELECT @uReads = LogicalReads, @uAns = Answer FROM Demo.ScanCosts WHERE Label = 'D. unordered, one day';

DECLARE @d1 nvarchar(200) = N'ordered: ' + CAST(@ordCover AS nvarchar(10)) + N' of ' + CAST(@ordTotal AS nvarchar(10))
    + N' rowgroups could hold the day; unordered: ' + CAST(@unCover AS nvarchar(10)) + N' of ' + CAST(@unTotal AS nvarchar(10));
DECLARE @d2 nvarchar(200) = N'one-day query: ' + CAST(@oReads AS nvarchar(20)) + N' reads vs ' + CAST(@uReads AS nvarchar(20))
    + N'; same answer: ' + CASE WHEN @oAns = @uAns THEN N'yes' ELSE N'NO' END;

INSERT Demo.Verdicts VALUES
 ('D. Rowgroup elimination', 'rowgroups whose date range covers 2021-03-15', @d1, 'ordered: 1; unordered: all',
  CASE WHEN @ordCover = 1 AND @unCover = @unTotal AND @ordTotal = @unTotal AND @ordTotal > 1 THEN 'RANGES SEPARATE'
       ELSE 'unexpected' END),
 ('D. Rowgroup elimination', 'what the one-day query read', @d2, 'ordered reads a fraction; same answer',
  CASE WHEN @oAns = @uAns AND @oReads * 3 <= @uReads THEN 'ROWGROUPS SKIPPED' ELSE 'unexpected' END);
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. ROWGROUPS ===';
GO
SELECT Label, TableName, RowGroupID, State, TotalRows, SizeKB, TrimReason
FROM   Demo.RowGroups ORDER BY CapturedAt, TableName, RowGroupID;
GO

PRINT '';
PRINT '=== 2. QUERY COSTS ===';
GO
SELECT Label, TableName, LogicalReads, CpuMs, Answer FROM Demo.ScanCosts ORDER BY CapturedAt;
GO

PRINT '';
PRINT '=== 3. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario;
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
