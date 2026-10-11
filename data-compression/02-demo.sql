/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  The same million rows stored five ways, and what each costs and saves --
  then the cases where compression saves nothing, costs more than it saves,
  or silently doesn't happen. Evidence lands in Demo.Results and
  Demo.Verdicts; the summary at the bottom is the payoff.

  Scenarios
    A  NONE, ROW, PAGE, COLUMNSTORE, ARCHIVE  -> size, and what building it
                                                 cost
    B  sp_estimate_data_compression_savings  -> how close the estimate is
    C  the same report on each copy          -> fewer pages read, more CPU
                                                 per page (rowstore)
    D  random data                           -> PAGE saves almost nothing
    E  updating 300,000 rows                 -> PAGE costs several times the
                                                 CPU, and the table grows
    F  a PAGE-compressed heap                -> ordinary inserts get ROW
                                                 compression only
    G  JSON documents over 8,000 bytes       -> PAGE saves nothing; COMPRESS()
                                                 does

  Every table it measures is built by this file, from Demo.Source.

  Expected runtime: about a minute.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE CompressionDemo;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('Demo.usp_Build') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

DELETE Demo.Results;
IF OBJECT_ID('Demo.Verdicts') IS NOT NULL DROP TABLE Demo.Verdicts;
CREATE TABLE Demo.Verdicts
(
    Scenario  char(1)       NOT NULL,
    Item      varchar(70)   NOT NULL,
    Detail    varchar(300)  NOT NULL,
    Expected  varchar(100)  NOT NULL,
    Verdict   varchar(30)   NOT NULL
);
GO


/*==============================================================================
  A -- five copies of Demo.Source.
==============================================================================*/
PRINT '=== A: one table, five ways ===';
EXEC Demo.usp_Build 'Demo.Orders_None',    'NONE';
EXEC Demo.usp_Build 'Demo.Orders_Row',     'ROW';
EXEC Demo.usp_Build 'Demo.Orders_Page',    'PAGE';
EXEC Demo.usp_Build 'Demo.Orders_CS',      'COLUMNSTORE';
EXEC Demo.usp_Build 'Demo.Orders_Archive', 'COLUMNSTORE_ARCHIVE';
GO


/*==============================================================================
  B -- what sp_estimate_data_compression_savings predicts for the
  uncompressed copy, against what A actually built. The procedure compresses
  a sample of the table in tempdb and scales up.
==============================================================================*/
PRINT '=== B: the estimate ===';
IF OBJECT_ID('tempdb..#est') IS NOT NULL DROP TABLE #est;
CREATE TABLE #est
(
    object_name sysname, schema_name sysname, index_id int, partition_number int,
    size_current_kb bigint, size_requested_kb bigint, sample_current_kb bigint, sample_requested_kb bigint
);
INSERT #est EXEC sys.sp_estimate_data_compression_savings 'Demo', 'Orders_None', NULL, NULL, 'ROW';
INSERT Demo.Results (Scenario, Label, Pages) SELECT 'B', 'ROW estimate', SUM(size_requested_kb) / 8 FROM #est;
TRUNCATE TABLE #est;
INSERT #est EXEC sys.sp_estimate_data_compression_savings 'Demo', 'Orders_None', NULL, NULL, 'PAGE';
INSERT Demo.Results (Scenario, Label, Pages) SELECT 'B', 'PAGE estimate', SUM(size_requested_kb) / 8 FROM #est;
GO


/*==============================================================================
  C -- the same report on each copy. Compressed rowstore pages hold more
  rows, so there are fewer of them to read -- but every row read has to be
  decompressed, which is CPU.
==============================================================================*/
PRINT '=== C: the same report on each copy ===';
EXEC Demo.usp_Scan 'Demo.Orders_None', 'NONE';
EXEC Demo.usp_Scan 'Demo.Orders_Row',  'ROW';
EXEC Demo.usp_Scan 'Demo.Orders_Page', 'PAGE';
EXEC Demo.usp_Scan 'Demo.Orders_CS',   'COLUMNSTORE';
GO


