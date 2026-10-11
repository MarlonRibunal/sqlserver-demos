/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  Nine ways a data type gives a wrong answer without an error -- or an error
  nobody planned for -- each shown next to the answer that was wanted and
  the way to get it. Every row of the summary is a value SQL Server actually
  returned.

  Scenarios
    A  integer arithmetic        -> 1/3 is 0, and AVG of ints is an int
    B  float                     -> a million 0.10s don't add up to 100,000.00
    C  decimal * decimal         -> digits silently dropped when precision
                                    runs out
    D  money / money             -> four decimal places, every step
    E  strings                   -> varchar with no length is one character;
                                    CAST to varchar is 30; no N, no Unicode
    F  datetime                  -> .999 rounds to the next day; BETWEEN
                                    with a date misses most of the last day
    G  date literals             -> '2025-02-01' is the 2nd of January in
                                    British English
    H  trailing spaces           -> 'ABC' and 'ABC  ' are the same key
    I  identity                  -> an int runs out at 2,147,483,647

  Expected runtime: a few seconds.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE TypeTrapsDemo;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('Demo.Results') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

DELETE Demo.Results;
DELETE Demo.Codes;
DELETE Demo.VarCodes;
TRUNCATE TABLE Demo.Tickets;          -- also puts the identity back to its seed
GO


/*==============================================================================
  A -- integer arithmetic. int / int is int: the fraction is thrown away,
  not rounded. AVG over an int column returns an int too.
==============================================================================*/
PRINT '=== A: integer arithmetic ===';
INSERT Demo.Results VALUES ('A', '1 / 3', CAST(1 / 3 AS nvarchar(40)), N'0.333...', NULL);
INSERT Demo.Results VALUES ('A', '7 / 2', CAST(7 / 2 AS nvarchar(40)), N'3.5', NULL);
INSERT Demo.Results
SELECT 'A', 'AVG(Stars) for product 1 (5, 4, 4)', CAST(AVG(Stars) AS nvarchar(40)), N'4.33', NULL
FROM   Demo.Ratings WHERE ProductID = 1;
INSERT Demo.Results
SELECT 'A', 'fix: AVG(Stars * 1.0)', CAST(CAST(AVG(Stars * 1.0) AS decimal(9,2)) AS nvarchar(40)), N'4.33', NULL
FROM   Demo.Ratings WHERE ProductID = 1;
GO


/*==============================================================================
  B -- float. 0.1 has no exact binary representation; every float 0.1 is a
  tiny bit off, and a million of them add up to a visible difference.
  Equality between floats is a coin toss.
==============================================================================*/
PRINT '=== B: float ===';
INSERT Demo.Results
SELECT 'B', 'SUM of a million float 0.1s', CONVERT(nvarchar(40), SUM(AmountFloat), 3), N'100000', NULL
FROM   Demo.Payments;
INSERT Demo.Results
SELECT 'B', 'fix: SUM of a million decimal(12,2) 0.10s', CAST(SUM(AmountDec) AS nvarchar(40)), N'100000.00', NULL
FROM   Demo.Payments;
DECLARE @a float = 0.1, @b float = 0.2;
INSERT Demo.Results VALUES ('B', 'float: 0.1 + 0.2 = 0.3 ?', CASE WHEN @a + @b = 0.3 THEN N'true' ELSE N'false' END, N'true', NULL);
DECLARE @da decimal(9,2) = 0.1, @db decimal(9,2) = 0.2;
INSERT Demo.Results VALUES ('B', 'fix: decimal: 0.1 + 0.2 = 0.3 ?', CASE WHEN @da + @db = 0.3 THEN N'true' ELSE N'false' END, N'true', NULL);
GO


