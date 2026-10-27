/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  SQL Server 2025's regular expression functions (REGEXP_LIKE and family)
  against LIKE, on the same column:

     A  case: REGEXP_LIKE ignores the case-insensitive collation
     B  indexes: which patterns can seek
     C  estimates: what the optimizer guesses for REGEXP_LIKE
     D  CPU: the same search, LIKE against REGEXP_LIKE
     E  the pattern language: what RE2 doesn't support
     F  compatibility level: what needs 170

  On SQL Server 2022 and earlier every scenario reports SKIPPED.

  WHAT THIS CHANGES: only RegexDemo. It clears RegexDemo's plan cache (this
  database's plans only), and scenario F moves its compatibility level to
  160 and back to 170.

  TESTED end to end on SQL Server 2025 RTM-CU9-GDR (17.0.5015.4), Linux
  container.
==============================================================================*/

USE RegexDemo;
GO
SET NOCOUNT ON;
GO

TRUNCATE TABLE Demo.Results;
TRUNCATE TABLE Demo.Verdicts;
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) < 17
    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'REGEXP_LIKE: case',                'needs SQL Server 2025 or later', 'SKIPPED'),
    ('B', 'REGEXP_LIKE: index seeks',         'needs SQL Server 2025 or later', 'SKIPPED'),
    ('C', 'REGEXP_LIKE: estimates',           'needs SQL Server 2025 or later', 'SKIPPED'),
    ('D', 'REGEXP_LIKE: CPU',                 'needs SQL Server 2025 or later', 'SKIPPED'),
    ('E', 'REGEXP_LIKE: the RE2 syntax',      'needs SQL Server 2025 or later', 'SKIPPED'),
    ('F', 'REGEXP_: compatibility level',     'needs SQL Server 2025 or later', 'SKIPPED');
GO

-- The database is created at the server's default level, 170 on 2025.
-- Make sure, in case a previous run stopped in scenario F.
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
    EXEC (N'ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 170;');
GO
ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
GO