/*==============================================================================
  D -- data with nothing to share: a GUID and 100 random bytes per row.
  No trailing spaces, no small numbers, no repeated prefixes or values for
  the page dictionary to find.
==============================================================================*/
PRINT '=== D: random data ===';
DROP TABLE IF EXISTS Demo.Random;
CREATE TABLE Demo.Random (ID int NOT NULL CONSTRAINT PK_Random PRIMARY KEY, G uniqueidentifier NOT NULL, B varbinary(100) NOT NULL);
INSERT Demo.Random WITH (TABLOCK)
SELECT TOP (300000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), NEWID(), CRYPT_GEN_RANDOM(100)
FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b;

DECLARE @p bigint, @l bigint, @c0 int, @c1 int;
EXEC Demo.usp_Pages 'Demo.Random', @p OUTPUT, @l OUTPUT;
INSERT Demo.Results (Scenario, Label, Pages) VALUES ('D', 'random, NONE', @p);
SELECT @c0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
ALTER INDEX PK_Random ON Demo.Random REBUILD WITH (DATA_COMPRESSION = PAGE, MAXDOP = 1);
SELECT @c1 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
EXEC Demo.usp_Pages 'Demo.Random', @p OUTPUT, @l OUTPUT;
INSERT Demo.Results (Scenario, Label, Pages, CpuMs) VALUES ('D', 'random, PAGE', @p, @c1 - @c0);
GO


/*==============================================================================
  E -- an update touching 300,000 rows, on the uncompressed copy and the
  PAGE copy. Every changed row on a PAGE-compressed page has to be
  re-encoded, and a value that no longer fits the page's dictionary makes
  the row bigger.
==============================================================================*/
PRINT '=== E: updating compressed rows ===';
DECLARE @c0 int, @c1 int, @p bigint, @l bigint;
EXEC Demo.usp_Pages 'Demo.Orders_Page', @p OUTPUT, @l OUTPUT;
INSERT Demo.Results (Scenario, Label, Pages) VALUES ('E', 'PAGE, before the update', @p);

SELECT @c0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
UPDATE Demo.Orders_None SET Amount = Amount + 0.01 WHERE OrderID <= 300000 OPTION (MAXDOP 1);
SELECT @c1 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
INSERT Demo.Results (Scenario, Label, CpuMs) VALUES ('E', 'NONE, update', @c1 - @c0);

SELECT @c0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
UPDATE Demo.Orders_Page SET Amount = Amount + 0.01 WHERE OrderID <= 300000 OPTION (MAXDOP 1);
SELECT @c1 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
EXEC Demo.usp_Pages 'Demo.Orders_Page', @p OUTPUT, @l OUTPUT;
INSERT Demo.Results (Scenario, Label, Pages, CpuMs) VALUES ('E', 'PAGE, update', @p, @c1 - @c0);
GO


/*==============================================================================
  F -- a heap declared WITH (DATA_COMPRESSION = PAGE), loaded three ways
  with the same 200,000 rows: ordinary INSERTs, one INSERT ... WITH
  (TABLOCK), and ordinary INSERTs followed by a rebuild.
==============================================================================*/
PRINT '=== F: a PAGE-compressed heap ===';
DROP TABLE IF EXISTS Demo.Heap;
CREATE TABLE Demo.Heap
(
    OrderID int NOT NULL, OrderDate datetime2(0) NOT NULL, CustomerID int NOT NULL, Country varchar(30) NOT NULL,
    Status char(12) NOT NULL, Amount decimal(19,4) NOT NULL, Quantity int NOT NULL, Note char(60) NOT NULL
) WITH (DATA_COMPRESSION = PAGE);

DECLARE @i int = 0, @p bigint, @l bigint;
-- How an application fills it: a thousand rows at a time.
WHILE @i < 200
BEGIN
    INSERT Demo.Heap SELECT * FROM Demo.Source WHERE OrderID BETWEEN @i * 1000 + 1 AND @i * 1000 + 1000;
    SET @i += 1;
END
EXEC Demo.usp_Pages 'Demo.Heap', @p OUTPUT, @l OUTPUT;
INSERT Demo.Results (Scenario, Label, Pages) VALUES ('F', 'heap, ordinary INSERTs', @p);

ALTER TABLE Demo.Heap REBUILD;
EXEC Demo.usp_Pages 'Demo.Heap', @p OUTPUT, @l OUTPUT;
INSERT Demo.Results (Scenario, Label, Pages) VALUES ('F', 'heap, then rebuilt', @p);

