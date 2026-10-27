/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Fuzzy string matching in SQL Server 2025: EDIT_DISTANCE,
  EDIT_DISTANCE_SIMILARITY, JARO_WINKLER_DISTANCE and
  JARO_WINKLER_SIMILARITY, against each other and against SOUNDEX.

     A  what the functions need: preview features, a Windows collation
     B  what EDIT_DISTANCE counts
     C  the two similarity scores disagree
     D  SOUNDEX against edit distance
     E  searching 200,000 names: every row, or SOUNDEX first

  On SQL Server 2022 and earlier every scenario reports SKIPPED.

  WHAT THIS CHANGES: only FuzzyDemo. Scenario A turns PREVIEW_FEATURES off
  and back on.

  TESTED end to end on SQL Server 2025 RTM-CU9-GDR (17.0.5015.4), Linux
  container.
==============================================================================*/

USE FuzzyDemo;
GO
SET NOCOUNT ON;
GO

TRUNCATE TABLE Demo.Results;
TRUNCATE TABLE Demo.Verdicts;
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) < 17
    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'fuzzy matching: prerequisites',     'needs SQL Server 2025 or later', 'SKIPPED'),
    ('B', 'EDIT_DISTANCE: what it counts',     'needs SQL Server 2025 or later', 'SKIPPED'),
    ('C', 'the two similarity scores',         'needs SQL Server 2025 or later', 'SKIPPED'),
    ('D', 'SOUNDEX against edit distance',     'needs SQL Server 2025 or later', 'SKIPPED'),
    ('E', 'searching 200,000 names',           'needs SQL Server 2025 or later', 'SKIPPED');
GO


/*==============================================================================
  A. What the functions need. A database scoped configuration applies from
  the next batch, so each change is a batch of its own.
==============================================================================*/
PRINT '=== A. prerequisites ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
    EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = OFF;');
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @e int;
    EXEC Demo.usp_Try N'DECLARE @d int = EDIT_DISTANCE(N''Smith'', N''Smyth'');', @e OUTPUT;
    INSERT Demo.Results (Scenario, Item, Value)
    VALUES ('A', 'EDIT_DISTANCE, PREVIEW_FEATURES = OFF', CASE @e WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e AS varchar(10)) END);
    EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;');
