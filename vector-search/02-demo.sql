/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Vector search in SQL Server 2025: the exact search (VECTOR_DISTANCE and
  ORDER BY) against the approximate one (VECTOR_SEARCH on a DiskANN vector
  index), on 100,000 vectors of 128 dimensions.

     A  exact search: what one query reads
     B  approximate search: what it reads, and what it misses
     C  filtering the approximate search
     D  writing to a table with a vector index
     E  what the index costs: size and build time
     F  preview features, and vectors of different sizes

  On SQL Server 2022 and earlier every scenario reports SKIPPED.

  WHAT THIS CHANGES: only VectorDemo. Scenario F turns PREVIEW_FEATURES off
  and back on, and creates and drops a small table. Every write in
  scenario D fails, by design.

  TESTED end to end on SQL Server 2025 RTM-CU9-GDR (17.0.5015.4), Linux
  container.
==============================================================================*/

USE VectorDemo;
GO
SET NOCOUNT ON;
GO

TRUNCATE TABLE Demo.Results;
TRUNCATE TABLE Demo.Verdicts;
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) < 17
    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'vectors: exact search',              'needs SQL Server 2025 or later', 'SKIPPED'),
    ('B', 'vectors: approximate search',        'needs SQL Server 2025 or later', 'SKIPPED'),
    ('C', 'vectors: filtering',                 'needs SQL Server 2025 or later', 'SKIPPED'),
    ('D', 'vectors: writes',                    'needs SQL Server 2025 or later', 'SKIPPED'),
    ('E', 'vectors: index size and build time', 'needs SQL Server 2025 or later', 'SKIPPED'),
    ('F', 'vectors: preview and dimensions',    'needs SQL Server 2025 or later', 'SKIPPED');
GO


/*==============================================================================
  A and B. Twenty query vectors, none of them in the table: each near one
  cluster's centre, with more noise than the stored rows. For each, the
  exact top 10 and the approximate top 10, and the logical reads of each.
==============================================================================*/
PRINT '=== A and B. exact against approximate, 20 queries ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
EXEC (N'
    DECLARE @i int = 1, @q vector(128), @r0 bigint, @r1 bigint, @r2 bigint,
            @readsExact bigint = 0, @readsApprox bigint = 0, @hits int = 0, @perfect int = 0, @h int;
    DECLARE @exact  TABLE (ID int PRIMARY KEY);
    DECLARE @approx TABLE (ID int PRIMARY KEY);

    WHILE @i <= 20
    BEGIN
        SELECT @q = CAST(''['' + STRING_AGG(CAST(CAST(
                        (ABS(CHECKSUM(CONCAT(''c'', @i * 7 % 200, ''-'', d.dn))) % 1000) / 1000.0
                      + (ABS(CHECKSUM(CONCAT(''q'', @i, ''-'', d.dn))) % 1000) / 1500.0
                    AS decimal(9,6)) AS varchar(max)), '','') WITHIN GROUP (ORDER BY d.dn) + '']'' AS vector(128))
        FROM   (SELECT TOP (128) dn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int) FROM sys.all_columns) AS d;

        DELETE @exact; DELETE @approx;

        SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
        INSERT @exact (ID)
        SELECT TOP (10) ID FROM Demo.Embeddings ORDER BY VECTOR_DISTANCE(''cosine'', Embedding, @q);
        SELECT @r1 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
        INSERT @approx (ID)
        SELECT t.ID
        FROM   VECTOR_SEARCH(TABLE = Demo.Embeddings AS t, COLUMN = Embedding, SIMILAR_TO = @q,
                             METRIC = ''cosine'', TOP_N = 10) AS s;
        SELECT @r2 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;

        SELECT @h = COUNT(*) FROM @exact AS e JOIN @approx AS a ON a.ID = e.ID;
        SELECT @readsExact += @r1 - @r0, @readsApprox += @r2 - @r1, @hits += @h,
               @perfect += CASE WHEN @h = 10 THEN 1 ELSE 0 END;
        SET @i += 1;
    END

    DECLARE @pages bigint = (SELECT SUM(used_page_count) FROM sys.dm_db_partition_stats
                             WHERE object_id = OBJECT_ID(N''Demo.Embeddings'') AND index_id IN (0, 1));

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    (''A'', ''pages in Demo.Embeddings'',                       CAST(@pages AS varchar(20))),
    (''A'', ''reads per query, exact (VECTOR_DISTANCE + TOP)'', CAST(@readsExact / 20 AS varchar(20))),
    (''B'', ''reads per query, approximate (VECTOR_SEARCH)'',   CAST(@readsApprox / 20 AS varchar(20))),
    (''B'', ''recall: exact top-10 rows the search also found'', CAST(@hits AS varchar(10)) + '' of 200''),
    (''B'', ''queries with all 10 found'',                      CAST(@perfect AS varchar(10)) + '' of 20'');

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    (''A'', ''the exact search reads the whole table for every query'',
     CAST(@readsExact / 20 AS varchar(20)) + '' reads per query; the table is '' + CAST(@pages AS varchar(20)) + '' pages'',
     CASE WHEN @readsExact / 20 * 10 >= @pages * 9 THEN ''CONFIRMED'' ELSE ''unexpected'' END),
    (''B'', ''VECTOR_SEARCH reads at most half as much'',
     CAST(@readsApprox / 20 AS varchar(20)) + '' reads per query, against '' + CAST(@readsExact / 20 AS varchar(20)),
     CASE WHEN @readsApprox * 2 <= @readsExact THEN ''CONFIRMED'' ELSE ''unexpected'' END),
    (''B'', ''... and it is approximate: it found most, but not reliably all, of the true top 10'',
     CAST(@hits AS varchar(10)) + '' of 200 ('' + CAST(@hits / 2 AS varchar(10)) + ''%); all 10 in '' + CAST(@perfect AS varchar(10)) + '' of 20 queries'',
     CASE WHEN @hits >= 140 THEN ''CONFIRMED'' ELSE ''unexpected'' END);');