TRUNCATE TABLE Demo.Heap;
INSERT Demo.Heap WITH (TABLOCK) SELECT * FROM Demo.Source WHERE OrderID <= 200000;
EXEC Demo.usp_Pages 'Demo.Heap', @p OUTPUT, @l OUTPUT;
INSERT Demo.Results (Scenario, Label, Pages) VALUES ('F', 'heap, INSERT WITH (TABLOCK)', @p);

-- For comparison: the same 200,000 rows as a ROW-compressed heap.
DROP TABLE IF EXISTS Demo.HeapRow;
SELECT * INTO Demo.HeapRow FROM Demo.Source WHERE 1 = 0;
ALTER TABLE Demo.HeapRow REBUILD WITH (DATA_COMPRESSION = ROW);
INSERT Demo.HeapRow WITH (TABLOCK) SELECT * FROM Demo.Source WHERE OrderID <= 200000;
EXEC Demo.usp_Pages 'Demo.HeapRow', @p OUTPUT, @l OUTPUT;
INSERT Demo.Results (Scenario, Label, Pages) VALUES ('F', 'for comparison: ROW heap', @p);
GO


/*==============================================================================
  G -- 5,000 JSON documents of about 23 KB each (60 orders apiece), too big
  to stay in the row: they live on LOB pages, which ROW and PAGE
  compression never touch. COMPRESS() gzips a value into varbinary(max);
  DECOMPRESS() undoes it.
==============================================================================*/
PRINT '=== G: big documents ===';
DROP TABLE IF EXISTS Demo.Docs_None, Demo.Docs_Page, Demo.Docs_Gzip;
CREATE TABLE Demo.Docs_None (ID int NOT NULL CONSTRAINT PK_Docs_None PRIMARY KEY, Doc nvarchar(max) NOT NULL);
CREATE TABLE Demo.Docs_Page (ID int NOT NULL CONSTRAINT PK_Docs_Page PRIMARY KEY, Doc nvarchar(max) NOT NULL) WITH (DATA_COMPRESSION = PAGE);
CREATE TABLE Demo.Docs_Gzip (ID int NOT NULL CONSTRAINT PK_Docs_Gzip PRIMARY KEY, Doc varbinary(max) NOT NULL);

DECLARE @doc nvarchar(max) =
    (SELECT TOP (60) OrderID, OrderDate, CustomerID, Country, Status, Amount, Note
     FROM Demo.Source ORDER BY OrderID FOR JSON PATH);
INSERT Demo.Docs_None (ID, Doc)
SELECT TOP (5000) n, STUFF(@doc, 1, 1, CONCAT('[{"Batch":', n, '},'))
FROM  (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b) AS v;
INSERT Demo.Docs_Page (ID, Doc) SELECT ID, Doc FROM Demo.Docs_None;
ALTER TABLE Demo.Docs_Page REBUILD WITH (DATA_COMPRESSION = PAGE);
INSERT Demo.Docs_Gzip (ID, Doc) SELECT ID, COMPRESS(Doc) FROM Demo.Docs_None;

DECLARE @p bigint, @l bigint, @bytes bigint = (SELECT AVG(DATALENGTH(Doc)) FROM Demo.Docs_None);
EXEC Demo.usp_Pages 'Demo.Docs_None', @p OUTPUT, @l OUTPUT;
INSERT Demo.Results (Scenario, Label, Pages, LobPages, Note) VALUES ('G', 'documents, NONE', @p, @l, CONCAT(@bytes, ' bytes each'));
EXEC Demo.usp_Pages 'Demo.Docs_Page', @p OUTPUT, @l OUTPUT;
INSERT Demo.Results (Scenario, Label, Pages, LobPages) VALUES ('G', 'documents, PAGE', @p, @l);
SET @bytes = (SELECT AVG(DATALENGTH(Doc)) FROM Demo.Docs_Gzip);
EXEC Demo.usp_Pages 'Demo.Docs_Gzip', @p OUTPUT, @l OUTPUT;
INSERT Demo.Results (Scenario, Label, Pages, LobPages, Note) VALUES ('G', 'documents, COMPRESS()', @p, @l, CONCAT(@bytes, ' bytes each'));

-- And it comes back intact.
DECLARE @same int = (SELECT COUNT(*) FROM Demo.Docs_None AS n JOIN Demo.Docs_Gzip AS g ON g.ID = n.ID
                     WHERE CAST(DECOMPRESS(g.Doc) AS nvarchar(max)) = n.Doc);
