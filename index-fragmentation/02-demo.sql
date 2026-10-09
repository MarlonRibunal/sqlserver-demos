/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  Six scenarios, run end to end, each recording its own evidence into
  Demo.DemoResults and Demo.IndexSnapshots. The summary at the bottom is the
  payoff.

  Scenarios
    A  logical fragmentation, full pages   -> 99% fragmented, ZERO extra reads
    B  half-empty pages, in order          -> 0% fragmented, TWICE the reads
    C  a random GUID key                   -> both at once; the reads track
                                              density, not fragmentation
    D  cold reads                          -> where out-of-order pages do cost
                                              something: I/O count, not bytes
    E  what the 5% / 30% rule would do     -> rebuilds the table that gains
                                              nothing, skips the one that
                                              gains most
    F  FILLFACTOR                          -> fewer splits, paid for on every
                                              read

  Expected runtime: under a minute. Scenario E builds six fresh tables to
  maintain, so that this file can be run again without re-running setup.

  ############################################################################
  #  SCENARIO D TAKES FragmentationDemo OFFLINE AND BACK ONLINE              #
  #                                                                          #
  #  That is how it gets a cold cache for this one database without          #
  #  DBCC DROPCLEANBUFFERS, which would empty the buffer pool of the whole    #
  #  instance. Any other session connected to FragmentationDemo is           #
  #  disconnected (ROLLBACK IMMEDIATE). No other database is affected.        #
  ############################################################################

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers,
  Linux container on NVMe storage.
==============================================================================*/

USE FragmentationDemo;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('Demo.usp_Snapshot') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

TRUNCATE TABLE Demo.DemoResults;
TRUNCATE TABLE Demo.IndexSnapshots;
GO