/*==============================================================================
  A. Case. The database collation is case-insensitive. Search for codes
  starting with lower-case 'qz'.
==============================================================================*/
PRINT '=== A. case ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @like int, @rx int, @rxi int;
    EXEC sys.sp_executesql N'SELECT @n = COUNT(*) FROM Demo.Codes WHERE Code LIKE ''qz%'';',                     N'@n int OUTPUT', @n = @like OUTPUT;
    EXEC sys.sp_executesql N'SELECT @n = COUNT(*) FROM Demo.Codes WHERE REGEXP_LIKE(Code, ''^qz'');',            N'@n int OUTPUT', @n = @rx OUTPUT;
    EXEC sys.sp_executesql N'SELECT @n = COUNT(*) FROM Demo.Codes WHERE REGEXP_LIKE(Code, ''^qz'', ''i'');',     N'@n int OUTPUT', @n = @rxi OUTPUT;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('A', 'rows: Code LIKE ''qz%''',                   CAST(@like AS varchar(20))),
    ('A', 'rows: REGEXP_LIKE(Code, ''^qz'')',          CAST(@rx AS varchar(20))),
    ('A', 'rows: REGEXP_LIKE(Code, ''^qz'', ''i'')',   CAST(@rxi AS varchar(20)));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'in a case-insensitive database, LIKE ignores case but REGEXP_LIKE doesn''t',
     'LIKE ' + CAST(@like AS varchar(20)) + ' rows, REGEXP_LIKE ' + CAST(@rx AS varchar(20)),
     CASE WHEN @like > 0 AND @rx = 0 THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('A', 'the ''i'' flag makes REGEXP_LIKE match what LIKE matched',
     CAST(@rxi AS varchar(20)) + ' rows',
     CASE WHEN @rxi = @like THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  B. Indexes. The same rows, the codes starting 'QZ-' and a digit, written
  as LIKE and as several regular expressions. Logical reads, warm cache.
==============================================================================*/
PRINT '=== B. which patterns can seek ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @c bigint, @pages bigint, @likePrefix bigint, @rxPrefix bigint,
            @likeClass bigint, @rxDigit bigint, @rxDotStar bigint, @rxVar bigint;
    SELECT @pages = SUM(ps.used_page_count) FROM sys.dm_db_partition_stats AS ps
    JOIN   sys.indexes AS i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
    WHERE  i.name = N'IX_Codes_Code';

    -- Each runs twice; the second run is kept.
    DECLARE @pass int = 1;
    WHILE @pass <= 2
    BEGIN
        EXEC Demo.usp_Measure N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.Codes WHERE Code LIKE ''QZ%'';',                  @likePrefix OUTPUT, @c OUTPUT;
        EXEC Demo.usp_Measure N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.Codes WHERE REGEXP_LIKE(Code, ''^QZ'');',         @rxPrefix OUTPUT, @c OUTPUT;
        EXEC Demo.usp_Measure N'DECLARE @n int; DECLARE @p varchar(20) = ''^QZ''; SELECT @n = COUNT(*) FROM Demo.Codes WHERE REGEXP_LIKE(Code, @p);', @rxVar OUTPUT, @c OUTPUT;
        EXEC Demo.usp_Measure N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.Codes WHERE Code LIKE ''QZ-[0-9]%'';',            @likeClass OUTPUT, @c OUTPUT;
        EXEC Demo.usp_Measure N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.Codes WHERE REGEXP_LIKE(Code, ''^QZ-\d'');',      @rxDigit OUTPUT, @c OUTPUT;
        EXEC Demo.usp_Measure N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.Codes WHERE REGEXP_LIKE(Code, ''^QZ.*'');',       @rxDotStar OUTPUT, @c OUTPUT;
        SET @pass += 1;
    END

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('B', 'pages in IX_Codes_Code',                           CAST(@pages AS varchar(20))),
    ('B', 'reads: Code LIKE ''QZ%''',                          CAST(@likePrefix AS varchar(20))),
    ('B', 'reads: REGEXP_LIKE(Code, ''^QZ'')',                 CAST(@rxPrefix AS varchar(20))),
    ('B', 'reads: REGEXP_LIKE(Code, @p), @p = ''^QZ''',        CAST(@rxVar AS varchar(20))),
    ('B', 'reads: Code LIKE ''QZ-[0-9]%''',                    CAST(@likeClass AS varchar(20))),
    ('B', 'reads: REGEXP_LIKE(Code, ''^QZ-\d'')',              CAST(@rxDigit AS varchar(20))),
    ('B', 'reads: REGEXP_LIKE(Code, ''^QZ.*'')',               CAST(@rxDotStar AS varchar(20)));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('B', 'an anchored literal prefix, ''^QZ'', seeks like LIKE ''QZ%'', even from a variable',
     'REGEXP_LIKE ' + CAST(@rxPrefix AS varchar(20)) + ', from a variable ' + CAST(@rxVar AS varchar(20)) + ', LIKE ' + CAST(@likePrefix AS varchar(20)) + ' reads',
     CASE WHEN @rxPrefix <= 3 * @likePrefix AND @rxVar <= 3 * @likePrefix AND @rxPrefix < 50 THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('B', '... but ''^QZ-\d'' and ''^QZ.*'' read the whole index, where LIKE ''QZ-[0-9]%'' seeks',
     '''^QZ-\d'' ' + CAST(@rxDigit AS varchar(20)) + ', ''^QZ.*'' ' + CAST(@rxDotStar AS varchar(20)) + ', LIKE ' + CAST(@likeClass AS varchar(20)) + ' reads; the index is ' + CAST(@pages AS varchar(20)) + ' pages',
     CASE WHEN @rxDigit * 10 >= @pages * 9 AND @rxDotStar * 10 >= @pages * 9 AND @likeClass < 50 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  C. Estimates. The optimizer's row estimate for the codes starting 'QZ'
  (about 740 rows), written as LIKE and as REGEXP_LIKE.
==============================================================================*/
PRINT '=== C. estimates ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @actual int, @eLike float, @eRx float;
    SELECT @actual = COUNT(*) FROM Demo.Codes WHERE Code LIKE 'QZ%';
    EXEC Demo.usp_Estimate N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.Codes WHERE Code LIKE ''QZ%'' /*est:C1*/;',              N'/*est:C1*/', @eLike OUTPUT;
    EXEC Demo.usp_Estimate N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.Codes WHERE REGEXP_LIKE(Code, ''^QZ'') /*est:C2*/;',     N'/*est:C2*/', @eRx OUTPUT;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('C', 'actual rows',                          CAST(@actual AS varchar(20))),
    ('C', 'estimate: LIKE ''QZ%''',               CAST(CAST(@eLike AS bigint) AS varchar(20))),
    ('C', 'estimate: REGEXP_LIKE(Code, ''^QZ'')', CAST(CAST(@eRx AS bigint) AS varchar(20)));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('C', 'LIKE ''QZ%'' is estimated from the histogram, close to the actual rows',
     'estimate ' + CAST(CAST(@eLike AS bigint) AS varchar(20)) + ', actual ' + CAST(@actual AS varchar(20)),
     CASE WHEN @eLike BETWEEN @actual / 3.0 AND @actual * 3.0 THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('C', 'REGEXP_LIKE gets a fixed guess, here over 10 times the actual rows',
     'estimate ' + CAST(CAST(@eRx AS bigint) AS varchar(20)) + ', actual ' + CAST(@actual AS varchar(20))
     + ' (' + CAST(CAST(100.0 * @eRx / (SELECT COUNT(*) FROM Demo.Codes) AS decimal(5,1)) AS varchar(10)) + '% of the table)',
     CASE WHEN @eRx >= 10 * @actual THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  D. CPU. Find the malformed addresses ('@@' anywhere): a scan either way,
  so the difference is the cost of the test on each row. Serial, best of 3.
==============================================================================*/
PRINT '=== D. CPU ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @i int = 1, @r bigint, @c bigint, @cLike bigint = 2147483647, @cRx bigint = 2147483647, @cValid bigint = 2147483647;
    WHILE @i <= 3
    BEGIN
        EXEC Demo.usp_Measure N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.Codes WHERE Email LIKE ''%@@%'' OPTION (MAXDOP 1);',            @r OUTPUT, @c OUTPUT;
        IF @c < @cLike SET @cLike = @c;
        EXEC Demo.usp_Measure N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.Codes WHERE REGEXP_LIKE(Email, ''@@'') OPTION (MAXDOP 1);',      @r OUTPUT, @c OUTPUT;
        IF @c < @cRx SET @cRx = @c;
        EXEC Demo.usp_Measure N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.Codes WHERE NOT REGEXP_LIKE(Email, ''^[a-z0-9._]+@[a-z0-9-]+(\.[a-z0-9-]+)+$'') OPTION (MAXDOP 1);', @r OUTPUT, @c OUTPUT;
        IF @c < @cValid SET @cValid = @c;
        SET @i += 1;
    END

    DECLARE @nBad int, @nInvalid int;
    SELECT @nBad = COUNT(*) FROM Demo.Codes WHERE Email LIKE '%@@%';
    EXEC sys.sp_executesql N'SELECT @n = COUNT(*) FROM Demo.Codes WHERE NOT REGEXP_LIKE(Email, ''^[a-z0-9._]+@[a-z0-9-]+(\.[a-z0-9-]+)+$'');',
         N'@n int OUTPUT', @n = @nInvalid OUTPUT;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('D', 'CPU ms: Email LIKE ''%@@%''',                 CAST(@cLike AS varchar(20))),
    ('D', 'CPU ms: REGEXP_LIKE(Email, ''@@'')',          CAST(@cRx AS varchar(20))),
    ('D', 'CPU ms: NOT REGEXP_LIKE(Email, <a full address pattern>)', CAST(@cValid AS varchar(20))),
    ('D', 'rows: ''@@'' / failing the address pattern', CAST(@nBad AS varchar(20)) + ' / ' + CAST(@nInvalid AS varchar(20)));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('D', 'for a plain substring, REGEXP_LIKE costs at least 3 times the CPU of LIKE',
     'REGEXP_LIKE ' + CAST(@cRx AS varchar(20)) + ' ms, LIKE ' + CAST(@cLike AS varchar(20)) + ' ms',
     CASE WHEN @cLike < 5 AND @cRx < 50 THEN 'INCONCLUSIVE'
          WHEN @cRx >= 3 * @cLike THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('D', 'one regular expression checks the whole address, and finds the same bad rows',
     CAST(@nInvalid AS varchar(20)) + ' rows fail the pattern, ' + CAST(@nBad AS varchar(20)) + ' contain ''@@''; '
     + CAST(@cValid AS varchar(20)) + ' ms',
     CASE WHEN @nInvalid = @nBad THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  E. The pattern language is RE2. Backreferences and lookarounds, common in
  .NET, Perl and PCRE patterns, are errors.
==============================================================================*/
PRINT '=== E. RE2 ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @eBack int, @eLook int, @eOk int;
    EXEC Demo.usp_Try N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.Codes WHERE REGEXP_LIKE(Code, ''^(.)\1'');',   @eBack OUTPUT;
    EXEC Demo.usp_Try N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.Codes WHERE REGEXP_LIKE(Code, ''^QZ(?=-)'');', @eLook OUTPUT;
    EXEC Demo.usp_Try N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.Codes WHERE REGEXP_LIKE(Code, ''^(QZ|QY)-'');', @eOk OUTPUT;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('E', 'backreference ''^(.)\1''',  CASE @eBack WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eBack AS varchar(10)) END),
    ('E', 'lookahead ''^QZ(?=-)''',    CASE @eLook WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eLook AS varchar(10)) END),
    ('E', 'alternation ''^(QZ|QY)-''', CASE @eOk   WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eOk AS varchar(10)) END);

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('E', 'backreferences and lookaheads are errors (19300); alternation works',
     'backreference ' + CAST(@eBack AS varchar(10)) + ', lookahead ' + CAST(@eLook AS varchar(10)) + ', alternation ' + CASE @eOk WHEN 0 THEN 'ran' ELSE CAST(@eOk AS varchar(10)) END,
     CASE WHEN @eBack = 19300 AND @eLook = 19300 AND @eOk = 0 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  F. Compatibility level. At 160, which REGEXP_ functions still work?
==============================================================================*/
PRINT '=== F. compatibility level ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
    EXEC (N'ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 160;');
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @eLike int, @eReplace int, @eSplit int;
    EXEC Demo.usp_Try N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.Codes WHERE REGEXP_LIKE(Code, ''^QZ'');', @eLike OUTPUT;
    EXEC Demo.usp_Try N'DECLARE @s varchar(20) = REGEXP_REPLACE(''QZ-123'', ''\d+'', ''#'');',                 @eReplace OUTPUT;
    EXEC Demo.usp_Try N'DECLARE @n int; SELECT @n = COUNT(*) FROM REGEXP_SPLIT_TO_TABLE(''a,b,c'', '','');',     @eSplit OUTPUT;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('F', 'level 160: REGEXP_LIKE',           CASE @eLike    WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eLike AS varchar(10)) END),
    ('F', 'level 160: REGEXP_REPLACE',        CASE @eReplace WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eReplace AS varchar(10)) END),
    ('F', 'level 160: REGEXP_SPLIT_TO_TABLE', CASE @eSplit   WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eSplit AS varchar(10)) END);

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('F', 'below level 170, REGEXP_LIKE and the table functions don''t exist; REGEXP_REPLACE does',
     'REGEXP_LIKE ' + CAST(@eLike AS varchar(10)) + ', REGEXP_SPLIT_TO_TABLE ' + CAST(@eSplit AS varchar(10)) + ', REGEXP_REPLACE ' + CASE @eReplace WHEN 0 THEN 'ran' ELSE CAST(@eReplace AS varchar(10)) END,
     CASE WHEN @eLike = 195 AND @eSplit = 208 AND @eReplace = 0 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
    EXEC (N'ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 170;');
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