INSERT Demo.Results (Scenario, Label, Note) VALUES ('G', 'DECOMPRESS() round trip', CONCAT(@same, ' of 5000 identical'));
GO


/*==============================================================================
  Verdicts
==============================================================================*/
DECLARE @d varchar(300);
DECLARE @none bigint, @row bigint, @page bigint, @cs bigint, @arch bigint, @eRow bigint, @ePage bigint;
SELECT @none = MAX(CASE WHEN Label = 'NONE' THEN Pages END), @row = MAX(CASE WHEN Label = 'ROW' THEN Pages END),
       @page = MAX(CASE WHEN Label = 'PAGE' THEN Pages END), @cs = MAX(CASE WHEN Label = 'COLUMNSTORE' THEN Pages END),
       @arch = MAX(CASE WHEN Label = 'COLUMNSTORE_ARCHIVE' THEN Pages END)
FROM   Demo.Results WHERE Scenario = 'A';
SELECT @eRow = MAX(CASE WHEN Label = 'ROW estimate' THEN Pages END), @ePage = MAX(CASE WHEN Label = 'PAGE estimate' THEN Pages END)
FROM   Demo.Results WHERE Scenario = 'B';

-- A
SET @d = CONCAT('pages: NONE ', @none, ', ROW ', @row, ', PAGE ', @page, ', COLUMNSTORE ', @cs, ', ARCHIVE ', @arch);
INSERT Demo.Verdicts VALUES ('A', 'each step smaller than the last', @d, 'NONE > ROW > PAGE > COLUMNSTORE > ARCHIVE',
    CASE WHEN @none > @row AND @row > @page AND @page > @cs AND @cs > @arch AND @page * 3 < @none THEN 'SMALLER' ELSE 'unexpected' END);

-- B
SET @d = CONCAT('ROW: estimated ', @eRow, ' pages, built ', @row, '; PAGE: estimated ', @ePage, ', built ', @page);
INSERT Demo.Verdicts VALUES ('B', 'the estimate is close for repetitive data', @d, 'both within 15%',
    CASE WHEN ABS(@eRow - @row) <= @row * 0.15 AND ABS(@ePage - @page) <= @page * 0.15 THEN 'CLOSE' ELSE 'unexpected' END);

-- C
DECLARE @rN bigint, @rP bigint, @rC bigint, @cN decimal(12,1), @cP decimal(12,1), @cC decimal(12,1);
SELECT @rN = MAX(CASE WHEN Label = 'NONE' THEN Reads END), @cN = MAX(CASE WHEN Label = 'NONE' THEN CpuMs END),
       @rP = MAX(CASE WHEN Label = 'PAGE' THEN Reads END), @cP = MAX(CASE WHEN Label = 'PAGE' THEN CpuMs END),
       @rC = MAX(CASE WHEN Label = 'COLUMNSTORE' THEN Reads END), @cC = MAX(CASE WHEN Label = 'COLUMNSTORE' THEN CpuMs END)
FROM   Demo.Results WHERE Scenario = 'C';
SET @d = CONCAT('per scan: NONE ', @rN, ' reads, ', @cN, ' ms CPU; PAGE ', @rP, ' reads, ', @cP, ' ms CPU');
INSERT Demo.Verdicts VALUES ('C', 'PAGE: fewer reads, more CPU', @d, 'PAGE reads < 1/3; PAGE CPU higher',
    CASE WHEN @rP * 3 < @rN AND @cP > @cN THEN 'TRADE' ELSE 'unexpected' END);
SET @d = CONCAT('per scan: COLUMNSTORE ', @rC, ' reads, ', @cC, ' ms CPU');
INSERT Demo.Verdicts VALUES ('C', 'columnstore: fewer reads and less CPU', @d, 'reads and CPU below PAGE',
    CASE WHEN @rC < @rP AND @cC < @cP THEN 'BOTH LOWER' ELSE 'unexpected' END);

-- D
DECLARE @dN bigint, @dP bigint;
SELECT @dN = MAX(CASE WHEN Label = 'random, NONE' THEN Pages END), @dP = MAX(CASE WHEN Label = 'random, PAGE' THEN Pages END)
FROM   Demo.Results WHERE Scenario = 'D';
SET @d = CONCAT('pages: NONE ', @dN, ', PAGE ', @dP, ' (', CAST(100.0 * (@dN - @dP) / @dN AS decimal(5,1)), '% saved)');
INSERT Demo.Verdicts VALUES ('D', 'random data barely compresses', @d, 'under 10% saved',
    CASE WHEN @dP > @dN * 0.9 THEN 'LITTLE SAVED' ELSE 'unexpected' END);

