/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  The native json data type and the JSON index, SQL Server 2025, against
  JSON kept in nvarchar(max), the way it has been stored since 2016.

     A  validation: what each type accepts
     B  what json stores: normalised text, size on disk
     C  reading: JSON_VALUE over every row, CPU
     D  indexing: which predicates a JSON index serves, and its size
     E  writing: what the JSON index costs on insert
     F  the json type can't be compared, sorted or grouped

  On SQL Server 2022 and earlier every scenario reports SKIPPED.

  WHAT THIS CHANGES: nothing that stays. Scenarios A and E insert into
  empty tables of their own, roll back, and empty them again.

  TESTED end to end on SQL Server 2025 RTM-CU9-GDR (17.0.5015.4), Linux
  container.
==============================================================================*/

USE JsonDemo;
GO
SET NOCOUNT ON;
GO

TRUNCATE TABLE Demo.Results;
TRUNCATE TABLE Demo.Verdicts;
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) < 17
    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'json: validation',             'needs SQL Server 2025 or later', 'SKIPPED'),
    ('B', 'json: normalisation and size', 'needs SQL Server 2025 or later', 'SKIPPED'),
    ('C', 'json: read CPU',               'needs SQL Server 2025 or later', 'SKIPPED'),
    ('D', 'JSON index: which predicates', 'needs SQL Server 2025 or later', 'SKIPPED'),
    ('E', 'JSON index: write cost',       'needs SQL Server 2025 or later', 'SKIPPED'),
    ('F', 'json: comparisons',            'needs SQL Server 2025 or later', 'SKIPPED');
GO