GO


/*==============================================================================
  C. Filtering. The 10 nearest rows to row 777 that are NOT in its cluster.
  VECTOR_SEARCH finds its top 10 first; the WHERE clause is applied after.
==============================================================================*/
PRINT '=== C. filtering ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
EXEC (N'
    DECLARE @q vector(128), @cluster int, @nApprox int, @nExact int, @nWide int;
    SELECT @q = Embedding, @cluster = ClusterID FROM Demo.Embeddings WHERE ID = 777;

    SELECT @nApprox = COUNT(*)
    FROM   VECTOR_SEARCH(TABLE = Demo.Embeddings AS t, COLUMN = Embedding, SIMILAR_TO = @q,
                         METRIC = ''cosine'', TOP_N = 10) AS s
    WHERE  t.ClusterID <> @cluster;

    SELECT @nWide = COUNT(*)
    FROM   VECTOR_SEARCH(TABLE = Demo.Embeddings AS t, COLUMN = Embedding, SIMILAR_TO = @q,
                         METRIC = ''cosine'', TOP_N = 1000) AS s
    WHERE  t.ClusterID <> @cluster;

    SELECT @nExact = COUNT(*)
    FROM   (SELECT TOP (10) ID FROM Demo.Embeddings
            WHERE ClusterID <> @cluster
            ORDER BY VECTOR_DISTANCE(''cosine'', Embedding, @q)) AS x;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    (''C'', ''rows: VECTOR_SEARCH TOP_N = 10, then WHERE other clusters'',   CAST(@nApprox AS varchar(10))),
    (''C'', ''rows: VECTOR_SEARCH TOP_N = 1000, then WHERE other clusters'', CAST(@nWide AS varchar(10))),
    (''C'', ''rows: exact TOP (10) with the WHERE'',                          CAST(@nExact AS varchar(10)));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    (''C'', ''a WHERE on VECTOR_SEARCH filters its top N afterwards: asked for 10, got fewer'',
     CAST(@nApprox AS varchar(10)) + '' rows from VECTOR_SEARCH; the exact query returned '' + CAST(@nExact AS varchar(10)),
     CASE WHEN @nApprox < 10 AND @nExact = 10 THEN ''CONFIRMED'' ELSE ''unexpected'' END),
    (''C'', ''asking for a bigger TOP_N and filtering that gets the rows back'',
     CAST(@nWide AS varchar(10)) + '' rows left of 1,000'',
     CASE WHEN @nWide >= 10 THEN ''CONFIRMED'' ELSE ''unexpected'' END);');
GO


/*==============================================================================
  D. Writing. Insert, update and delete one row of the indexed table.
==============================================================================*/
PRINT '=== D. writes ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @eIns int, @eUpd int, @eDel int;
    EXEC Demo.usp_Try N'INSERT Demo.Embeddings (ID, ClusterID, Embedding) SELECT -1, ClusterID, Embedding FROM Demo.Embeddings WHERE ID = 1;', @eIns OUTPUT;
    EXEC Demo.usp_Try N'UPDATE Demo.Embeddings SET ClusterID = ClusterID WHERE ID = 1;', @eUpd OUTPUT;
    EXEC Demo.usp_Try N'DELETE Demo.Embeddings WHERE ID = -1;',                          @eDel OUTPUT;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('D', 'INSERT one row', CASE @eIns WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eIns AS varchar(10)) END),
    ('D', 'UPDATE one row (a column that isn''t the vector)', CASE @eUpd WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eUpd AS varchar(10)) END),
    ('D', 'DELETE (no rows match)', CASE @eDel WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eDel AS varchar(10)) END);

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('D', 'on this build a vector index makes the table read-only (error 42231)',
     'INSERT ' + CAST(@eIns AS varchar(10)) + ', UPDATE ' + CAST(@eUpd AS varchar(10)) + ', DELETE ' + CAST(@eDel AS varchar(10)),
     CASE WHEN @eIns = 42231 AND @eUpd = 42231 AND @eDel = 42231 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  E. What the index costs: its size, and how long setup took to build it.
==============================================================================*/
PRINT '=== E. size and build time ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @pTable bigint, @pIndex bigint, @ms bigint, @load bigint;
    SELECT @pTable = SUM(used_page_count) FROM sys.dm_db_partition_stats
    WHERE  object_id = OBJECT_ID(N'Demo.Embeddings') AND index_id IN (0, 1);
    SELECT @pIndex = SUM(ps.used_page_count)
    FROM   sys.dm_db_partition_stats AS ps
    JOIN   sys.internal_tables AS it ON it.object_id = ps.object_id
    WHERE  it.name LIKE N'vector[_]index[_]%[_]' + CAST(OBJECT_ID(N'Demo.Embeddings') AS nvarchar(20)) + N'[_]%';
    SELECT @ms = Value FROM Demo.SetupLog WHERE Item = 'vector index build ms';
    SELECT @load = Value FROM Demo.SetupLog WHERE Item = 'load ms';

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('E', 'pages: the table',           CAST(@pTable AS varchar(20))),
    ('E', 'pages: the vector index',    CAST(@pIndex AS varchar(20))),
    ('E', 'ms to load the 100,000 rows', CAST(@load AS varchar(20))),
    ('E', 'ms to build the index',      CAST(@ms AS varchar(20)));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('E', 'the vector index is at least a quarter the size of the table',
     CAST(@pIndex AS varchar(20)) + ' pages, against ' + CAST(@pTable AS varchar(20)),
     CASE WHEN @pIndex * 4 >= @pTable THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('E', 'building the index took longer than generating and loading the rows',
     CAST(@ms AS varchar(20)) + ' ms to build, ' + CAST(@load AS varchar(20)) + ' ms to load',
     CASE WHEN @ms > @load THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  F. Preview features, and vectors of different sizes.
==============================================================================*/
PRINT '=== F. preview features and dimensions ===';
GO
-- A database scoped configuration applies from the next batch, so each
-- change is a batch of its own, and each attempt is recorded as it runs.
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    EXEC (N'DROP TABLE IF EXISTS Demo.Small;');
    EXEC (N'CREATE TABLE Demo.Small (ID int NOT NULL CONSTRAINT PK_Small PRIMARY KEY, v vector(3) NOT NULL);
            INSERT Demo.Small VALUES (1, ''[1,0,0]''), (2, ''[0,1,0]'');');
    EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = OFF;');
END
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @e int;
    EXEC Demo.usp_Try N'CREATE VECTOR INDEX VX_Small ON Demo.Small (v) WITH (METRIC = ''cosine'', TYPE = ''diskann'');', @e OUTPUT;
    INSERT Demo.Results (Scenario, Item, Value)
    VALUES ('F', 'CREATE VECTOR INDEX, PREVIEW_FEATURES = OFF', CASE @e WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e AS varchar(10)) END);
    EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;');
END
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @e int;
    EXEC Demo.usp_Try N'CREATE VECTOR INDEX VX_Small ON Demo.Small (v) WITH (METRIC = ''cosine'', TYPE = ''diskann'');', @e OUTPUT;
    INSERT Demo.Results (Scenario, Item, Value)
    VALUES ('F', 'CREATE VECTOR INDEX, PREVIEW_FEATURES = ON', CASE @e WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e AS varchar(10)) END);
    EXEC (N'DROP TABLE IF EXISTS Demo.Small;');

    EXEC Demo.usp_Try N'DECLARE @d float = VECTOR_DISTANCE(''cosine'', CAST(''[1,0,0]'' AS vector(3)), CAST(''[1,0]'' AS vector(2)));', @e OUTPUT;
    INSERT Demo.Results (Scenario, Item, Value)
    VALUES ('F', 'VECTOR_DISTANCE between vector(3) and vector(2)', CASE @e WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e AS varchar(10)) END);

    DECLARE @off varchar(40) = (SELECT Value FROM Demo.Results WHERE Item = 'CREATE VECTOR INDEX, PREVIEW_FEATURES = OFF'),
            @on  varchar(40) = (SELECT Value FROM Demo.Results WHERE Item = 'CREATE VECTOR INDEX, PREVIEW_FEATURES = ON'),
            @dim varchar(40) = (SELECT Value FROM Demo.Results WHERE Item = 'VECTOR_DISTANCE between vector(3) and vector(2)');

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('F', 'on this build, a vector index needs PREVIEW_FEATURES = ON (error 343 without it)',
     'off: ' + @off + ', on: ' + @on,
     CASE WHEN @off = 'error 343' AND @on = 'ran' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('F', 'vectors of different sizes can''t be compared (error 42204)',
     @dim, CASE WHEN @dim = 'error 42204' THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. EVERY MEASUREMENT ===';
GO
SELECT Scenario, Item, Value FROM Demo.Results ORDER BY Seq;
GO

PRINT '';
PRINT '=== 2. VERDICTS ===';
GO
SELECT Scenario, Claim, Evidence, Verdict FROM Demo.Verdicts ORDER BY Scenario, Seq;
GO

PRINT '';
PRINT '=== 3. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Claim, Evidence, Verdict FROM Demo.Verdicts
WHERE  Verdict IN ('unexpected', 'INCONCLUSIVE', 'SKIPPED') ORDER BY Scenario, Seq;
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 3 should be EMPTY on SQL Server 2025 and';
PRINT ' later. On 2022 and earlier it lists every scenario as';
PRINT ' SKIPPED. Anything else in it is a genuine difference';
PRINT ' on your build, worth reading before you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