/*==============================================================================
  C -- decimal multiplication. The result of decimal(p1,s1) * decimal(p2,s2)
  needs precision p1 + p2 + 1. Past 38 there's no room, so SQL Server
  keeps the integer digits and cuts the scale -- down to 6 -- rounding away
  whatever doesn't fit, without a warning.
==============================================================================*/
PRINT '=== C: decimal * decimal ===';
DECLARE @amount decimal(38,18) = 1000000, @rate decimal(38,18) = 1.123456789012345678;
INSERT Demo.Results VALUES ('C', 'decimal(38,18) * decimal(38,18)', CAST(@amount * @rate AS nvarchar(60)), N'1123456.789012345678', NULL);
INSERT Demo.Results VALUES ('C', '... its type', CONCAT(N'decimal(', CAST(SQL_VARIANT_PROPERTY(@amount * @rate, 'Precision') AS nvarchar(5)), N',',
                            CAST(SQL_VARIANT_PROPERTY(@amount * @rate, 'Scale') AS nvarchar(5)), N')'), N'enough scale for the rate', NULL);
DECLARE @amount2 decimal(18,2) = 1000000, @rate2 decimal(19,18) = 1.123456789012345678;
-- (18 + 19 + 1 = 38: the result fits whole, as decimal(38,20).)
INSERT Demo.Results VALUES ('C', 'fix: decimal(18,2) * decimal(19,18)', CAST(CAST(@amount2 * @rate2 AS decimal(38,18)) AS nvarchar(60)), N'1123456.789012345678000000', NULL);
GO


/*==============================================================================
  D -- money. Every money result has exactly four decimal places, including
  the intermediate result of a division. And converting money to a string
  by default shows two.
==============================================================================*/
PRINT '=== D: money ===';
DECLARE @m money = 100, @three money = 3;
-- CONVERT style 2: all four decimal places.
INSERT Demo.Results VALUES ('D', 'money: 100 / 3 * 3', CONVERT(nvarchar(40), @m / @three * @three, 2), N'100.0000', NULL);
-- And the default conversion to a string rounds money to two places --
-- which hides exactly this.
INSERT Demo.Results VALUES ('D', '... the same value through CAST(... AS nvarchar)', CAST(@m / @three * @three AS nvarchar(40)), N'99.9999', NULL);
DECLARE @dm decimal(19,4) = 100, @d3 decimal(19,4) = 3;
INSERT Demo.Results VALUES ('D', 'fix: decimal(19,4), rounded at the end', CAST(CAST(ROUND(@dm / @d3 * @d3, 2) AS decimal(19,2)) AS nvarchar(40)), N'100.00', NULL);
GO


