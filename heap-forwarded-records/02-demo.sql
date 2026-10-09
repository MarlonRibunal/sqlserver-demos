/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  Every scenario builds its own tables through Demo.usp_Build, so this file
  can be re-run without re-running setup. Evidence lands in Demo.Snapshots
  and Demo.DemoResults; the summary at the bottom is the payoff.

  Scenarios
    A  rows that grow       -> a heap forwards them; a full scan then reads
                               one extra page per forwarded row
    B  lookups              -> fetching a row through a nonclustered index
                               costs one extra read when it was forwarded
    C  deletes              -> a heap keeps its emptied pages unless the
                               delete held a TABLE lock -- which batching,
                               the usual cure for escalation, prevents
    D  the fix              -> ALTER TABLE ... REBUILD, and what it costs

  Expected runtime: under a minute.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers.
==============================================================================*/

USE HeapDemo;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('Demo.usp_Snapshot') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

TRUNCATE TABLE Demo.Snapshots;
TRUNCATE TABLE Demo.DemoResults;
GO


/*==============================================================================
  SCENARIO A -- rows that grow

  The same 100,000 short rows in a heap and in a clustered table, then the
  same UPDATE on both: Notes grows from 10 characters to 400 on every third
  row. The rows no longer fit where they are.

     clustered  the page SPLITS. More pages, each about half full, and every
                row still lives where the index says.
     heap       the row MOVES to any page with room, and leaves a forwarding
                pointer behind in its old slot.

  What to look for:
    - the heap ends up with FEWER pages than the clustered table
    - but a full scan of the heap reads about one extra page for every
      forwarded row: it follows each pointer to the row's new home, then
      comes back. Pages + forwarded records = reads.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO A: rows that grow ---';
GO

EXEC Demo.usp_Build 'Demo.Heap',      'HEAP';
EXEC Demo.usp_Build 'Demo.Clustered', 'CLUSTERED';

EXEC Demo.usp_Snapshot 'A. heap, before',      'Demo.Heap';
EXEC Demo.usp_Snapshot 'A. clustered, before', 'Demo.Clustered';

EXEC Demo.usp_Widen 'Demo.Heap';
EXEC Demo.usp_Widen 'Demo.Clustered';

EXEC Demo.usp_Snapshot 'A. heap, after',      'Demo.Heap';
EXEC Demo.usp_Snapshot 'A. clustered, after', 'Demo.Clustered';
GO

DECLARE @hPages bigint, @hFwd bigint, @hScan bigint, @cPages bigint, @cScan bigint;
SELECT @hPages = DataPages, @hFwd = Forwarded, @hScan = ScanReads FROM Demo.Snapshots WHERE Label = 'A. heap, after';
SELECT @cPages = DataPages, @cScan = ScanReads FROM Demo.Snapshots WHERE Label = 'A. clustered, after';

DECLARE @predicted bigint = @hPages + @hFwd;
DECLARE @detail nvarchar(200) =
      CAST(@hPages AS nvarchar(20)) + N' pages + ' + CAST(@hFwd AS nvarchar(20))
    + N' forwarded = ' + CAST(@predicted AS nvarchar(20)) + N'; measured ' + CAST(@hScan AS nvarchar(20));
DECLARE @v1 varchar(24) =
    CASE WHEN @hFwd > 0 AND ABS(@hScan - @predicted) <= @predicted * 0.05 THEN 'ONE READ PER POINTER' ELSE 'unexpected' END;
DECLARE @ratio decimal(18,3) = @hScan * 1.0 / NULLIF(@cScan, 0);
DECLARE @v2 varchar(24) =
    CASE WHEN @hPages < @cPages AND @ratio > 2 THEN 'FEWER PAGES, MORE READS' ELSE 'unexpected' END;

EXEC Demo.usp_Record 'A. Rows that grow', 1, 'heap scan reads vs pages + forwarded records', 'reads',
     @hScan, @detail, 'pages + forwarded, within 5%', @v1;
EXEC Demo.usp_Record 'A. Rows that grow', 2, 'heap scan reads / clustered scan reads', 'ratio',
     @ratio, NULL, 'heap has fewer pages, yet reads more', @v2;
GO


/*==============================================================================
  SCENARIO B -- lookups through a nonclustered index

  2,000 rows (Status = 'X') are fetched through IX_..._Status, then each row
  is looked up in the base table. A heap's nonclustered index points to a
  physical row id (RID); a forwarded row is found at its old RID, and the
  pointer there costs one more read.

  Of the 2,000 rows, every third one was widened -- 666 rows, the ones with
  ID divisible by 150. The heap's lookup cost should rise by about one read
  per forwarded row it meets.

  The clustered table is shown for scale. Its lookups go through the
  clustered key, which costs more per row than a RID lookup -- before AND
  after. A heap is not slower at lookups in general; forwarding is what
  erodes its one structural advantage.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO B: lookups ---';
GO

DECLARE @before bigint = (SELECT LookupReads FROM Demo.Snapshots WHERE Label = 'A. heap, before');
DECLARE @after  bigint = (SELECT LookupReads FROM Demo.Snapshots WHERE Label = 'A. heap, after');
DECLARE @moved  bigint = (SELECT COUNT_BIG(*) FROM Demo.Heap WHERE Status = 'X' AND ID % 3 = 0);
DECLARE @extra  bigint = @after - @before;
DECLARE @detail nvarchar(200) =
      N'lookup reads ' + CAST(@before AS nvarchar(20)) + N' -> ' + CAST(@after AS nvarchar(20))
    + N'; ' + CAST(@moved AS nvarchar(20)) + N' of the 2,000 rows were forwarded';
DECLARE @v varchar(24) =
    CASE WHEN ABS(@extra - @moved) <= @moved * 0.1 THEN 'ONE EXTRA READ PER ROW' ELSE 'unexpected' END;

EXEC Demo.usp_Record 'B. Lookups', 1, 'extra heap lookup reads after forwarding', 'reads',
     @extra, @detail, 'about one per forwarded row', @v;

DECLARE @cBefore bigint = (SELECT LookupReads FROM Demo.Snapshots WHERE Label = 'A. clustered, before');
DECLARE @cText nvarchar(200) =
      N'heap ' + CAST(@before AS nvarchar(20)) + N' vs clustered ' + CAST(@cBefore AS nvarchar(20)) + N', before any update';
DECLARE @v2 varchar(24) = CASE WHEN @before < @cBefore THEN 'RID LOOKUPS CHEAPER' ELSE 'unexpected' END;

EXEC Demo.usp_Record 'B. Lookups', 2, 'heap RID lookups vs clustered key lookups', 'reads',
     @before, @cText, 'RID lookup is one read; key lookup is a seek', @v2;
GO


/*==============================================================================
  SCENARIO C -- deletes, and the pages a heap keeps

  Delete 90,000 of the 100,000 rows -- the first 90,000, so whole pages
  empty out -- four ways:

     C1 heap,      20 statements of 4,500 rows   no statement escalates
     C2 heap,      one statement                 escalates to a table lock
     C3 heap,      one statement WITH (TABLOCK)  table lock from the start
     C4 clustered, 20 statements of 4,500 rows   the control

  A heap only releases a page emptied by DELETE when the delete holds a lock
  on the whole table. Otherwise the empty page stays allocated, and every
  scan keeps reading it.

  Batching, the usual cure for lock escalation (see the lock-escalation
  topic), is exactly what keeps the delete from holding that table lock. So
  the purge that is kindest to concurrency is the one that leaves the heap
  full of empty pages. A clustered index has no such problem: its emptied
  pages are released by the background ghost cleanup.

  Ghost cleanup runs a few seconds after a delete, so each snapshot waits
  for this table's ghost records to reach zero (bounded at 60 seconds).
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO C: deletes (waits for ghost cleanup) ---';
GO

DECLARE @lo int;

EXEC Demo.usp_Build 'Demo.HeapBatched', 'HEAP';
SET @lo = 0;
WHILE @lo < 90000
BEGIN
    DELETE Demo.HeapBatched WHERE ID > @lo AND ID <= @lo + 4500;
    SET @lo += 4500;
END

EXEC Demo.usp_Build 'Demo.HeapOneDelete', 'HEAP';
DELETE Demo.HeapOneDelete WHERE ID <= 90000;
-- Read the escalation counter straight away, before anything else touches the table.
INSERT Demo.DemoResults (Scenario, StepNo, Item, Measure, NumericValue)
SELECT 'C. escalations', 2, 'one-statement heap delete', 'lock escalations',
       SUM(index_lock_promotion_count)
FROM   sys.dm_db_index_operational_stats(DB_ID(), OBJECT_ID('Demo.HeapOneDelete'), NULL, NULL);

EXEC Demo.usp_Build 'Demo.HeapTablock', 'HEAP';
DELETE Demo.HeapTablock WITH (TABLOCK) WHERE ID <= 90000;

EXEC Demo.usp_Build 'Demo.ClusteredBatched', 'CLUSTERED';
SET @lo = 0;
WHILE @lo < 90000
BEGIN
    DELETE Demo.ClusteredBatched WHERE ID > @lo AND ID <= @lo + 4500;
    SET @lo += 4500;
END
GO

EXEC Demo.usp_WaitForGhosts 'Demo.HeapBatched';
EXEC Demo.usp_WaitForGhosts 'Demo.HeapOneDelete';
EXEC Demo.usp_WaitForGhosts 'Demo.HeapTablock';
EXEC Demo.usp_WaitForGhosts 'Demo.ClusteredBatched';

EXEC Demo.usp_Snapshot 'C1. heap, batched delete',             'Demo.HeapBatched';
EXEC Demo.usp_Snapshot 'C2. heap, one delete (escalates)',     'Demo.HeapOneDelete';
EXEC Demo.usp_Snapshot 'C3. heap, delete WITH (TABLOCK)',      'Demo.HeapTablock';
EXEC Demo.usp_Snapshot 'C4. clustered, batched delete',        'Demo.ClusteredBatched';
GO

DECLARE @full bigint = (SELECT DataPages FROM Demo.Snapshots WHERE Label = 'A. heap, before');
DECLARE @c1 bigint = (SELECT DataPages FROM Demo.Snapshots WHERE Label LIKE 'C1.%');
DECLARE @c2 bigint = (SELECT DataPages FROM Demo.Snapshots WHERE Label LIKE 'C2.%');
DECLARE @c3 bigint = (SELECT DataPages FROM Demo.Snapshots WHERE Label LIKE 'C3.%');
DECLARE @c4 bigint = (SELECT DataPages FROM Demo.Snapshots WHERE Label LIKE 'C4.%');
DECLARE @esc bigint =
    (SELECT NumericValue FROM Demo.DemoResults WHERE Scenario = 'C. escalations' AND StepNo = 2);
DECLARE @escBatched bigint =
    (SELECT index_lock_promotion_count FROM sys.dm_db_index_operational_stats(DB_ID(), OBJECT_ID('Demo.HeapBatched'), 0, NULL));

DECLARE @t1 nvarchar(200) = CAST(@c1 AS nvarchar(20)) + N' of ' + CAST(@full AS nvarchar(20))
                          + N' pages still allocated; escalations ' + CAST(ISNULL(@escBatched, 0) AS nvarchar(10));
DECLARE @t2 nvarchar(200) = CAST(@c2 AS nvarchar(20)) + N' pages; escalations ' + CAST(ISNULL(@esc, 0) AS nvarchar(10));
DECLARE @t3 nvarchar(200) = CAST(@c3 AS nvarchar(20)) + N' pages';
DECLARE @t4 nvarchar(200) = CAST(@c4 AS nvarchar(20)) + N' pages';

DECLARE @v1 varchar(24) = CASE WHEN @c1 >= @full * 0.9                          THEN 'EMPTY PAGES KEPT'  ELSE 'unexpected' END;
DECLARE @v2 varchar(24) = CASE WHEN @c2 <= @full * 0.25                          THEN 'PAGES RELEASED'    ELSE 'unexpected' END;
DECLARE @v3 varchar(24) = CASE WHEN @c3 <= @full * 0.15                         THEN 'PAGES RELEASED'    ELSE 'unexpected' END;
DECLARE @v4 varchar(24) = CASE WHEN @c4 <= @full * 0.15                         THEN 'PAGES RELEASED'    ELSE 'unexpected' END;

EXEC Demo.usp_Record 'C. Deletes', 1, 'heap, 20 x 4,500-row deletes', 'pages', @c1, @t1, 'nearly every page kept', @v1;
EXEC Demo.usp_Record 'C. Deletes', 2, 'heap, one 90,000-row delete', 'pages', @c2, @t2, 'most pages released', @v2;
EXEC Demo.usp_Record 'C. Deletes', 3, 'heap, delete WITH (TABLOCK)', 'pages', @c3, @t3, 'pages released', @v3;
EXEC Demo.usp_Record 'C. Deletes', 4, 'clustered, 20 x 4,500-row deletes', 'pages', @c4, @t4, 'pages released by ghost cleanup', @v4;
GO


/*==============================================================================
  SCENARIO D -- the fix

  ALTER TABLE ... REBUILD (SQL Server 2008 and later) rewrites a heap:
  forwarded rows are put back in line and empty pages are released.

  It is not free. Every nonclustered index on a heap points at physical row
  ids, and a rebuild changes all of them -- so it rebuilds every nonclustered
  index too. On a heap with many indexes that is most of the cost. If the
  table is going to keep taking updates that grow its rows, a clustered index
  fixes the problem for good; a rebuild only resets it.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO D: ALTER TABLE ... REBUILD ---';
GO

DECLARE @t0 datetime2(7) = SYSDATETIME();
ALTER TABLE Demo.Heap REBUILD;
DECLARE @ms1 int = DATEDIFF(millisecond, @t0, SYSDATETIME());

SET @t0 = SYSDATETIME();
ALTER TABLE Demo.HeapBatched REBUILD;
DECLARE @ms2 int = DATEDIFF(millisecond, @t0, SYSDATETIME());

EXEC Demo.usp_Snapshot 'D. heap from A, rebuilt',  'Demo.Heap';
EXEC Demo.usp_Snapshot 'D. heap from C1, rebuilt', 'Demo.HeapBatched';

DECLARE @fwd bigint, @scan bigint, @pages bigint, @fwdBefore bigint, @scanBefore bigint;
SELECT @fwd = Forwarded, @scan = ScanReads, @pages = DataPages FROM Demo.Snapshots WHERE Label = 'D. heap from A, rebuilt';
SELECT @fwdBefore = Forwarded, @scanBefore = ScanReads FROM Demo.Snapshots WHERE Label = 'A. heap, after';

DECLARE @t1 nvarchar(200) = N'forwarded ' + CAST(@fwdBefore AS nvarchar(20)) + N' -> ' + CAST(@fwd AS nvarchar(20))
                          + N'; scan reads ' + CAST(@scanBefore AS nvarchar(20)) + N' -> ' + CAST(@scan AS nvarchar(20))
                          + N'; ' + CAST(@ms1 AS nvarchar(20)) + N' ms';
DECLARE @v1 varchar(24) = CASE WHEN @fwd = 0 AND @scan <= @pages * 1.05 THEN 'FORWARDING GONE' ELSE 'unexpected' END;

DECLARE @p2 bigint = (SELECT DataPages FROM Demo.Snapshots WHERE Label = 'D. heap from C1, rebuilt');
DECLARE @p2Before bigint = (SELECT DataPages FROM Demo.Snapshots WHERE Label LIKE 'C1.%');
DECLARE @t2 nvarchar(200) = N'pages ' + CAST(@p2Before AS nvarchar(20)) + N' -> ' + CAST(@p2 AS nvarchar(20))
                          + N'; ' + CAST(@ms2 AS nvarchar(20)) + N' ms';
DECLARE @v2 varchar(24) = CASE WHEN @p2 <= @p2Before * 0.15 THEN 'EMPTY PAGES GONE' ELSE 'unexpected' END;

EXEC Demo.usp_Record 'D. The fix', 1, 'ALTER TABLE REBUILD, the widened heap', 'forwarded', @fwd, @t1, '0 forwarded; reads = pages', @v1;
EXEC Demo.usp_Record 'D. The fix', 2, 'ALTER TABLE REBUILD, the batch-deleted heap', 'pages', @p2, @t2, 'empty pages released', @v2;
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. EVERY SNAPSHOT ===';
GO
SELECT Label, Structure, RowCnt, DataPages, Forwarded, DensityPct, ScanReads, LookupReads
FROM   Demo.Snapshots ORDER BY SnapshotID;
GO

PRINT '';
PRINT '=== 2. THE VERDICTS ===';
GO
SELECT Scenario, StepNo, Item, Value = NumericValue, Detail = TextValue, Expected, Verdict
FROM   Demo.DemoResults WHERE Scenario <> 'C. escalations' ORDER BY ResultID;
GO

PRINT '';
PRINT '=== 3. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, StepNo, Item, NumericValue, TextValue, Verdict
FROM   Demo.DemoResults WHERE Verdict = 'unexpected';
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
