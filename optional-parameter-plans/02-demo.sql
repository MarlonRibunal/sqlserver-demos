/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Optional parameter plan optimization (OPPO), SQL Server 2025, compatibility
  level 170: for WHERE (@p IS NULL OR col = @p), the engine keeps one plan
  for "@p was given" and another for "@p was NULL", and picks per call.

  Every search runs at compatibility level 160 (before) and 170:

     A  the catch-all with one optional parameter
     B  two optional parameters
     C  the same search written with COALESCE, and with ISNULL
     D  the parameter modified first, or copied into a local variable
     E  the database setting that turns OPPO off

  On SQL Server 2022 and earlier every scenario reports SKIPPED.

  WHAT THIS CHANGES: only OppoDemo. It clears OppoDemo's Query Store and its
  plan cache (this database's plans only), moves its compatibility level
  between 160 and 170, and turns OPTIONAL_PARAMETER_OPTIMIZATION off and
  back on. It leaves OppoDemo at 170 with the setting on.

  TESTED end to end on SQL Server 2025 RTM-CU8 (17.0.4075.5), Linux
  container.
==============================================================================*/

USE OppoDemo;
GO
SET NOCOUNT ON;
GO

TRUNCATE TABLE Demo.Results;
TRUNCATE TABLE Demo.Verdicts;
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) < 17
    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'OPPO: one optional parameter',      'needs SQL Server 2025 or later', 'SKIPPED'),
    ('B', 'OPPO: two optional parameters',     'needs SQL Server 2025 or later', 'SKIPPED'),
    ('C', 'OPPO: COALESCE and ISNULL',         'needs SQL Server 2025 or later', 'SKIPPED'),
    ('D', 'OPPO: modified parameters',         'needs SQL Server 2025 or later', 'SKIPPED'),
    ('E', 'OPPO: the database setting',        'needs SQL Server 2025 or later', 'SKIPPED');
GO

/*------------------------------------------------------------------------------
  Every setting change is a batch of its own, and dynamic, so earlier
  versions don't reject the file. Changed inside a procedure, a
  compatibility level did not apply to that procedure's later compilations
  (see ../sql2022-iqp).
------------------------------------------------------------------------------*/
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET OPTIONAL_PARAMETER_OPTIMIZATION = ON;');
    EXEC (N'ALTER DATABASE CURRENT SET QUERY_STORE CLEAR;');
    EXEC (N'ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 160;');
END
GO
PRINT '=== compatibility level 160 ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17 EXEC Demo.usp_RunAll;
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17 EXEC (N'ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 170;');
GO
PRINT '=== compatibility level 170 ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    EXEC Demo.usp_RunAll;
    DECLARE @v varchar(400);
    EXEC Demo.usp_Variants @v OUTPUT;
    INSERT Demo.Results (Scenario, Config, Search, Args, Reads)
    VALUES ('-', 'compat 170', 'Query Store', 'plan variants: ' + ISNULL(@v, 'none'), NULL);
END
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17 EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET OPTIONAL_PARAMETER_OPTIMIZATION = OFF;');
GO
PRINT '=== compatibility level 170, OPTIONAL_PARAMETER_OPTIMIZATION = OFF ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
    EXEC Demo.usp_Run 'E', 's_Or', 123;
    EXEC Demo.usp_Run 'E', 's_Or', NULL;
END
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17 EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET OPTIONAL_PARAMETER_OPTIMIZATION = ON;');
GO