/*==============================================================================
  E -- strings. A varchar declared without a length is varchar(1) as a
  variable and varchar(30) in CAST, and both truncate without an error.
  A string literal without N is varchar, in the database's code page:
  characters it doesn't have become '?' before they ever reach an nvarchar
  column.
==============================================================================*/
PRINT '=== E: strings ===';
DECLARE @s varchar = 'Hello, world';
INSERT Demo.Results VALUES ('E', 'DECLARE @s varchar = ''Hello, world''', @s, N'Hello, world', NULL);
INSERT Demo.Results VALUES ('E', 'LEN(CAST(<40 characters> AS varchar))', CAST(LEN(CAST(REPLICATE('x', 40) AS varchar)) AS nvarchar(10)), N'40', NULL);
-- 東京 (Tokyo), built from its code points so this file's own encoding
-- can't get in the way. A literal written without N -- '東京' -- is a
-- varchar in the database's code page; CAST(... AS varchar) is that same
-- conversion, spelled out.
DECLARE @tokyo nvarchar(20) = NCHAR(26481) + NCHAR(20140);
DECLARE @nv nvarchar(20) = CAST(@tokyo AS varchar(20));
INSERT Demo.Results VALUES ('E', N'nvarchar variable = ''' + @tokyo + N''' (no N)', @nv, @tokyo, NULL);
DECLARE @nv2 nvarchar(20) = @tokyo;
INSERT Demo.Results VALUES ('E', N'fix: nvarchar variable = N''' + @tokyo + N'''', @nv2, @tokyo, NULL);
INSERT Demo.Results VALUES ('E', '... the database''s collation', CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS nvarchar(100)), NULL, NULL);
GO


/*==============================================================================
  F -- datetime. It stores time in steps of 1/300 s (.000, .003, .007), so
  '23:59:59.999' rounds UP, to midnight of the next day. And a date with no
  time means midnight: "BETWEEN '2025-01-01' AND '2025-01-31'" stops at the
  first moment of the 31st.
  Demo.Events has one event a minute on 31 January (1,440) and 60 more on
  1 February.
==============================================================================*/
PRINT '=== F: datetime ===';
INSERT Demo.Results VALUES ('F', 'CAST(''2025-01-31 23:59:59.999'' AS datetime)',
    CONVERT(nvarchar(30), CAST('2025-01-31 23:59:59.999' AS datetime), 121), N'2025-01-31 23:59:59.999', NULL);
INSERT Demo.Results
SELECT 'F', 'January events, BETWEEN ''20250101'' AND ''20250131 23:59:59.999''', CAST(COUNT(*) AS nvarchar(10)), N'1440', NULL
FROM   Demo.Events WHERE At BETWEEN '20250101' AND '20250131 23:59:59.999';
INSERT Demo.Results
SELECT 'F', 'January events, BETWEEN ''20250101'' AND ''20250131''', CAST(COUNT(*) AS nvarchar(10)), N'1440', NULL
FROM   Demo.Events WHERE At BETWEEN '20250101' AND '20250131';
INSERT Demo.Results
SELECT 'F', 'fix: At >= ''20250101'' AND At < ''20250201''', CAST(COUNT(*) AS nvarchar(10)), N'1440', NULL
FROM   Demo.Events WHERE At >= '20250101' AND At < '20250201';
GO


/*==============================================================================
  G -- date literals. 'YYYY-MM-DD' looks unambiguous, but converted to
  datetime it is read according to the session's language: in British
  English (day-month order) it's YYYY-DD-MM. date and datetime2 always read
  it as ISO; 'YYYYMMDD', with no separators, is safe for every type.

  The language is set inside one dynamic batch, and reverts when it ends.
==============================================================================*/
PRINT '=== G: date literals ===';
DECLARE @dt datetime, @d date, @dtSafe datetime, @lang nvarchar(60);
EXEC sys.sp_executesql
     N'SET LANGUAGE British;
       SELECT @dt = CAST(''2025-02-01'' AS datetime), @d = CAST(''2025-02-01'' AS date),
              @dtSafe = CAST(''20250201'' AS datetime), @lang = @@LANGUAGE;',
     N'@dt datetime OUTPUT, @d date OUTPUT, @dtSafe datetime OUTPUT, @lang nvarchar(60) OUTPUT',
     @dt = @dt OUTPUT, @d = @d OUTPUT, @dtSafe = @dtSafe OUTPUT, @lang = @lang OUTPUT;
INSERT Demo.Results VALUES ('G', CONCAT('in ', @lang, ': CAST(''2025-02-01'' AS datetime)'), CONVERT(nvarchar(30), @dt, 106), N'01 Feb 2025', NULL);
INSERT Demo.Results VALUES ('G', 'fix: CAST(''2025-02-01'' AS date)', CONVERT(nvarchar(30), @d, 106), N'01 Feb 2025', NULL);
INSERT Demo.Results VALUES ('G', 'fix: CAST(''20250201'' AS datetime)', CONVERT(nvarchar(30), @dtSafe, 106), N'01 Feb 2025', NULL);
INSERT Demo.Results VALUES ('G', '... and this session''s language afterwards', @@LANGUAGE, NULL, NULL);
GO


/*==============================================================================
  H -- trailing spaces. Comparisons ignore them (ANSI padding), for char
  AND varchar, so 'ABC' and 'ABC  ' are the same value to a unique key --
  while LEN ignores them and DATALENGTH doesn't.
==============================================================================*/
PRINT '=== H: trailing spaces ===';
DECLARE @err int;
INSERT Demo.VarCodes (Code, Note) VALUES ('ABC', 'first');
BEGIN TRY
    INSERT Demo.VarCodes (Code, Note) VALUES ('ABC  ', 'second, two trailing spaces');
    SET @err = 0;
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
END CATCH
INSERT Demo.Results VALUES ('H', 'varchar(10) UNIQUE: insert ''ABC'', then ''ABC  ''', CONCAT(N'error ', @err), N'two distinct codes', NULL);
INSERT Demo.Results VALUES ('H', '''ABC'' = ''ABC  ''', CASE WHEN 'ABC' = 'ABC  ' THEN N'true' ELSE N'false' END, N'false', NULL);
INSERT Demo.Results VALUES ('H', 'LEN(''ABC  ''), DATALENGTH(''ABC  '')', CONCAT(LEN('ABC  '), N', ', DATALENGTH('ABC  ')), N'5, 5', NULL);
GO


/*==============================================================================
  I -- identity. An int identity stops at 2,147,483,647; the next insert
  fails. Demo.Tickets starts three values short of the end. (A heavy
  insert-and-delete workload gets there faster than the row count suggests:
  identity values are never reused, and failed or rolled-back inserts burn
  them too.)
==============================================================================*/
PRINT '=== I: identity ===';
DECLARE @i int = 1, @ok int = 0, @err int = 0, @msg nvarchar(200);
WHILE @i <= 4
BEGIN
    BEGIN TRY
        INSERT Demo.Tickets (Note) VALUES (CONCAT('ticket ', @i));
        SET @ok += 1;
    END TRY
    BEGIN CATCH
        SELECT @err = ERROR_NUMBER(), @msg = ERROR_MESSAGE();
    END CATCH
    SET @i += 1;
END
INSERT Demo.Results VALUES ('I', 'insert 4 tickets, int identity seeded at 2147483645',
    CONCAT(@ok, N' inserted; then error ', @err, N': ', @msg), N'4 inserted', NULL);
INSERT Demo.Results
SELECT 'I', 'the last TicketID', CAST(MAX(TicketID) AS nvarchar(20)), NULL, NULL FROM Demo.Tickets;
GO


/*==============================================================================
  Verdicts: every row predicted to be a trap must have come out wrong, and
  every fix right.
==============================================================================*/
UPDATE Demo.Results
SET    Verdict = CASE
         -- informational rows
         WHEN Wanted IS NULL THEN 'info'
         -- the fixes: got what was wanted
         WHEN Item LIKE 'fix:%' THEN CASE WHEN Got = Wanted THEN 'FIXED' ELSE 'unexpected' END
         -- C's type row: scale 6 is the trap
         WHEN Item = '... its type' THEN CASE WHEN Got = N'decimal(38,6)' THEN 'TRAP' ELSE 'unexpected' END
         -- E's no-N row: a database whose collation has the characters (a
         -- UTF-8 or Japanese collation) won't show the trap
         WHEN Scenario = 'E' AND Item LIKE N'nvarchar variable%' THEN
              CASE WHEN Got <> Wanted THEN 'TRAP'
                   WHEN CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS nvarchar(100)) LIKE N'%UTF8%' THEN 'INCONCLUSIVE'
                   ELSE 'unexpected' END
         -- everything else is a trap: it must NOT be what was wanted
         ELSE CASE WHEN Got <> Wanted OR Got IS NULL THEN 'TRAP' ELSE 'unexpected' END
       END;