/*==============================================================================
  SCENARIO A -- logical fragmentation, and nothing else

  Demo.Dense and Demo.Scattered hold the same 100,000 rows on the same number
  of pages, each about 99% full. The only difference is ORDER: Demo.Scattered's
  pages were reversed by a file shrink in setup, so almost every page's
  next-page pointer leads backwards in the file. avg_fragmentation_in_percent
  is ~99.97 -- as bad as that number gets.

  What to look for:
    - identical logical reads for both tables
    - identical buffer pool footprint

  A logical read is a page touched in memory. Once a page is in the buffer
  pool, where it sits in the data file is irrelevant -- the scan follows the
  page pointers, and the pointers do not care which direction they point.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO A: logical fragmentation, full pages ---';
GO

DECLARE @dense bigint, @scattered bigint;
EXEC Demo.usp_Snapshot 'A. control',   'Demo.Dense',     @dense     OUTPUT;
EXEC Demo.usp_Snapshot 'A. scattered', 'Demo.Scattered', @scattered OUTPUT;

DECLARE @ratio decimal(18,3) = @scattered * 1.0 / @dense;
DECLARE @verdict varchar(24) =
    CASE WHEN @ratio BETWEEN 0.95 AND 1.05 THEN 'NO EXTRA READS' ELSE 'unexpected' END;

EXEC Demo.usp_Record 'A. Logical fragmentation only', 1,
     'Demo.Scattered reads / Demo.Dense reads', 'ratio', @ratio, NULL,
     '1.00 -- page order does not change reads', @verdict;
GO


/*==============================================================================
  SCENARIO B -- half-empty pages, and nothing else

  Demo.Sparse was loaded with 200,000 rows and then had every second row
  deleted -- a purge job in miniature. Every page kept its place and its
  neighbours, so fragmentation is ~0%. But every page is now half empty, so
  the same 100,000 rows are spread over twice as many pages.

  What to look for:
    - about TWICE the logical reads of Demo.Dense
    - about twice the buffer pool memory, for the same rows

  That second figure is the one people miss. Half-empty pages are not just
  slower to scan; they are cached half-empty too. Every MB of buffer pool they
  hold is half air, and something else is evicted to make room for it.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO B: low page density, in order ---';
GO

DECLARE @sparse bigint;
EXEC Demo.usp_Snapshot 'B. sparse', 'Demo.Sparse', @sparse OUTPUT;

DECLARE @dense bigint =
    (SELECT LogicalReads FROM Demo.IndexSnapshots WHERE Label = 'A. control');
DECLARE @ratio decimal(18,3) = @sparse * 1.0 / @dense;
DECLARE @verdict varchar(24) =
    CASE WHEN @ratio >= 1.8 THEN 'READS DOUBLED' ELSE 'unexpected' END;

EXEC Demo.usp_Record 'B. Low density only', 1,
     'Demo.Sparse reads / Demo.Dense reads', 'ratio', @ratio, NULL,
     '~2.0 -- half-empty pages, twice the pages', @verdict;

DECLARE @denseMB  decimal(18,3) = (SELECT BufferPoolMB FROM Demo.IndexSnapshots WHERE Label = 'A. control');
DECLARE @sparseMB decimal(18,3) = (SELECT BufferPoolMB FROM Demo.IndexSnapshots WHERE Label = 'B. sparse');
DECLARE @mbRatio  decimal(18,3) = @sparseMB / NULLIF(@denseMB, 0);
DECLARE @mbText   nvarchar(200) =
    CAST(@sparseMB AS nvarchar(20)) + N' MB vs ' + CAST(@denseMB AS nvarchar(20)) + N' MB';
DECLARE @mbVerdict varchar(24) =
    CASE WHEN @mbRatio >= 1.8 THEN 'MEMORY DOUBLED' ELSE 'unexpected' END;

EXEC Demo.usp_Record 'B. Low density only', 2,
     'buffer pool held by Demo.Sparse vs Demo.Dense', 'ratio', @mbRatio, @mbText,
     '~2.0 -- the empty half is cached too', @mbVerdict;
GO


/*==============================================================================
  SCENARIO C -- a random GUID clustering key

  The case that gave fragmentation its reputation. Rows arrive with a NEWID()
  key, so they land all over the index; a full page that receives a row splits
  in two, leaving two pages about half full and the new one somewhere else in
  the file. The result is BOTH conditions at once: ~99% fragmented and ~68%
  dense.

  So which one costs the reads? Scenarios A and B already answered that. If
  density is the cost, Demo.Random's reads should exceed Demo.Dense's by the
  ratio of their densities -- about 98.8 / 67.9 = 1.46 -- and the 99%
  fragmentation should add nothing on top.

  What to look for:
    - the read ratio lands on the density ratio, within a few percent
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO C: random GUID key ---';
GO

DECLARE @random bigint;
EXEC Demo.usp_Snapshot 'C. random', 'Demo.Random', @random OUTPUT;

DECLARE @dense bigint =
    (SELECT LogicalReads FROM Demo.IndexSnapshots WHERE Label = 'A. control');
DECLARE @readRatio decimal(18,3) = @random * 1.0 / @dense;
DECLARE @densRatio decimal(18,3) =
    (SELECT d.DensityPct / r.DensityPct
     FROM   Demo.IndexSnapshots AS d, Demo.IndexSnapshots AS r
     WHERE  d.Label = 'A. control' AND r.Label = 'C. random');
DECLARE @densText nvarchar(200) =
    N'density ratio predicts ' + CAST(CAST(@densRatio AS decimal(6,2)) AS nvarchar(20));
DECLARE @verdict varchar(24) =
    CASE WHEN ABS(@readRatio - @densRatio) / @densRatio <= 0.05 THEN 'EXPLAINED BY DENSITY'
         ELSE 'unexpected' END;

EXEC Demo.usp_Record 'C. Random GUID key', 1,
     'Demo.Random reads / Demo.Dense reads', 'ratio', @readRatio, @densText,
     'equal to the density ratio -- fragmentation adds nothing', @verdict;
GO


/*==============================================================================
  SCENARIO D -- cold reads: where page order does cost something

  Everything above measured LOGICAL reads, which is what a warm workload pays.
  The traditional argument for defragmenting is about PHYSICAL reads: a scan
  reads ahead in large I/Os, and only pages that sit next to each other on disk
  can be read in one I/O.

  To test that honestly the pages have to come off disk, which needs a cold
  cache. DBCC DROPCLEANBUFFERS would do it by emptying the buffer pool of the
  WHOLE INSTANCE, so this does not use it. Taking this one database offline
  and back online evicts its pages and nobody else's.

  Each table lives alone in its own file, so sys.dm_io_virtual_file_stats on
  that file counts exactly the I/Os its scan issued.

  What to look for:
    - Demo.Scattered issues about as many I/Os as Demo.Dense, of much the same
      size. Its pages are in reverse order, but they are still CONTIGUOUS, and
      read-ahead fetches contiguous runs whichever way they point. A 99.97%
      fragmentation figure, and the disk can barely tell. (The exact count
      depends on where the shrink happened to put each page, so it differs
      between SETUPS -- from 1.06x to 1.35x across four builds of the tested
      instance -- while repeating exactly across demo runs on the same setup.
      Hence a verdict of "under 2x". Demo.Random lands at 6-8x.)
    - Demo.Random issues many more, much smaller I/Os. Its pages are scattered
      across the file one split at a time, so read-ahead rarely finds two
      neighbours to fetch together. THIS is the real cost of logical
      fragmentation: I/O count, not bytes. On spinning disks it was serious;
      on SSD it is far smaller, and on a warm cache it is zero.
    - Demo.Sparse reads about twice the bytes, in normal-sized I/Os.

  Elapsed milliseconds are recorded but carry no verdict. On fast storage
  they are small and noisy; the I/O counts are the evidence.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO D: cold reads (taking FragmentationDemo offline and online) ---';
GO

USE master;
GO
ALTER DATABASE FragmentationDemo SET OFFLINE WITH ROLLBACK IMMEDIATE;
ALTER DATABASE FragmentationDemo SET ONLINE;
GO
USE FragmentationDemo;
GO
SET NOCOUNT ON;
GO

-- Prove the cache really is cold before trusting anything below. A handful of
-- pages (boot page, allocation maps read during recovery) is normal.
DECLARE @cached bigint =
    (SELECT COUNT_BIG(*) FROM sys.dm_os_buffer_descriptors WHERE database_id = DB_ID());
DECLARE @denseLeaf bigint =
    (SELECT LeafPages FROM Demo.IndexSnapshots WHERE Label = 'A. control');
DECLARE @coldVerdict varchar(24) =
    CASE WHEN @cached < @denseLeaf * 0.1 THEN 'COLD' ELSE 'INCONCLUSIVE' END;

EXEC Demo.usp_Record 'D. Cold reads', 0,
     'pages of this database still cached after offline/online', 'pages', @cached, NULL,
     'a few hundred at most', @coldVerdict;
GO

DECLARE @tables TABLE (Seq int PRIMARY KEY, TableName sysname, FileName sysname, Expected nvarchar(140));
INSERT @tables VALUES
 (1, 'Demo.Dense',     'FG_Dense',     'baseline: few, large read-ahead I/Os'),
 (2, 'Demo.Scattered', 'FG_Scattered', 'close to Dense (under 2x) -- pages still contiguous'),
 (3, 'Demo.Sparse',    'FG_Sparse',    'about twice the bytes of Dense'),
 (4, 'Demo.Random',    'FG_Random',    'many more, much smaller I/Os');

DECLARE @seq int = 1, @tbl sysname, @file sysname, @exp nvarchar(140), @sql nvarchar(400),
        @fileId int, @r0 bigint, @b0 bigint, @t0 datetime2(7),
        @ios bigint, @bytes bigint, @ms int,
        @denseIos bigint, @denseBytes bigint;

WHILE @seq <= 4
BEGIN
    SELECT @tbl = TableName, @file = FileName, @exp = Expected FROM @tables WHERE Seq = @seq;
    SET @fileId = FILE_IDEX(@file);
    SET @sql = N'DECLARE @c bigint; SELECT @c = COUNT_BIG(*) FROM ' + @tbl + N' OPTION (MAXDOP 1);';

    SELECT @r0 = num_of_reads, @b0 = num_of_bytes_read
    FROM   sys.dm_io_virtual_file_stats(DB_ID(), @fileId);
    SET @t0 = SYSDATETIME();

    EXEC sys.sp_executesql @sql;

    SET @ms = DATEDIFF(millisecond, @t0, SYSDATETIME());
    SELECT @ios = num_of_reads - @r0, @bytes = num_of_bytes_read - @b0
    FROM   sys.dm_io_virtual_file_stats(DB_ID(), @fileId);

    IF @seq = 1 SELECT @denseIos = @ios, @denseBytes = @bytes;

    DECLARE @detail nvarchar(200) =
          CAST(CAST(@bytes / 1048576.0 AS decimal(8,1)) AS nvarchar(20)) + N' MB read, avg '
        + CAST(CAST(@bytes / 1024.0 / NULLIF(@ios, 0) AS decimal(8,1)) AS nvarchar(20)) + N' KB per I/O, '
        + CAST(@ms AS nvarchar(20)) + N' ms';

    DECLARE @ioRatio    decimal(18,3) = @ios   * 1.0 / NULLIF(@denseIos, 0);
    DECLARE @bytesRatio decimal(18,3) = @bytes * 1.0 / NULLIF(@denseBytes, 0);
    DECLARE @verdict varchar(24) =
        CASE @seq
             WHEN 1 THEN 'BASELINE'
             WHEN 2 THEN CASE WHEN @ioRatio < 2                THEN 'NEAR BASELINE'      ELSE 'unexpected' END
             WHEN 3 THEN CASE WHEN @bytesRatio >= 1.7          THEN 'TWICE THE BYTES'    ELSE 'unexpected' END
             WHEN 4 THEN CASE WHEN @ioRatio >= 3               THEN 'MANY SMALL I/Os'    ELSE 'unexpected' END
        END;

    EXEC Demo.usp_Record 'D. Cold reads', @seq, @tbl, 'read I/Os', @ios, @detail, @exp, @verdict;

    SET @seq += 1;
END

UPDATE Demo.DemoResults
SET    Verdict = 'INCONCLUSIVE'
WHERE  Scenario = 'D. Cold reads'
  AND  EXISTS (SELECT 1 FROM Demo.DemoResults
               WHERE Scenario = 'D. Cold reads' AND StepNo = 0 AND Verdict = 'INCONCLUSIVE');
GO


/*==============================================================================
  SCENARIO E -- what the 5% / 30% rule does with these tables

  The rule most maintenance jobs implement: under 5% fragmentation leave it,
  5-30% REORGANIZE, over 30% REBUILD. Demo.fn_RuleSays is that rule.

  For each of the three problem shapes this builds a fresh copy ("victim") in
  FG_Work, asks the rule what to do, then actually runs REORGANIZE on one copy
  and REBUILD on another, measuring:

    - reads before and after       did the maintenance buy anything?
    - transaction log written      what did it cost?
    - elapsed time
    - whether statistics were      REBUILD refreshes the index's statistics
      refreshed                    with a full scan. REORGANIZE does not
                                   touch them. Jobs that rebuild "for the
                                   statistics" are relying on this.

  Log bytes come from sys.dm_io_virtual_file_stats on the log file, which is
  cumulative. Not from sys.dm_db_log_space_usage: in SIMPLE recovery a
  checkpoint can truncate the log mid-operation and make that delta
  meaningless.

  Statistics are first refreshed with a deliberately small SAMPLE, so "was it
  refreshed afterwards" can be read off rows_sampled without guessing.

  What to look for:
    - scattered: rule says REBUILD. Reads saved: ~0%. Work for nothing.
    - sparse:    rule says leave alone. Reads saved: ~50%. Missed entirely.
    - random:    rule says REBUILD, and it pays -- but only because of the
                 density it recovers, as scenario C predicted.

  A note on the log figures: FragmentationDemo uses SIMPLE recovery, where
  REBUILD is minimally logged. Under FULL recovery REBUILD is fully logged and
  writes roughly the size of the index to the log. REORGANIZE is fully logged
  in every recovery model.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO E: the 5% / 30% rule vs the reads (builds six tables) ---';
GO

DECLARE @runs TABLE (Seq int PRIMARY KEY, Shape varchar(10), Op varchar(12));
INSERT @runs VALUES (1, 'scattered', 'REORGANIZE'), (2, 'scattered', 'REBUILD'),
                    (3, 'sparse',    'REORGANIZE'), (4, 'sparse',    'REBUILD'),
                    (5, 'random',    'REORGANIZE'), (6, 'random',    'REBUILD');

DECLARE @seq int = 1, @shape varchar(10), @op varchar(12), @sql nvarchar(400),
        @readsBefore bigint, @readsAfter bigint, @rule varchar(20),
        @log0 bigint, @logBytes bigint, @t0 datetime2(7), @ms int,
        @sampledBefore bigint, @sampledAfter bigint, @rowCnt bigint,
        @lblBefore varchar(60), @lblAfter varchar(60);

WHILE @seq <= 6
BEGIN
    SELECT @shape = Shape, @op = Op FROM @runs WHERE Seq = @seq;
    SET @lblBefore = 'E. ' + @shape + ' before ' + @op;
    SET @lblAfter  = 'E. ' + @shape + ' after '  + @op;

    EXEC Demo.usp_BuildTable @shape, 'Demo.Victim', 'FG_Work';

    UPDATE STATISTICS Demo.Victim PK_Victim WITH SAMPLE 5 PERCENT;
    SELECT @sampledBefore = rows_sampled
    FROM   sys.dm_db_stats_properties(OBJECT_ID('Demo.Victim'), 1);

    EXEC Demo.usp_Snapshot @lblBefore, 'Demo.Victim', @readsBefore OUTPUT;

    SELECT @rule = Demo.fn_RuleSays(FragPct, LeafPages)
    FROM   Demo.IndexSnapshots WHERE Label = @lblBefore;

    SET @sql = N'ALTER INDEX PK_Victim ON Demo.Victim ' + @op + N';';

    SELECT @log0 = num_of_bytes_written FROM sys.dm_io_virtual_file_stats(DB_ID(), 2);
    SET @t0 = SYSDATETIME();

    EXEC sys.sp_executesql @sql;

    SET @ms = DATEDIFF(millisecond, @t0, SYSDATETIME());
    SELECT @logBytes = num_of_bytes_written - @log0 FROM sys.dm_io_virtual_file_stats(DB_ID(), 2);

    SELECT @sampledAfter = rows_sampled, @rowCnt = [rows]
    FROM   sys.dm_db_stats_properties(OBJECT_ID('Demo.Victim'), 1);

    EXEC Demo.usp_Snapshot @lblAfter, 'Demo.Victim', @readsAfter OUTPUT;

    DECLARE @saved decimal(18,3) = 100.0 * (@readsBefore - @readsAfter) / @readsBefore;
    DECLARE @statsTxt varchar(40) =
        CASE WHEN @sampledAfter = @rowCnt AND @sampledBefore < @rowCnt THEN 'stats refreshed (full scan)'
             WHEN @sampledAfter = @sampledBefore                        THEN 'stats untouched'
             ELSE 'stats: sampled ' + CAST(@sampledAfter AS varchar(20)) END;
    DECLARE @detail nvarchar(200) =
          N'rule says ' + @rule + N'; reads ' + CAST(@readsBefore AS nvarchar(20))
        + N' -> ' + CAST(@readsAfter AS nvarchar(20))
        + N'; log ' + CAST(CAST(@logBytes / 1048576.0 AS decimal(8,1)) AS nvarchar(20)) + N' MB; '
        + CAST(@ms AS nvarchar(20)) + N' ms; ' + @statsTxt;
    DECLARE @item varchar(90) = @shape + ': ' + @op;

    -- The verdict compares what the rule decided with what the maintenance
    -- actually bought. "Bought" means reads saved by doing it at all.
    DECLARE @ruleActs bit = CASE WHEN @rule IN ('REORGANIZE', 'REBUILD') THEN 1 ELSE 0 END;
    DECLARE @verdict varchar(24) =
        CASE WHEN @ruleActs = 1 AND @saved <  5 THEN 'WORK FOR NOTHING'
             WHEN @ruleActs = 0 AND @saved >= 20 THEN 'RULE MISSED IT'
             WHEN @ruleActs = 1 AND @saved >= 20 THEN 'PAID OFF'
             WHEN @ruleActs = 0 AND @saved <  5 THEN 'CORRECTLY IGNORED'
             ELSE 'MARGINAL' END;
    DECLARE @predicted varchar(24) =
        CASE @shape WHEN 'scattered' THEN 'WORK FOR NOTHING'
                    WHEN 'sparse'    THEN 'RULE MISSED IT'
                    ELSE                  'PAID OFF' END;
    DECLARE @exp nvarchar(140) =
        CASE @shape WHEN 'scattered' THEN 'rule acts; ~0% saved'
                    WHEN 'sparse'    THEN 'rule ignores it; ~50% saved'
                    ELSE                  'rule acts; ~30% saved, all from density' END
        + N' (' + @predicted + N')';

    -- The categories above are generic, so a surprising result would still
    -- land in one of them -- a scattered table that DID gain from a rebuild
    -- would read 'PAID OFF' and look like a pass. Anything other than the
    -- predicted category is recorded as unexpected, so result set 6 sees it.
    IF @verdict <> @predicted SET @verdict = 'unexpected';

    EXEC Demo.usp_Record 'E. The 5/30 rule', @seq, @item, 'reads saved %', @saved,
         @detail, @exp, @verdict;

    -- Record the raw cost figures as their own rows too, so the summary can
    -- line them up as columns.
    DECLARE @logMB decimal(18,3) = @logBytes / 1048576.0;
    EXEC Demo.usp_Record 'E. cost', @seq, @item, 'log MB', @logMB, @statsTxt;
    EXEC Demo.usp_Record 'E. time', @seq, @item, 'ms', @ms;

    SET @seq += 1;
END

DROP TABLE IF EXISTS Demo.Victim;
GO


/*==============================================================================
  SCENARIO F -- FILLFACTOR: the trade, priced

  FILLFACTOR leaves free space on each page when an index is built, so that
  inserts into the middle of the key range have somewhere to go without
  splitting the page. It is the right tool for an index whose inserts land
  all over its key range. It is also, by construction, scenario B on purpose:
  every scan of a FILLFACTOR 80 index reads about 20% more pages than it
  has to.

  Two identical tables, 100,000 rows with EVEN ids only, one built at
  FILLFACTOR 100 and one at 80. Then the same 10,000 random ODD ids go into
  both -- the gaps in the key range, the worst case for a full page.

  Page splits are counted as growth in the leaf page count. That is
  deterministic and belongs to this table alone. The obvious source,
  sys.dm_db_index_operational_stats.leaf_allocation_count, stayed at ZERO on
  the tested build through thousands of splits, and the "Page Splits/sec"
  performance counter is instance-wide.

  What to look for:
    - FILLFACTOR 80 reads ~20% more BEFORE a single row is inserted
    - FILLFACTOR 100 splits most of its pages and jumps to high fragmentation
    - FILLFACTOR 80 absorbs the same inserts with almost no splits
    - and afterwards FILLFACTOR 100 is the one reading MORE: every split left
      two half-full pages, so it ends up sparser than the index that reserved
      its free space up front
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO F: FILLFACTOR ---';
GO

DROP TABLE IF EXISTS Demo.Fill100, Demo.Fill80;
CREATE TABLE Demo.Fill100 (id int NOT NULL, g uniqueidentifier NOT NULL, pad char(200) NOT NULL,
                           CONSTRAINT PK_Fill100 PRIMARY KEY CLUSTERED (id));
CREATE TABLE Demo.Fill80  (id int NOT NULL, g uniqueidentifier NOT NULL, pad char(200) NOT NULL,
                           CONSTRAINT PK_Fill80  PRIMARY KEY CLUSTERED (id));
GO

;WITH n AS (SELECT TOP (100000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
            FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b)
INSERT Demo.Fill100 WITH (TABLOCK) (id, g, pad) SELECT rn * 2, NEWID(), 'x' FROM n;

INSERT Demo.Fill80 WITH (TABLOCK) (id, g, pad) SELECT id, g, pad FROM Demo.Fill100;

ALTER INDEX PK_Fill100 ON Demo.Fill100 REBUILD WITH (FILLFACTOR = 100);
ALTER INDEX PK_Fill80  ON Demo.Fill80  REBUILD WITH (FILLFACTOR = 80);
GO

DECLARE @r100 bigint, @r80 bigint;
EXEC Demo.usp_Snapshot 'F. FILLFACTOR 100 before', 'Demo.Fill100', @r100 OUTPUT;
EXEC Demo.usp_Snapshot 'F. FILLFACTOR 80 before',  'Demo.Fill80',  @r80  OUTPUT;

DECLARE @tax decimal(18,3) = @r80 * 1.0 / @r100;
DECLARE @verdict varchar(24) = CASE WHEN @tax >= 1.15 THEN 'READ TAX PAID' ELSE 'unexpected' END;

EXEC Demo.usp_Record 'F. FILLFACTOR', 1, 'reads before inserts: FF 80 / FF 100', 'ratio', @tax,
     NULL, '~1.2 -- the reserved space, read on every scan', @verdict;
GO

-- The same 10,000 odd ids for both tables, in the same random order, inserted
-- 100 at a time so they arrive scattered rather than pre-sorted.
DROP TABLE IF EXISTS #incoming;
;WITH n AS (SELECT TOP (100000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
            FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b)
SELECT id, seq = ROW_NUMBER() OVER (ORDER BY NEWID())   -- numbered AFTER the TOP,
INTO   #incoming                                       -- so seq runs 1..10,000
FROM   (SELECT TOP (10000) id = rn * 2 - 1 FROM n ORDER BY NEWID()) AS pick;

DECLARE @b int = 0;
WHILE @b < 100
BEGIN
    INSERT Demo.Fill100 (id, g, pad) SELECT id, NEWID(), 'x' FROM #incoming WHERE (seq - 1) / 100 = @b;
    INSERT Demo.Fill80  (id, g, pad) SELECT id, NEWID(), 'x' FROM #incoming WHERE (seq - 1) / 100 = @b;
    SET @b += 1;
END
DROP TABLE #incoming;
GO

DECLARE @r100 bigint, @r80 bigint;
EXEC Demo.usp_Snapshot 'F. FILLFACTOR 100 after', 'Demo.Fill100', @r100 OUTPUT;
EXEC Demo.usp_Snapshot 'F. FILLFACTOR 80 after',  'Demo.Fill80',  @r80  OUTPUT;

DECLARE @split100 bigint =
    (SELECT a.LeafPages - b.LeafPages FROM Demo.IndexSnapshots AS a, Demo.IndexSnapshots AS b
     WHERE  a.Label = 'F. FILLFACTOR 100 after' AND b.Label = 'F. FILLFACTOR 100 before');
DECLARE @split80 bigint =
    (SELECT a.LeafPages - b.LeafPages FROM Demo.IndexSnapshots AS a, Demo.IndexSnapshots AS b
     WHERE  a.Label = 'F. FILLFACTOR 80 after'  AND b.Label = 'F. FILLFACTOR 80 before');
DECLARE @frag100 nvarchar(200) =
    (SELECT N'fragmentation now ' + CAST(FragPct AS nvarchar(20)) + N'%, density ' + CAST(DensityPct AS nvarchar(20)) + N'%'
     FROM Demo.IndexSnapshots WHERE Label = 'F. FILLFACTOR 100 after');
DECLARE @frag80 nvarchar(200) =
    (SELECT N'fragmentation now ' + CAST(FragPct AS nvarchar(20)) + N'%, density ' + CAST(DensityPct AS nvarchar(20)) + N'%'
     FROM Demo.IndexSnapshots WHERE Label = 'F. FILLFACTOR 80 after');

DECLARE @v100 varchar(24) = CASE WHEN @split100 >= 10 * NULLIF(@split80, 0) OR (@split80 = 0 AND @split100 > 100)
                                 THEN 'SPLIT HEAVILY' ELSE 'unexpected' END;
DECLARE @v80  varchar(24) = CASE WHEN @split80 * 10 <= @split100 THEN 'SPLITS AVOIDED' ELSE 'unexpected' END;

EXEC Demo.usp_Record 'F. FILLFACTOR', 2, 'FILLFACTOR 100: pages added by 10,000 inserts', 'pages',
     @split100, @frag100, 'most pages split once', @v100;
EXEC Demo.usp_Record 'F. FILLFACTOR', 3, 'FILLFACTOR 80: pages added by 10,000 inserts', 'pages',
     @split80, @frag80, 'a handful of splits', @v80;

DECLARE @after decimal(18,3) = @r80 * 1.0 / @r100;
DECLARE @vAfter varchar(24) = CASE WHEN @after < 1 THEN 'REVERSED' ELSE 'unexpected' END;
EXEC Demo.usp_Record 'F. FILLFACTOR', 4, 'reads after inserts: FF 80 / FF 100', 'ratio', @after,
     NULL, 'below 1 -- FF 100''s splits left it sparser than FF 80', @vAfter;
GO

DROP TABLE IF EXISTS Demo.Fill100, Demo.Fill80;
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. THE FOUR TABLES: what the maintenance job sees vs what queries pay ===';
GO
SELECT  TableName,
        FragPct,
        DensityPct,
        LeafPages,
        LogicalReads,
        ReadsVsDense = CAST(LogicalReads * 1.0 /
                       (SELECT LogicalReads FROM Demo.IndexSnapshots WHERE Label = 'A. control')
                       AS decimal(6,2)),
        BufferPoolMB,
        RuleSays     = Demo.fn_RuleSays(FragPct, LeafPages)
FROM    Demo.IndexSnapshots
WHERE   Label IN ('A. control', 'A. scattered', 'B. sparse', 'C. random')
ORDER BY SnapshotID;
GO

PRINT '';
PRINT '=== 2. SCENARIOS A-C: which number predicts the reads ===';
GO
SELECT Scenario, Item, Ratio = NumericValue, Detail = TextValue, Expected, Verdict
FROM   Demo.DemoResults
WHERE  Scenario IN ('A. Logical fragmentation only', 'B. Low density only', 'C. Random GUID key')
ORDER BY ResultID;
GO

PRINT '';
PRINT '=== 3. SCENARIO D: cold reads ===';
GO
SELECT StepNo, Item, ReadIOs = CAST(NumericValue AS bigint), Detail = TextValue, Expected, Verdict
FROM   Demo.DemoResults WHERE Scenario = 'D. Cold reads' ORDER BY StepNo;
GO

PRINT '';
PRINT '=== 4. SCENARIO E: the 5% / 30% rule vs the reads ===';
GO
SELECT  r.StepNo,
        r.Item,
        RuleSays      = SUBSTRING(r.TextValue, 11, CHARINDEX(';', r.TextValue) - 11),
        ReadsSavedPct = CAST(r.NumericValue AS decimal(6,1)),
        LogMB         = CAST(c.NumericValue AS decimal(8,1)),
        Ms            = CAST(t.NumericValue AS int),
        StatsAfter    = c.TextValue,
        r.Verdict
FROM    Demo.DemoResults AS r
JOIN    Demo.DemoResults AS c ON c.Scenario = 'E. cost' AND c.StepNo = r.StepNo
JOIN    Demo.DemoResults AS t ON t.Scenario = 'E. time' AND t.StepNo = r.StepNo
WHERE   r.Scenario = 'E. The 5/30 rule'
ORDER BY r.StepNo;
GO

PRINT '';
PRINT '=== 5. SCENARIO F: FILLFACTOR ===';
GO
SELECT StepNo, Item, Value = NumericValue, Detail = TextValue, Expected, Verdict
FROM   Demo.DemoResults WHERE Scenario = 'F. FILLFACTOR' ORDER BY StepNo;
GO

PRINT '';
PRINT '=== 6. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, StepNo, Item, NumericValue, TextValue, Expected, Verdict
FROM   Demo.DemoResults
WHERE  Verdict IN ('unexpected', 'INCONCLUSIVE', 'MARGINAL')
ORDER BY ResultID;
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 6 should be EMPTY. Anything in it is either';
PRINT ' a genuine difference on your build or storage, or a';
PRINT ' condition the scenario could not control -- both are';
PRINT ' worth reading before you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