/*==============================================================================
  Verdicts (2025 and later).
==============================================================================*/
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @t TABLE (k varchar(80) PRIMARY KEY, r bigint);
    INSERT @t SELECT Scenario + '|' + LEFT(Config, 10) + CASE WHEN Config LIKE '%OFF' THEN ' off' ELSE '' END + '|' + Search + '|' + Args, Reads
    FROM   Demo.Results WHERE Reads IS NOT NULL;

    DECLARE @a160c bigint = (SELECT r FROM @t WHERE k = 'A|compat 160|s_Or|customer 123'),
            @a160n bigint = (SELECT r FROM @t WHERE k = 'A|compat 160|s_Or|customer NULL'),
            @a170c bigint = (SELECT r FROM @t WHERE k = 'A|compat 170|s_Or|customer 123'),
            @a170n bigint = (SELECT r FROM @t WHERE k = 'A|compat 170|s_Or|customer NULL'),
            @b170c bigint = (SELECT r FROM @t WHERE k = 'B|compat 170|s_Or2|customer 123, date NULL'),
            @b170d bigint = (SELECT r FROM @t WHERE k = 'B|compat 170|s_Or2|customer NULL, date 2023-01-01'),
            @b170n bigint = (SELECT r FROM @t WHERE k = 'B|compat 170|s_Or2|customer NULL, date NULL'),
            @c170c bigint = (SELECT r FROM @t WHERE k = 'C|compat 170|s_Coalesce|customer 123'),
            @c170i bigint = (SELECT r FROM @t WHERE k = 'C|compat 170|s_IsNull|customer 123'),
            @dmc   bigint = (SELECT r FROM @t WHERE k = 'D|compat 170|s_OrModified|customer 123'),
            @dmn   bigint = (SELECT r FROM @t WHERE k = 'D|compat 170|s_OrModified|customer NULL'),
            @dlc   bigint = (SELECT r FROM @t WHERE k = 'D|compat 170|s_OrLocal|customer 123'),
            @dln   bigint = (SELECT r FROM @t WHERE k = 'D|compat 170|s_OrLocal|customer NULL'),
            @eoffn bigint = (SELECT r FROM @t WHERE k = 'E|compat 170 off|s_Or|customer NULL'),
            @vars  varchar(400) = (SELECT Args FROM Demo.Results WHERE Search = 'Query Store');

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'compat 160: all customers runs the plan compiled for one, a lookup per row',
     CAST(@a160n AS varchar(20)) + ' reads for all customers (one customer: ' + CAST(@a160c AS varchar(20)) + ')',
     CASE WHEN @a160n >= 50 * @a170n THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('A', 'compat 170: OPPO gives "all customers" a plan of its own',
     CAST(@a170n AS varchar(20)) + ' reads for all customers; one customer: ' + CAST(@a170c AS varchar(20)),
     CASE WHEN @a170n * 50 <= @a160n AND @a170c <= 1000 THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('A', 'Query Store records the plans as variants of one query',
     @vars, CASE WHEN @vars LIKE '%s_Or: 2%' THEN 'CONFIRMED' ELSE 'unexpected' END),

    ('B', 'two optional parameters: the first two searches are fast',
     'customer only ' + CAST(@b170c AS varchar(20)) + ', date only ' + CAST(@b170d AS varchar(20)) + ' reads',
     CASE WHEN @b170c <= 1000 AND @b170d <= 10000 THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('B', '... but "neither" reuses the date search''s plan: a lookup for every order',
     CAST(@b170n AS varchar(20)) + ' reads for no filter at all (a scan reads about ' + CAST(@a170n AS varchar(20)) + ')',
     CASE WHEN @b170n >= 50 * @a170n THEN 'CONFIRMED' ELSE 'unexpected' END),

    ('C', 'COALESCE and ISNULL are not recognised: one customer still scans',
     'one customer: COALESCE ' + CAST(@c170c AS varchar(20)) + ', ISNULL ' + CAST(@c170i AS varchar(20)) + ', OR form ' + CAST(@a170c AS varchar(20)) + ' reads',
     CASE WHEN @c170c >= 20 * @a170c AND @c170i >= 20 * @a170c THEN 'CONFIRMED' ELSE 'unexpected' END),

    ('D', 'modifying the parameter first (SET @p = NULLIF(@p, 0)) doesn''t stop OPPO',
     'one customer ' + CAST(@dmc AS varchar(20)) + ', all customers after it ' + CAST(@dmn AS varchar(20)) + ' reads',
     CASE WHEN @dmc <= 1000 AND @dmn <= 2 * @a170n THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('D', 'copying it into a local variable does stop OPPO: one plan, a scan even for one customer',
     'one customer ' + CAST(@dlc AS varchar(20)) + ', all customers ' + CAST(@dln AS varchar(20)) + ' reads; the OR form: ' + CAST(@a170c AS varchar(20)) + ' and ' + CAST(@a170n AS varchar(20)),
     CASE WHEN @dlc >= 20 * @a170c THEN 'CONFIRMED' ELSE 'unexpected' END),

    ('E', 'OPTIONAL_PARAMETER_OPTIMIZATION = OFF puts 160''s behaviour back, at 170',
     CAST(@eoffn AS varchar(20)) + ' reads for all customers after one',
     CASE WHEN @eoffn >= 50 * @a170n THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. EVERY CALL ===';
GO
SELECT Scenario, Config, Search, Args, Reads FROM Demo.Results ORDER BY Seq;
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