-- The session's language really did come back.
UPDATE Demo.Results SET Verdict = CASE WHEN Got <> N'British' THEN 'REVERTED' ELSE 'unexpected' END
WHERE  Item = '... and this session''s language afterwards';
-- I: exactly 3 inserted, then 8115.
UPDATE Demo.Results SET Verdict = CASE WHEN Got LIKE N'3 inserted; then error 8115%' THEN 'TRAP' ELSE 'unexpected' END
WHERE  Scenario = 'I' AND Item LIKE 'insert 4%';
-- H: the second insert was rejected as a duplicate.
UPDATE Demo.Results SET Verdict = CASE WHEN Got IN (N'error 2627', N'error 2601') THEN 'TRAP' ELSE 'unexpected' END
WHERE  Scenario = 'H' AND Item LIKE 'varchar(10) UNIQUE%';
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. WHAT SQL SERVER RETURNED ===';
GO
SELECT Scenario, Item, Got, Wanted, Verdict FROM Demo.Results ORDER BY Scenario;
GO

PRINT '';
PRINT '=== 2. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Got, Wanted, Verdict FROM Demo.Results WHERE Verdict IN ('unexpected', 'INCONCLUSIVE');
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 2 should be EMPTY. Anything in it is a';
PRINT ' genuine difference on your build or database, worth';
PRINT ' reading before you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
