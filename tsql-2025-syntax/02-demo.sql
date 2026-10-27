/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  New T-SQL syntax in SQL Server 2025, and the traps in it.

     A  || and NULL: not the same as CONCAT
     B  || converts numbers; + doesn't; || on two numbers doesn't compile
     C  || and + have equal precedence, evaluated left to right
     D  || truncates at 8,000 characters, exactly like +
     E  PRODUCT() against the old EXP(SUM(LOG())) trick
     F  the small ones: CURRENT_DATE, SUBSTRING without a length, DATEADD
        with a bigint, UNISTR and the collation, BASE64_ENCODE
     G  none of it depends on the compatibility level

  Every statement that uses the new syntax runs as dynamic SQL, through
  Demo.usp_Eval, so this file compiles on any version. On SQL Server 2022
  and earlier every scenario reports SKIPPED.

  WHAT THIS CHANGES: only SyntaxDemo. Scenario G sets its compatibility
  level to 160 and back to 170.

  TESTED end to end on SQL Server 2025 RTM-CU9-GDR (17.0.5015.4), Linux
  container.
==============================================================================*/

USE SyntaxDemo;
GO
SET NOCOUNT ON;
GO

TRUNCATE TABLE Demo.Results;
TRUNCATE TABLE Demo.Verdicts;
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) < 17
    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', '|| and NULL',                      'needs SQL Server 2025 or later', 'SKIPPED'),
    ('B', '|| and implicit conversion',       'needs SQL Server 2025 or later', 'SKIPPED'),
    ('C', '|| precedence',                    'needs SQL Server 2025 or later', 'SKIPPED'),
    ('D', '|| truncation',                    'needs SQL Server 2025 or later', 'SKIPPED'),
    ('E', 'PRODUCT()',                        'needs SQL Server 2025 or later', 'SKIPPED'),
    ('F', 'CURRENT_DATE, SUBSTRING, DATEADD, UNISTR, BASE64_ENCODE', 'needs SQL Server 2025 or later', 'SKIPPED'),
    ('G', 'compatibility level',              'needs SQL Server 2025 or later', 'SKIPPED');
GO

-- Start at the 2025 default compatibility level, in case a previous run
-- stopped inside scenario G.
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
    EXEC (N'ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 170;');
GO