END
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @e int;
    EXEC Demo.usp_Try N'DECLARE @d int = EDIT_DISTANCE(N''Smith'', N''Smyth'');', @e OUTPUT;
    INSERT Demo.Results (Scenario, Item, Value)
    VALUES ('A', 'EDIT_DISTANCE, PREVIEW_FEATURES = ON, Windows collation', CASE @e WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e AS varchar(10)) END);
    EXEC Demo.usp_Try N'DECLARE @d int = EDIT_DISTANCE(N''Smith'' COLLATE SQL_Latin1_General_CP1_CI_AS, N''Smyth'');', @e OUTPUT;
    INSERT Demo.Results (Scenario, Item, Value)
    VALUES ('A', 'EDIT_DISTANCE, a SQL_Latin1_General_CP1_CI_AS string', CASE @e WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e AS varchar(10)) END);

    DECLARE @off varchar(40) = (SELECT Value FROM Demo.Results WHERE Item = 'EDIT_DISTANCE, PREVIEW_FEATURES = OFF'),
            @on  varchar(40) = (SELECT Value FROM Demo.Results WHERE Item = 'EDIT_DISTANCE, PREVIEW_FEATURES = ON, Windows collation'),
            @sql varchar(40) = (SELECT Value FROM Demo.Results WHERE Item = 'EDIT_DISTANCE, a SQL_Latin1_General_CP1_CI_AS string');

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'on this build the functions need PREVIEW_FEATURES = ON (error 195 without)',
     'off: ' + @off + ', on: ' + @on,
     CASE WHEN @off = 'error 195' AND @on = 'ran' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('A', 'they refuse SQL_* collations (error 9847), the default on a US-English install',
     @sql, CASE WHEN @sql = 'error 9847' THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  B. What EDIT_DISTANCE counts. Dynamic SQL, so 2022 never compiles it.
==============================================================================*/
PRINT '=== B. what EDIT_DISTANCE counts ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
EXEC (N'
    DECLARE @case int    = EDIT_DISTANCE(N''smith'', N''SMITH''),
            @accent int  = EDIT_DISTANCE(N''Müller'', N''Muller''),
            @swap int    = EDIT_DISTANCE(N''ab'', N''ba''),
            @full int    = EDIT_DISTANCE(N''Katherine'', N''Kathy''),
            @capped int  = EDIT_DISTANCE(N''Katherine'', N''Kathy'', 1),
            @null int    = EDIT_DISTANCE(NULL, N''Kathy'');

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    (''B'', ''smith / SMITH (a case-insensitive collation)'', CAST(@case AS varchar(10))),
    (''B'', ''Müller / Muller (accent-sensitive)'',            CAST(@accent AS varchar(10))),
    (''B'', ''ab / ba'',                                       CAST(@swap AS varchar(10))),
    (''B'', ''Katherine / Kathy'',                             CAST(@full AS varchar(10))),
    (''B'', ''Katherine / Kathy, maximum distance 1'',         CAST(@capped AS varchar(10))),
    (''B'', ''NULL / Kathy'',                                  ISNULL(CAST(@null AS varchar(10)), ''NULL''));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    (''B'', ''comparison follows the collation: case ignored, accents counted'',
     ''smith/SMITH '' + CAST(@case AS varchar(10)) + '', Müller/Muller '' + CAST(@accent AS varchar(10)),
     CASE WHEN @case = 0 AND @accent = 1 THEN ''CONFIRMED'' ELSE ''unexpected'' END),
    (''B'', ''swapping two adjacent letters counts as one edit, not two'',
     ''ab/ba '' + CAST(@swap AS varchar(10)),
     CASE WHEN @swap = 1 THEN ''CONFIRMED'' ELSE ''unexpected'' END),
    (''B'', ''with a maximum, it stops counting: the result is the maximum plus 1'',
     ''Katherine/Kathy '' + CAST(@full AS varchar(10)) + '', with maximum 1: '' + CAST(@capped AS varchar(10)),
     CASE WHEN @full = 5 AND @capped = 2 THEN ''CONFIRMED'' ELSE ''unexpected'' END);');
GO


/*==============================================================================
  C. The two similarity scores, 0 to 100, on the same pairs.
==============================================================================*/
PRINT '=== C. two similarity scores ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
EXEC (N'
    DECLARE @p TABLE (a nvarchar(20), b nvarchar(20), ed int, jw int);
    INSERT @p (a, b) VALUES (N''Smith'', N''Smyth''), (N''MARTHA'', N''MARHTA''), (N''Jonathan'', N''Jon''),
                            (N''Smith'', N''Smithson''), (N''Robert'', N''Bob'');
    UPDATE @p SET ed = EDIT_DISTANCE_SIMILARITY(a, b), jw = JARO_WINKLER_SIMILARITY(a, b);

    INSERT Demo.Results (Scenario, Item, Value)
    SELECT ''C'', a + '' / '' + b, ''EDIT_DISTANCE_SIMILARITY '' + CAST(ed AS varchar(10)) + '', JARO_WINKLER_SIMILARITY '' + CAST(jw AS varchar(10))
    FROM   @p;

    DECLARE @jon_ed int, @jon_jw int, @son_ed int, @son_jw int;
    SELECT @jon_ed = ed, @jon_jw = jw FROM @p WHERE b = N''Jon'';
    SELECT @son_ed = ed, @son_jw = jw FROM @p WHERE b = N''Smithson'';

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    (''C'', ''at a threshold of 80, Jaro-Winkler accepts Jonathan/Jon and Smith/Smithson; edit-distance similarity rejects both'',
     ''Jonathan/Jon '' + CAST(@jon_jw AS varchar(10)) + '' against '' + CAST(@jon_ed AS varchar(10))
     + '', Smith/Smithson '' + CAST(@son_jw AS varchar(10)) + '' against '' + CAST(@son_ed AS varchar(10)),
     CASE WHEN @jon_jw >= 80 AND @son_jw >= 80 AND @jon_ed < 80 AND @son_ed < 80 THEN ''CONFIRMED'' ELSE ''unexpected'' END);');
GO


/*==============================================================================
  D. SOUNDEX against edit distance.
==============================================================================*/
PRINT '=== D. SOUNDEX ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
EXEC (N'
    DECLARE @ck1 char(4) = SOUNDEX(N''Catherine''), @ck2 char(4) = SOUNDEX(N''Katherine''), @ckd int = EDIT_DISTANCE(N''Catherine'', N''Katherine''),
            @rr1 char(4) = SOUNDEX(N''Robert''),    @rr2 char(4) = SOUNDEX(N''Rupert''),    @rrd int = EDIT_DISTANCE(N''Robert'', N''Rupert'');

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    (''D'', ''Catherine / Katherine'', ''SOUNDEX '' + @ck1 + '' / '' + @ck2 + '', edit distance '' + CAST(@ckd AS varchar(10))),
    (''D'', ''Robert / Rupert'',       ''SOUNDEX '' + @rr1 + '' / '' + @rr2 + '', edit distance '' + CAST(@rrd AS varchar(10)));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    (''D'', ''SOUNDEX keeps the first letter: Catherine and Katherine differ, one edit apart'',
     @ck1 + '' / '' + @ck2 + '', distance '' + CAST(@ckd AS varchar(10)),
     CASE WHEN @ck1 <> @ck2 AND @ckd = 1 THEN ''CONFIRMED'' ELSE ''unexpected'' END),
    (''D'', ''... and matches different names: Robert and Rupert share a code, two edits apart'',
     @rr1 + '' / '' + @rr2 + '', distance '' + CAST(@rrd AS varchar(10)),
     CASE WHEN @rr1 = @rr2 AND @rrd = 2 THEN ''CONFIRMED'' ELSE ''unexpected'' END);');
GO


/*==============================================================================
  E. Searching 200,000 names for 'Johnson', within two edits: every row, or
  only the rows with Johnson's SOUNDEX code. Serial, best of three.
==============================================================================*/
PRINT '=== E. searching 200,000 names ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @i int = 1, @c bigint, @cAll bigint = 2147483647, @cBlocked bigint = 2147483647;
    WHILE @i <= 3
    BEGIN
        EXEC Demo.usp_Measure N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.People WHERE EDIT_DISTANCE(Surname, N''Johnson'') <= 2 OPTION (MAXDOP 1);', @c OUTPUT;
        IF @c < @cAll SET @cAll = @c;
        EXEC Demo.usp_Measure N'DECLARE @n int; SELECT @n = COUNT(*) FROM Demo.People WHERE SoundexCode = SOUNDEX(N''Johnson'') AND EDIT_DISTANCE(Surname, N''Johnson'') <= 2 OPTION (MAXDOP 1);', @c OUTPUT;
        IF @c < @cBlocked SET @cBlocked = @c;
        SET @i += 1;
    END

    DECLARE @all varchar(400), @blocked varchar(400);
    EXEC sys.sp_executesql N'
        SELECT @a = STRING_AGG(CAST(Surname AS varchar(50)), '', '') WITHIN GROUP (ORDER BY Surname)
        FROM (SELECT DISTINCT Surname FROM Demo.People WHERE EDIT_DISTANCE(Surname, N''Johnson'') <= 2) AS x;
        SELECT @b = STRING_AGG(CAST(Surname AS varchar(50)), '', '') WITHIN GROUP (ORDER BY Surname)
        FROM (SELECT DISTINCT Surname FROM Demo.People WHERE SoundexCode = SOUNDEX(N''Johnson'') AND EDIT_DISTANCE(Surname, N''Johnson'') <= 2) AS x;',
        N'@a varchar(400) OUTPUT, @b varchar(400) OUTPUT', @a = @all OUTPUT, @b = @blocked OUTPUT;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('E', 'CPU ms: EDIT_DISTANCE on every row',            CAST(@cAll AS varchar(20))),
    ('E', 'CPU ms: SOUNDEX code first, then EDIT_DISTANCE', CAST(@cBlocked AS varchar(20))),
    ('E', 'names found: every row',                         @all),
    ('E', 'names found: SOUNDEX first',                     @blocked);

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('E', 'filtering on SOUNDEX first cuts the CPU at least threefold',
     CAST(@cBlocked AS varchar(20)) + ' ms against ' + CAST(@cAll AS varchar(20)),
     CASE WHEN @cAll < 30 THEN 'INCONCLUSIVE' WHEN @cBlocked * 3 <= @cAll THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('E', '... and misses Kohnson, whose first letter differs',
     'every row: ' + @all + '; SOUNDEX first: ' + @blocked,
     CASE WHEN @all LIKE '%Kohnson%' AND @blocked NOT LIKE '%Kohnson%' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('E', 'two edits also reaches a different surname: Roinson, a Robinson with a letter dropped',
     @all, CASE WHEN @all LIKE '%Roinson%' THEN 'CONFIRMED' ELSE 'unexpected' END);
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