/*==============================================================================
  A. Validation. Invalid JSON, and a bare string, into each type.
==============================================================================*/
PRINT '=== A. validation ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @eTextBad int, @eJsonBad int, @eJsonScalar int;
    EXEC Demo.usp_Try N'INSERT Demo.ScratchText (OrderID, doc) VALUES (-1, N''{"orderId": 1, "status": '');', @eTextBad OUTPUT;
    EXEC Demo.usp_Try N'INSERT Demo.ScratchJson (OrderID, doc) VALUES (-1, N''{"orderId": 1, "status": '');', @eJsonBad OUTPUT;
    EXEC Demo.usp_Try N'INSERT Demo.ScratchJson (OrderID, doc) VALUES (-1, N''"shipped"'');',                 @eJsonScalar OUTPUT;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('A', 'truncated JSON into nvarchar(max)', CASE @eTextBad    WHEN 0 THEN 'accepted' ELSE 'error ' + CAST(@eTextBad AS varchar(10)) END),
    ('A', 'truncated JSON into json',          CASE @eJsonBad    WHEN 0 THEN 'accepted' ELSE 'error ' + CAST(@eJsonBad AS varchar(10)) END),
    ('A', 'a bare string ("shipped") into json', CASE @eJsonScalar WHEN 0 THEN 'accepted' ELSE 'error ' + CAST(@eJsonScalar AS varchar(10)) END);

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'nvarchar(max) accepts broken JSON; json rejects it (error 13609)',
     'nvarchar(max): ' + CASE @eTextBad WHEN 0 THEN 'accepted' ELSE 'error ' + CAST(@eTextBad AS varchar(10)) END
     + '; json: ' + CASE @eJsonBad WHEN 0 THEN 'accepted' ELSE 'error ' + CAST(@eJsonBad AS varchar(10)) END,
     CASE WHEN @eTextBad = 0 AND @eJsonBad = 13609 THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('A', 'json holds an object or an array, not a bare scalar',
     'a bare string: ' + CASE @eJsonScalar WHEN 0 THEN 'accepted' ELSE 'error ' + CAST(@eJsonScalar AS varchar(10)) END,
     CASE WHEN @eJsonScalar <> 0 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  B. What json stores. A document with extra whitespace and a duplicate key
  goes in; what comes back out?
==============================================================================*/
PRINT '=== B. normalisation and size ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @in nvarchar(200) = N'{ "status" : "held",   "qty": 2, "status": "shipped" }',
            @out nvarchar(200), @textValue nvarchar(20);
    EXEC sys.sp_executesql N'DECLARE @j json = @in; SET @out = CAST(@j AS nvarchar(200));',
         N'@in nvarchar(200), @out nvarchar(200) OUTPUT', @in = @in, @out = @out OUTPUT;
    SET @textValue = JSON_VALUE(@in, '$.status');

    DECLARE @pText bigint = Demo.fn_Pages(N'Demo.OrdersText', NULL),
            @pJson bigint = Demo.fn_Pages(N'Demo.OrdersJson', NULL);

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('B', 'in',                                  @in),
    ('B', 'out of json',                         @out),
    ('B', 'JSON_VALUE(''$.status'') of the nvarchar text', @textValue),
    ('B', 'pages, 200,000 documents in nvarchar(max)', CAST(@pText AS varchar(20))),
    ('B', 'pages, the same documents in json',         CAST(@pJson AS varchar(20)));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('B', 'json doesn''t keep the text: whitespace is removed, a duplicate key is dropped (the first wins)',
     @out, CASE WHEN @out = N'{"status":"held","qty":2}' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('B', 'the binary json format is no bigger than the nvarchar text',
     CAST(@pJson AS varchar(20)) + ' pages against ' + CAST(@pText AS varchar(20)),
     CASE WHEN @pJson <= @pText THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  C. Reading. The same JSON_VALUE filter over every row, nvarchar(max)
  against json, serial so the CPU figures compare. Best of three runs each.
==============================================================================*/
PRINT '=== C. JSON_VALUE over every row ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @i int = 1, @r bigint, @c bigint, @cText bigint = 2147483647, @cJson bigint = 2147483647;
    WHILE @i <= 3
    BEGIN
        EXEC Demo.usp_Measure N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.OrdersText WHERE JSON_VALUE(doc, ''$.status'') = N''held'' OPTION (MAXDOP 1);', @r OUTPUT, @c OUTPUT;
        IF @c < @cText SET @cText = @c;
        EXEC Demo.usp_Measure N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.OrdersJson WHERE JSON_VALUE(doc, ''$.status'') = N''held'' OPTION (MAXDOP 1);', @r OUTPUT, @c OUTPUT;
        IF @c < @cJson SET @cJson = @c;
        SET @i += 1;
    END

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('C', 'CPU ms, nvarchar(max), best of 3', CAST(@cText AS varchar(20))),
    ('C', 'CPU ms, json, best of 3',          CAST(@cJson AS varchar(20)));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('C', 'JSON_VALUE costs less CPU on json: no text to parse on every row',
     'json ' + CAST(@cJson AS varchar(20)) + ' ms, nvarchar(max) ' + CAST(@cText AS varchar(20)) + ' ms',
     CASE WHEN @cText < 50 THEN 'INCONCLUSIVE'
          WHEN @cJson * 10 <= @cText * 9 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  D. Indexing. Find the 200 held orders three ways, on the table with the
  JSON index, and with JSON_VALUE on the pre-2025 computed-column index.
==============================================================================*/
PRINT '=== D. which predicates the JSON index serves ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    -- Each search runs twice and the second run is kept: the first can
    -- include compiling, and creating statistics on the way.
    DECLARE @c bigint, @rValue bigint, @rContains bigint, @rNoIndex bigint, @rComputed bigint, @pass int = 1;
    WHILE @pass <= 2
    BEGIN
        EXEC Demo.usp_Measure N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.OrdersJsonIndex WHERE JSON_VALUE(doc, ''$.status'') = N''held'';',       @rValue OUTPUT, @c OUTPUT;
        EXEC Demo.usp_Measure N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.OrdersJsonIndex WHERE JSON_CONTAINS(doc, N''held'', ''$.status'') = 1;', @rContains OUTPUT, @c OUTPUT;
        EXEC Demo.usp_Measure N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.OrdersJson      WHERE JSON_CONTAINS(doc, N''held'', ''$.status'') = 1;', @rNoIndex OUTPUT, @c OUTPUT;
        EXEC Demo.usp_Measure N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.OrdersComputed  WHERE JSON_VALUE(doc, ''$.status'') = N''held'';',       @rComputed OUTPUT, @c OUTPUT;
    SET @pass += 1;
    END

    DECLARE @pTable bigint = Demo.fn_Pages(N'Demo.OrdersJsonIndex', NULL),
            @pJx    bigint = Demo.fn_Pages(N'Demo.OrdersJsonIndex', N'JX_OrdersJsonIndex_status'),
            @pIx    bigint = Demo.fn_Pages(N'Demo.OrdersComputed', N'IX_OrdersComputed_status');

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('D', 'reads: JSON_VALUE = ''held'', table with JSON index',            CAST(@rValue AS varchar(20))),
    ('D', 'reads: JSON_CONTAINS(..., ''held'', ''$.status''), with JSON index', CAST(@rContains AS varchar(20))),
    ('D', 'reads: the same JSON_CONTAINS, no JSON index',                    CAST(@rNoIndex AS varchar(20))),
    ('D', 'reads: JSON_VALUE = ''held'', nvarchar + computed-column index', CAST(@rComputed AS varchar(20))),
    ('D', 'pages: the table',                                               CAST(@pTable AS varchar(20))),
    ('D', 'pages: JSON index on one path',                                  CAST(@pJx AS varchar(20))),
    ('D', 'pages: computed-column index on the same path',                  CAST(@pIx AS varchar(20)));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('D', 'JSON_CONTAINS uses the JSON index',
     CAST(@rContains AS varchar(20)) + ' reads, against ' + CAST(@rNoIndex AS varchar(20)) + ' without the index',
     CASE WHEN @rContains * 5 <= @rNoIndex THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('D', '... but JSON_VALUE = on the same path ignores it and scans the table',
     CAST(@rValue AS varchar(20)) + ' reads; the table is ' + CAST(@pTable AS varchar(20)) + ' pages',
     CASE WHEN @rValue * 10 >= @pTable * 9 THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('D', 'the pre-2025 computed-column index serves JSON_VALUE = with a seek',
     CAST(@rComputed AS varchar(20)) + ' reads',
     CASE WHEN @rComputed <= 50 THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('D', 'the JSON index on one path is at least twice the size of the computed-column index',
     CAST(@pJx AS varchar(20)) + ' pages against ' + CAST(@pIx AS varchar(20)),
     CASE WHEN @pJx >= 2 * @pIx THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  E. Writing. Log written by inserting 20,000 documents into an empty json
  table without and with the JSON index. Both inserts are rolled back, and
  the tables emptied, so a re-run starts from the same place.
==============================================================================*/
PRINT '=== E. what the JSON index costs on insert ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @lPlain bigint, @lIndexed bigint;
    TRUNCATE TABLE Demo.ScratchJson;
    TRUNCATE TABLE Demo.ScratchJsonIndex;

    BEGIN TRAN;
        INSERT Demo.ScratchJson (OrderID, doc)      SELECT OrderID, doc FROM Demo.OrdersJson WHERE OrderID <= 20000;
        SELECT @lPlain = database_transaction_log_bytes_used FROM sys.dm_tran_database_transactions
        WHERE  database_id = DB_ID() AND transaction_id = CURRENT_TRANSACTION_ID();
    ROLLBACK;

    BEGIN TRAN;
        INSERT Demo.ScratchJsonIndex (OrderID, doc) SELECT OrderID, doc FROM Demo.OrdersJson WHERE OrderID <= 20000;
        SELECT @lIndexed = database_transaction_log_bytes_used FROM sys.dm_tran_database_transactions
        WHERE  database_id = DB_ID() AND transaction_id = CURRENT_TRANSACTION_ID();
    ROLLBACK;

    TRUNCATE TABLE Demo.ScratchJson;
    TRUNCATE TABLE Demo.ScratchJsonIndex;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('E', 'log bytes, 20,000 inserts, no JSON index',   CAST(@lPlain AS varchar(20))),
    ('E', 'log bytes, 20,000 inserts, with JSON index', CAST(@lIndexed AS varchar(20)));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('E', 'a JSON index on one path adds at least 30% to the log an insert writes',
     CAST(@lIndexed AS varchar(20)) + ' bytes against ' + CAST(@lPlain AS varchar(20))
     + ' (+' + CAST(CAST(100.0 * (@lIndexed - @lPlain) / NULLIF(@lPlain, 0) AS int) AS varchar(10)) + '%)',
     CASE WHEN @lIndexed * 10 >= @lPlain * 13 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  F. The json type can't be compared, sorted, grouped or made DISTINCT.
==============================================================================*/
PRINT '=== F. comparisons ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @eEq int, @eOrder int, @eGroup int, @eCast int, @eStr int, @eDistinct int;
    EXEC Demo.usp_Try N'SELECT COUNT(*) FROM Demo.OrdersJson AS a JOIN Demo.OrdersJson AS b ON b.doc = a.doc;', @eEq OUTPUT;
    EXEC Demo.usp_Try N'SELECT TOP (1) OrderID FROM Demo.OrdersJson ORDER BY doc;',                            @eOrder OUTPUT;
    EXEC Demo.usp_Try N'SELECT COUNT(*) FROM Demo.OrdersJson GROUP BY doc;',                                  @eGroup OUTPUT;
    EXEC Demo.usp_Try N'SELECT COUNT(*) FROM Demo.OrdersJson GROUP BY CAST(doc AS nvarchar(max));',           @eCast OUTPUT;
    EXEC Demo.usp_Try N'SELECT COUNT(*) FROM Demo.OrdersJson WHERE doc = N''{"orderId":1}'';',                @eStr OUTPUT;
    EXEC Demo.usp_Try N'SELECT DISTINCT TOP (1) doc FROM Demo.OrdersJson;',                                  @eDistinct OUTPUT;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('F', 'join on doc = doc',               CASE @eEq    WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eEq AS varchar(10)) END),
    ('F', 'ORDER BY doc',                    CASE @eOrder WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eOrder AS varchar(10)) END),
    ('F', 'GROUP BY doc',                    CASE @eGroup WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eGroup AS varchar(10)) END),
    ('F', 'GROUP BY CAST(doc AS nvarchar(max))', CASE @eCast WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eCast AS varchar(10)) END),
    ('F', 'WHERE doc = a string',            CASE @eStr   WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eStr AS varchar(10)) END),
    ('F', 'SELECT DISTINCT doc',             CASE @eDistinct WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eDistinct AS varchar(10)) END);

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('F', 'json can''t be compared, sorted or grouped (error 13636); cast it to text first',
     'join ' + CAST(@eEq AS varchar(10)) + ', ORDER BY ' + CAST(@eOrder AS varchar(10)) + ', GROUP BY ' + CAST(@eGroup AS varchar(10))
     + ', GROUP BY a cast ' + CASE @eCast WHEN 0 THEN 'ran' ELSE CAST(@eCast AS varchar(10)) END,
     CASE WHEN @eEq = 13636 AND @eOrder = 13636 AND @eGroup = 13636 AND @eCast = 0 THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('F', 'comparing json with a string fails (402), and so does SELECT DISTINCT (421)',
     'string ' + CAST(@eStr AS varchar(10)) + ', DISTINCT ' + CAST(@eDistinct AS varchar(10)),
     CASE WHEN @eStr = 402 AND @eDistinct = 421 THEN 'CONFIRMED' ELSE 'unexpected' END);
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