-- E
DECLARE @uN decimal(12,1), @uP decimal(12,1), @pBefore bigint, @pAfter bigint;
SELECT @uN = MAX(CASE WHEN Label = 'NONE, update' THEN CpuMs END), @uP = MAX(CASE WHEN Label = 'PAGE, update' THEN CpuMs END),
       @pBefore = MAX(CASE WHEN Label = 'PAGE, before the update' THEN Pages END),
       @pAfter = MAX(CASE WHEN Label = 'PAGE, update' THEN Pages END)
FROM   Demo.Results WHERE Scenario = 'E';
SET @d = CONCAT('CPU for 300,000 updates: NONE ', @uN, ' ms, PAGE ', @uP, ' ms; PAGE table ', @pBefore, ' -> ', @pAfter, ' pages');
INSERT Demo.Verdicts VALUES ('E', 'updates cost more on PAGE', @d, 'PAGE CPU > 2x NONE',
    CASE WHEN @uP > 2 * @uN THEN 'COSTLIER' ELSE 'unexpected' END);

-- F
DECLARE @hPlain bigint, @hRebuilt bigint, @hTab bigint, @hRow bigint;
SELECT @hPlain = MAX(CASE WHEN Label = 'heap, ordinary INSERTs' THEN Pages END),
       @hRebuilt = MAX(CASE WHEN Label = 'heap, then rebuilt' THEN Pages END),
       @hTab = MAX(CASE WHEN Label = 'heap, INSERT WITH (TABLOCK)' THEN Pages END),
       @hRow = MAX(CASE WHEN Label = 'for comparison: ROW heap' THEN Pages END)
FROM   Demo.Results WHERE Scenario = 'F';
SET @d = CONCAT('pages: ordinary INSERTs ', @hPlain, ' (a ROW heap: ', @hRow, '); rebuilt ', @hRebuilt, '; WITH (TABLOCK) ', @hTab);
INSERT Demo.Verdicts VALUES ('F', 'a PAGE heap gets ROW from ordinary inserts', @d, 'ordinary ~ ROW size; rebuild and TABLOCK ~ half',
    CASE WHEN ABS(@hPlain - @hRow) <= @hRow * 0.1 AND @hRebuilt * 1.8 < @hPlain AND @hTab * 1.8 < @hPlain THEN 'NOT PAGE' ELSE 'unexpected' END);

-- G
DECLARE @gN bigint, @gP bigint, @gZ bigint, @gNote varchar(200);
SELECT @gN = MAX(CASE WHEN Label = 'documents, NONE' THEN Pages END), @gP = MAX(CASE WHEN Label = 'documents, PAGE' THEN Pages END),
       @gZ = MAX(CASE WHEN Label = 'documents, COMPRESS()' THEN Pages END),
       @gNote = MAX(CASE WHEN Label = 'DECOMPRESS() round trip' THEN Note END)
FROM   Demo.Results WHERE Scenario = 'G';
SET @d = CONCAT('pages: NONE ', @gN, ', PAGE ', @gP, ', COMPRESS() ', @gZ, '; round trip ', @gNote);
INSERT Demo.Verdicts VALUES ('G', 'off-row documents: PAGE nothing, COMPRESS() a lot', @d, 'PAGE within 2%; COMPRESS() < 20%; intact',
    CASE WHEN @gP >= @gN * 0.98 AND @gZ < @gN * 0.2 AND @gNote = '5000 of 5000 identical' THEN 'ONLY COMPRESS()' ELSE 'unexpected' END);
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. EVERY MEASUREMENT ===';
GO
SELECT Scenario, Label, Pages, MB = CAST(Pages * 8 / 1024.0 AS decimal(10,1)), LobPages, Reads, CpuMs, Note
FROM   Demo.Results
ORDER BY Scenario, CapturedAt;
GO

PRINT '';
PRINT '=== 2. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario, Item;
GO

PRINT '';
PRINT '=== 3. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Detail, Verdict FROM Demo.Verdicts WHERE Verdict IN ('unexpected', 'INCONCLUSIVE');
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