/*==============================================================================
  A. || and NULL. CONCAT treats NULL as an empty string; || doesn't.
==============================================================================*/
PRINT '=== A. || and NULL ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @pipe varchar(400), @plus varchar(400), @concat varchar(400), @assign varchar(400);
    EXEC Demo.usp_Eval 'A', '''id='' || @n            (@n int = NULL)',
         N'DECLARE @n int = NULL; SET @v = ''id='' || @n;', @pipe OUTPUT;
    EXEC Demo.usp_Eval 'A', '''id='' + CAST(@n AS varchar(10))',
         N'DECLARE @n int = NULL; SET @v = ''id='' + CAST(@n AS varchar(10));', @plus OUTPUT;
    EXEC Demo.usp_Eval 'A', 'CONCAT(''id='', @n)',
         N'DECLARE @n int = NULL; SET @v = CONCAT(''id='', @n);', @concat OUTPUT;
    EXEC Demo.usp_Eval 'A', '@s = ''x''; SET @s ||= NULL',
         N'DECLARE @s varchar(20) = ''x''; SET @s ||= NULL; SET @v = @s;', @assign OUTPUT;

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', '|| with a NULL returns NULL, like +',
     '|| ' + @pipe + ', + ' + @plus,
     CASE WHEN @pipe = 'NULL' AND @plus = 'NULL' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('A', 'CONCAT with the same NULL returns the rest of the string',
     @concat, CASE WHEN @concat = 'id=' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('A', '||= with a NULL wipes the variable',
     @assign, CASE WHEN @assign = 'NULL' THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  B. Implicit conversion. + between a string and a number converts the
     string to a number; || converts the number to a string.
==============================================================================*/
PRINT '=== B. || and implicit conversion ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @pipe varchar(400), @plus varchar(400), @nums varchar(400), @date varchar(400);
    EXEC Demo.usp_Eval 'B', '''n='' || 5',   N'SET @v = ''n='' || 5;',   @pipe OUTPUT;
    EXEC Demo.usp_Eval 'B', '''n='' + 5',    N'SET @v = ''n='' + 5;',    @plus OUTPUT;
    EXEC Demo.usp_Eval 'B', '1 || 2',        N'SET @v = 1 || 2;',        @nums OUTPUT;
    EXEC Demo.usp_Eval 'B', '''d='' || CAST(''2026-10-29'' AS date)',
         N'SET @v = ''d='' || CAST(''2026-10-29'' AS date);', @date OUTPUT;

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('B', '|| converts the number to a string',
     @pipe, CASE WHEN @pipe = 'n=5' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('B', '+ tries to convert the string to a number: error 245',
     @plus, CASE WHEN @plus = 'error 245' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('B', '|| needs at least one string: two ints raise error 402',
     @nums, CASE WHEN @nums = 'error 402' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('B', '|| converts a date too',
     @date, CASE WHEN @date = 'd=2026-10-29' THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  C. Precedence. || and + have the same precedence and run left to right,
     so where the number sits decides whether the sum happens first.
==============================================================================*/
PRINT '=== C. || precedence ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @strFirst varchar(400), @numFirst varchar(400), @paren varchar(400);
    EXEC Demo.usp_Eval 'C', '''total='' || 1 + 2',   N'SET @v = ''total='' || 1 + 2;',   @strFirst OUTPUT;
    EXEC Demo.usp_Eval 'C', '1 + 2 || '' items''',    N'SET @v = 1 + 2 || '' items'';',    @numFirst OUTPUT;
    EXEC Demo.usp_Eval 'C', '''total='' || (1 + 2)', N'SET @v = ''total='' || (1 + 2);', @paren OUTPUT;

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('C', 'string first: || runs first, then + fails converting ''total=1'' (245)',
     @strFirst, CASE WHEN @strFirst = 'error 245' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('C', 'number first: + runs first, then ||',
     @numFirst, CASE WHEN @numFirst = '3 items' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('C', 'parentheses fix it',
     @paren, CASE WHEN @paren = 'total=3' THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  D. Truncation. A varchar result longer than 8,000 characters is cut at
     8,000, with no warning, unless one side is varchar(max). The same rule
     as +.
==============================================================================*/
PRINT '=== D. || truncation ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @pipe varchar(400), @plus varchar(400), @max varchar(400);
    EXEC Demo.usp_Eval 'D', 'LEN(REPLICATE(''x'', 8000) || ''y'')',
         N'SET @v = LEN(REPLICATE(''x'', 8000) || ''y'');', @pipe OUTPUT;
    EXEC Demo.usp_Eval 'D', 'LEN(REPLICATE(''x'', 8000) + ''y'')',
         N'SET @v = LEN(REPLICATE(''x'', 8000) + ''y'');', @plus OUTPUT;
    EXEC Demo.usp_Eval 'D', 'LEN(REPLICATE(CAST(''x'' AS varchar(max)), 8000) || ''y'')',
         N'SET @v = LEN(REPLICATE(CAST(''x'' AS varchar(max)), 8000) || ''y'');', @max OUTPUT;

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('D', '|| cuts 8,001 characters to 8,000 with no warning, exactly like +',
     '|| ' + @pipe + ', + ' + @plus,
     CASE WHEN @pipe = '8000' AND @plus = '8000' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('D', 'with varchar(max) on one side, nothing is cut',
     @max, CASE WHEN @max = '8001' THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  E. PRODUCT(). Before 2025 the usual way to multiply a column was
     EXP(SUM(LOG(x))): floating point, and LOG fails on zero and negatives.
==============================================================================*/
PRINT '=== E. PRODUCT() ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @p10 varchar(400), @l10 varchar(400), @pZero varchar(400), @lZero varchar(400),
            @pNeg varchar(400), @lNeg varchar(400), @pNull varchar(400), @pEmpty varchar(400),
            @pInt varchar(400), @pBig varchar(400), @pDec varchar(400), @pDecType varchar(400);

    EXEC Demo.usp_Eval 'E', 'PRODUCT of 1..10',
         N'SET @v = (SELECT PRODUCT(x) FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10)) AS t(x));', @p10 OUTPUT;
    EXEC Demo.usp_Eval 'E', 'EXP(SUM(LOG())) of 1..10',
         N'SET @v = CONVERT(varchar(40), (SELECT EXP(SUM(LOG(x))) FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10)) AS t(x)), 3);', @l10 OUTPUT;
    EXEC Demo.usp_Eval 'E', 'PRODUCT of (0, 3)',
         N'SET @v = (SELECT PRODUCT(x) FROM (VALUES (0),(3)) AS t(x));', @pZero OUTPUT;
    EXEC Demo.usp_Eval 'E', 'EXP(SUM(LOG())) of (0, 3)',
         N'SET @v = (SELECT EXP(SUM(LOG(x))) FROM (VALUES (0),(3)) AS t(x));', @lZero OUTPUT;
    EXEC Demo.usp_Eval 'E', 'PRODUCT of (-2, 3)',
         N'SET @v = (SELECT PRODUCT(x) FROM (VALUES (-2),(3)) AS t(x));', @pNeg OUTPUT;
    EXEC Demo.usp_Eval 'E', 'EXP(SUM(LOG())) of (-2, 3)',
         N'SET @v = (SELECT EXP(SUM(LOG(x))) FROM (VALUES (-2),(3)) AS t(x));', @lNeg OUTPUT;
    EXEC Demo.usp_Eval 'E', 'PRODUCT of (2, NULL, 4)',
         N'SET @v = (SELECT PRODUCT(x) FROM (VALUES (2),(NULL),(4)) AS t(x));', @pNull OUTPUT;
    EXEC Demo.usp_Eval 'E', 'PRODUCT over no rows',
         N'SET @v = (SELECT PRODUCT(x) FROM (VALUES (2)) AS t(x) WHERE x > 5);', @pEmpty OUTPUT;
    EXEC Demo.usp_Eval 'E', 'PRODUCT of (100000, 100000), int',
         N'SET @v = (SELECT PRODUCT(x) FROM (VALUES (100000),(100000)) AS t(x));', @pInt OUTPUT;
    EXEC Demo.usp_Eval 'E', 'PRODUCT of (100000, 100000), bigint',
         N'SET @v = (SELECT PRODUCT(CAST(x AS bigint)) FROM (VALUES (100000),(100000)) AS t(x));', @pBig OUTPUT;
    EXEC Demo.usp_Eval 'E', 'PRODUCT of decimal(5,2) 1.10 x 3',
         N'SET @v = (SELECT PRODUCT(x) FROM (VALUES (CAST(1.1 AS decimal(5,2))),(1.1),(1.1)) AS t(x));', @pDec OUTPUT;
    EXEC Demo.usp_Eval 'E', 'type of PRODUCT(decimal(5,2))',
         N'SET @v = (SELECT CAST(SQL_VARIANT_PROPERTY(PRODUCT(x), ''BaseType'') AS varchar(20)) + ''(''
                          + CAST(SQL_VARIANT_PROPERTY(PRODUCT(x), ''Precision'') AS varchar(5)) + '',''
                          + CAST(SQL_VARIANT_PROPERTY(PRODUCT(x), ''Scale'') AS varchar(5)) + '')''
                     FROM (VALUES (CAST(1.1 AS decimal(5,2))),(1.1)) AS t(x));', @pDecType OUTPUT;

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('E', 'PRODUCT is exact; EXP(SUM(LOG())) drifts',
     'PRODUCT ' + @p10 + ', EXP/LOG ' + @l10,
     CASE WHEN @p10 = '3628800' AND @l10 <> '3628800' AND @l10 NOT LIKE 'error%' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('E', 'a zero: PRODUCT returns 0, LOG raises error 3623',
     'PRODUCT ' + @pZero + ', EXP/LOG ' + @lZero,
     CASE WHEN @pZero = '0' AND @lZero = 'error 3623' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('E', 'a negative: PRODUCT keeps the sign, LOG raises error 3623',
     'PRODUCT ' + @pNeg + ', EXP/LOG ' + @lNeg,
     CASE WHEN @pNeg = '-6' AND @lNeg = 'error 3623' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('E', 'PRODUCT ignores NULLs, like SUM',
     @pNull, CASE WHEN @pNull = '8' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('E', 'PRODUCT over no rows returns NULL, not 1',
     @pEmpty, CASE WHEN @pEmpty = 'NULL' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('E', 'PRODUCT of an int column returns int: 10^10 overflows (8115)',
     'int ' + @pInt + ', bigint ' + @pBig,
     CASE WHEN @pInt = 'error 8115' AND @pBig = '10000000000' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('E', 'PRODUCT of a decimal returns decimal(38,6)',
     @pDecType + ', value ' + @pDec,
     CASE WHEN @pDecType = 'decimal(38,6)' AND @pDec = '1.331000' THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  F. The small ones.
==============================================================================*/
PRINT '=== F. CURRENT_DATE, SUBSTRING, DATEADD, UNISTR, BASE64_ENCODE ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @cdType varchar(400), @cdMatch varchar(400), @sub varchar(400), @dateadd varchar(400),
            @uniVar varchar(400), @uniUtf8 varchar(400), @uniN varchar(400),
            @b64Var varchar(400), @b64N varchar(400);

    EXEC Demo.usp_Eval 'F', 'type of CURRENT_DATE',
         N'SET @v = CAST(SQL_VARIANT_PROPERTY(CURRENT_DATE, ''BaseType'') AS varchar(20));', @cdType OUTPUT;
    EXEC Demo.usp_Eval 'F', 'CURRENT_DATE = CAST(GETDATE() AS date)',
         N'SET @v = CASE WHEN CURRENT_DATE = CAST(GETDATE() AS date) THEN ''equal'' ELSE ''different'' END;', @cdMatch OUTPUT;
    EXEC Demo.usp_Eval 'F', 'SUBSTRING(''abcdef'', 3)',
         N'SET @v = SUBSTRING(''abcdef'', 3);', @sub OUTPUT;
    EXEC Demo.usp_Eval 'F', 'DATEADD(second, 3000000000 (bigint), ''2000-01-01'')',
         N'SET @v = CONVERT(varchar(30), DATEADD(second, CAST(3000000000 AS bigint), CAST(''2000-01-01'' AS datetime2(0))), 120);', @dateadd OUTPUT;
    EXEC Demo.usp_Eval 'F', 'UNISTR(''caf\00E9''), varchar, Latin1_General_100_CI_AS',
         N'SET @v = UNISTR(''caf\00E9'' COLLATE Latin1_General_100_CI_AS);', @uniVar OUTPUT;
    EXEC Demo.usp_Eval 'F', 'UNISTR(''caf\00E9''), varchar, Latin1_General_100_CI_AS_SC_UTF8',
         N'SET @v = CASE WHEN UNISTR(''caf\00E9'' COLLATE Latin1_General_100_CI_AS_SC_UTF8) = NCHAR(99)+NCHAR(97)+NCHAR(102)+NCHAR(233)
                         THEN ''caf'' + CHAR(233) ELSE ''wrong'' END;', @uniUtf8 OUTPUT;
    EXEC Demo.usp_Eval 'F', 'UNISTR(N''caf\00E9''), nvarchar',
         N'SET @v = CASE WHEN UNISTR(N''caf\00E9'') = NCHAR(99)+NCHAR(97)+NCHAR(102)+NCHAR(233)
                         THEN ''caf'' + CHAR(233) ELSE ''wrong'' END;', @uniN OUTPUT;
    EXEC Demo.usp_Eval 'F', 'BASE64_ENCODE(CAST(''abc'' AS varbinary(max)))',
         N'SET @v = BASE64_ENCODE(CAST(''abc'' AS varbinary(max)));', @b64Var OUTPUT;
    EXEC Demo.usp_Eval 'F', 'BASE64_ENCODE(CAST(N''abc'' AS varbinary(max)))',
         N'SET @v = BASE64_ENCODE(CAST(N''abc'' AS varbinary(max)));', @b64N OUTPUT;

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('F', 'CURRENT_DATE returns date, not datetime',
     @cdType + ', ' + @cdMatch,
     CASE WHEN @cdType = 'date' AND @cdMatch = 'equal' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('F', 'SUBSTRING no longer needs a length: it reads to the end',
     @sub, CASE WHEN @sub = 'cdef' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('F', 'DATEADD takes a bigint number (2022: error 8115)',
     @dateadd, CASE WHEN @dateadd = '2095-01-24 05:20:00' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('F', 'UNISTR on varchar needs a UTF-8 collation: error 9844 otherwise',
     @uniVar + ' / UTF8 ' + @uniUtf8 + ' / nvarchar ' + @uniN,
     CASE WHEN @uniVar = 'error 9844' AND @uniUtf8 = 'caf' + CHAR(233) AND @uniN = 'caf' + CHAR(233)
          THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('F', 'BASE64_ENCODE encodes bytes: the same text as varchar and nvarchar differs',
     'varchar ' + @b64Var + ', nvarchar ' + @b64N,
     CASE WHEN @b64Var = 'YWJj' AND @b64N = 'YQBiAGMA' THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  G. Compatibility level. Unlike the REGEXP_ functions, none of this needs
     compatibility level 170: it all ran at 160.
==============================================================================*/
PRINT '=== G. compatibility level 160 ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
    EXEC (N'ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 160;');
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @lvl varchar(400), @pipe varchar(400), @prod varchar(400), @cd varchar(400),
            @sub varchar(400), @regex varchar(400);
    SET @lvl = (SELECT CAST(compatibility_level AS varchar(5)) FROM sys.databases WHERE database_id = DB_ID());
    EXEC Demo.usp_Eval 'G', '''a'' || ''b'' at 160',       N'SET @v = ''a'' || ''b'';', @pipe OUTPUT;
    EXEC Demo.usp_Eval 'G', 'PRODUCT at 160',
         N'SET @v = (SELECT PRODUCT(x) FROM (VALUES (2),(3)) AS t(x));', @prod OUTPUT;
    EXEC Demo.usp_Eval 'G', 'CURRENT_DATE at 160',
         N'SET @v = CASE WHEN CURRENT_DATE = CAST(GETDATE() AS date) THEN ''equal'' ELSE ''different'' END;', @cd OUTPUT;
    EXEC Demo.usp_Eval 'G', 'SUBSTRING(''abcdef'', 3) at 160', N'SET @v = SUBSTRING(''abcdef'', 3);', @sub OUTPUT;
    EXEC Demo.usp_Eval 'G', 'REGEXP_LIKE at 160, for contrast',
         N'SET @v = CASE WHEN REGEXP_LIKE(''abc'', ''^a'') THEN ''match'' ELSE ''no match'' END;', @regex OUTPUT;

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('G', '||, PRODUCT, CURRENT_DATE and SUBSTRING work at compatibility level 160',
     'level ' + @lvl + ': ' + @pipe + ', ' + @prod + ', ' + @cd + ', ' + @sub,
     CASE WHEN @lvl = '160' AND @pipe = 'ab' AND @prod = '6' AND @cd = 'equal' AND @sub = 'cdef'
          THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('G', 'REGEXP_LIKE at 160 does not (error 195)',
     @regex, CASE WHEN @regex = 'error 195' THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
    EXEC (N'ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 170;');
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. EVERY ATTEMPT ===';
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
