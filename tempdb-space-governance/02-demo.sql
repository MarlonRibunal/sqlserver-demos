/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  tempdb space resource governance, SQL Server 2025: cap how much tempdb a
  workload group can use.

     A  a limit that isn't applied yet: ALTER WORKLOAD GROUP alone
     B  a 20 MB limit on the default group: what fails, what doesn't
     C  what counts: a table variable, a sort spill, the version store
     D  hitting the limit inside a transaction
     E  a percentage limit on a tempdb that autogrows

  On SQL Server 2022 and earlier every scenario reports SKIPPED.

  WHAT THIS CHANGES -- READ THIS: the DEFAULT workload group, for the whole
  instance. It sets GROUP_MAX_TEMPDB_DATA_MB = 20 and enables Resource
  Governor, so every session in the default group (on most servers, every
  session) shares 20 MB of tempdb while the demo runs. At the end it puts
  back the settings 01-setup.sql recorded, and checks that it did.
  03-cleanup.sql does the same. Scratch instances only.

  TESTED end to end on SQL Server 2025 RTM-CU10 (17.0.5035.5), Linux
  container.
==============================================================================*/

USE TempGovDemo;
GO
SET NOCOUNT ON;
GO

TRUNCATE TABLE Demo.Results;
TRUNCATE TABLE Demo.Verdicts;
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) < 17
    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'tempdb governance: applying a limit',       'needs SQL Server 2025 or later', 'SKIPPED'),
    ('B', 'tempdb governance: a 20 MB limit',          'needs SQL Server 2025 or later', 'SKIPPED'),
    ('C', 'tempdb governance: what counts',            'needs SQL Server 2025 or later', 'SKIPPED'),
    ('D', 'tempdb governance: transactions',           'needs SQL Server 2025 or later', 'SKIPPED'),
    ('E', 'tempdb governance: percentage limit',       'needs SQL Server 2025 or later', 'SKIPPED');
GO

-- Start from the recorded settings, in case a previous run stopped halfway.
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    EXEC Demo.usp_RestoreRG;
    EXEC Demo.usp_Drain;
END
GO


/*==============================================================================
  A. The baseline, then a limit that hasn't been applied. 50 MB in a
     temporary table, and a sort that spills.
==============================================================================*/
PRINT '=== A. before the limit is applied ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @eBig int, @eSort int, @ePending int, @pending varchar(10);
    EXEC Demo.usp_Try N'CREATE TABLE #t (Pad char(8000) NOT NULL);
                        INSERT #t (Pad) SELECT ''x'' FROM Demo.Numbers WHERE N <= 6400;', @eBig OUTPUT;
    EXEC Demo.usp_Drain;
    EXEC Demo.usp_Try N'SELECT COUNT(*) FROM (SELECT ROW_NUMBER() OVER (ORDER BY CAST(NEWID() AS char(36)) + REPLICATE(''y'', 7000)) AS rn
                        FROM Demo.Numbers WHERE N <= 6400) AS x WHERE rn > 0 OPTION (MAX_GRANT_PERCENT = 0.0, MAXDOP 1);', @eSort OUTPUT;
    EXEC Demo.usp_Drain;

    EXEC Demo.usp_ApplyRG 20, NULL, @Reconfigure = 0;
    EXEC sys.sp_executesql N'SELECT @p = CASE is_reconfiguration_pending WHEN 1 THEN ''yes'' ELSE ''no'' END
                             FROM sys.dm_resource_governor_configuration;', N'@p varchar(10) OUTPUT', @p = @pending OUTPUT;
    EXEC Demo.usp_Try N'CREATE TABLE #t (Pad char(8000) NOT NULL);
                        INSERT #t (Pad) SELECT ''x'' FROM Demo.Numbers WHERE N <= 6400;', @ePending OUTPUT;
    EXEC Demo.usp_Drain;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('A', 'no limit: 50 MB into a temporary table',          CASE @eBig  WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eBig AS varchar(10)) END),
    ('A', 'no limit: a sort that spills about 45 MB',        CASE @eSort WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eSort AS varchar(10)) END),
    ('A', 'ALTER WORKLOAD GROUP ... 20 MB, no RECONFIGURE: reconfiguration pending', @pending),
    ('A', 'the same 50 MB, limit set but not applied',       CASE @ePending WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@ePending AS varchar(10)) END);

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'without a limit, 50 MB of temp table and the spilling sort both run',
     'temp table ' + CAST(@eBig AS varchar(10)) + ', sort ' + CAST(@eSort AS varchar(10)),
     CASE WHEN @eBig = 0 AND @eSort = 0 THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('A', 'ALTER WORKLOAD GROUP alone enforces nothing until RECONFIGURE',
     'pending ' + @pending + ', 50 MB insert ' + CASE @ePending WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@ePending AS varchar(10)) END,
     CASE WHEN @pending = 'yes' AND @ePending = 0 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  B. Apply it: 20 MB for the whole default group.
==============================================================================*/
PRINT '=== B. a 20 MB limit ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @v0 bigint, @v1 bigint, @e50 int, @e10 int, @e15 int, @e15x2 int, @en varchar(10);
    EXEC Demo.usp_ApplyRG 20, NULL;
    EXEC sys.sp_executesql N'SELECT @v = total_tempdb_data_limit_violation_count FROM sys.dm_resource_governor_workload_groups WHERE name = N''default'';',
         N'@v bigint OUTPUT', @v = @v0 OUTPUT;
    SELECT @en = CASE is_enabled WHEN 1 THEN 'yes' ELSE 'no' END FROM sys.resource_governor_configuration;

    EXEC Demo.usp_Try N'CREATE TABLE #t (Pad char(8000) NOT NULL);
                        INSERT #t (Pad) SELECT ''x'' FROM Demo.Numbers WHERE N <= 6400;', @e50 OUTPUT;
    EXEC Demo.usp_Drain;
    EXEC Demo.usp_Try N'CREATE TABLE #t (Pad char(8000) NOT NULL);
                        INSERT #t (Pad) SELECT ''x'' FROM Demo.Numbers WHERE N <= 1280;', @e10 OUTPUT;
    EXEC Demo.usp_Drain;
    EXEC Demo.usp_Try N'CREATE TABLE #a (Pad char(8000) NOT NULL);
                        INSERT #a (Pad) SELECT ''x'' FROM Demo.Numbers WHERE N <= 1920;', @e15 OUTPUT;
    EXEC Demo.usp_Drain;
    EXEC Demo.usp_Try N'CREATE TABLE #a (Pad char(8000) NOT NULL);
                        INSERT #a (Pad) SELECT ''x'' FROM Demo.Numbers WHERE N <= 1920;
                        CREATE TABLE #b (Pad char(8000) NOT NULL);
                        INSERT #b (Pad) SELECT ''x'' FROM Demo.Numbers WHERE N <= 1920;', @e15x2 OUTPUT;
    EXEC Demo.usp_Drain;

    EXEC sys.sp_executesql N'SELECT @v = total_tempdb_data_limit_violation_count FROM sys.dm_resource_governor_workload_groups WHERE name = N''default'';',
         N'@v bigint OUTPUT', @v = @v1 OUTPUT;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('B', 'Resource Governor enabled after RECONFIGURE',  @en),
    ('B', '50 MB into a temporary table',                 CASE @e50   WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e50 AS varchar(10)) END),
    ('B', '10 MB into a temporary table',                 CASE @e10   WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e10 AS varchar(10)) END),
    ('B', '15 MB into one temporary table',               CASE @e15   WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e15 AS varchar(10)) END),
    ('B', '15 MB into each of two temporary tables',      CASE @e15x2 WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e15x2 AS varchar(10)) END),
    ('B', 'total_tempdb_data_limit_violation_count, increase', CAST(@v1 - @v0 AS varchar(20)));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('B', 'RECONFIGURE turns Resource Governor on, and 50 MB now fails with error 1138',
     'enabled ' + @en + ', 50 MB ' + CASE @e50 WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e50 AS varchar(10)) END,
     CASE WHEN @en = 'yes' AND @e50 = 1138 THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('B', 'under the limit, work runs as before',
     '10 MB ' + CAST(@e10 AS varchar(10)) + ', 15 MB ' + CAST(@e15 AS varchar(10)),
     CASE WHEN @e10 = 0 AND @e15 = 0 THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('B', 'the limit is a total: two 15 MB tables fail where one ran',
     CASE @e15x2 WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e15x2 AS varchar(10)) END,
     CASE WHEN @e15x2 = 1138 THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('B', 'each refusal is counted in sys.dm_resource_governor_workload_groups',
     '+' + CAST(@v1 - @v0 AS varchar(20)),
     CASE WHEN @v1 - @v0 >= 2 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  C. What counts against the limit. The limit is still 20 MB.
==============================================================================*/
PRINT '=== C. what counts ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @eTv int, @eSort int;
    EXEC Demo.usp_Try N'DECLARE @t TABLE (Pad char(8000) NOT NULL);
                        INSERT @t (Pad) SELECT ''x'' FROM Demo.Numbers WHERE N <= 6400;', @eTv OUTPUT;
    EXEC Demo.usp_Drain;
    EXEC Demo.usp_Try N'SELECT COUNT(*) FROM (SELECT ROW_NUMBER() OVER (ORDER BY CAST(NEWID() AS char(36)) + REPLICATE(''y'', 7000)) AS rn
                        FROM Demo.Numbers WHERE N <= 6400) AS x WHERE rn > 0 OPTION (MAX_GRANT_PERCENT = 0.0, MAXDOP 1);', @eSort OUTPUT;
    EXEC Demo.usp_Drain;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('C', '50 MB into a table variable',    CASE @eTv   WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eTv AS varchar(10)) END),
    ('C', 'the sort that spills',           CASE @eSort WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eSort AS varchar(10)) END);

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('C', 'a table variable counts: error 1138',
     CASE @eTv WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eTv AS varchar(10)) END,
     CASE WHEN @eTv = 1138 THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('C', 'a sort spill counts: the query that ran in A now fails with 1138',
     CASE @eSort WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eSort AS varchar(10)) END,
     CASE WHEN @eSort = 1138 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO

-- The version store: update every row of Demo.Wide (50 MB) under
-- READ_COMMITTED_SNAPSHOT, and look at the version store before committing.
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @e int = 0, @rows int = 0, @vsMB bigint, @grpKB bigint;
    BEGIN TRANSACTION;
    BEGIN TRY
        UPDATE Demo.Wide SET Pad = CASE WHEN Pad = 'a' THEN 'b' ELSE 'a' END;
        SET @rows = @@ROWCOUNT;
    END TRY
    BEGIN CATCH
        SET @e = ERROR_NUMBER();
    END CATCH
    SELECT @vsMB = SUM(version_store_reserved_page_count) * 8 / 1024 FROM tempdb.sys.dm_db_file_space_usage;
    EXEC sys.sp_executesql N'SELECT @kb = tempdb_data_space_kb FROM sys.dm_resource_governor_workload_groups WHERE name = N''default'';',
         N'@kb bigint OUTPUT', @kb = @grpKB OUTPUT;
    IF XACT_STATE() = 1 COMMIT; ELSE IF XACT_STATE() = -1 ROLLBACK;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('C', 'UPDATE of 50 MB under RCSI',              CASE @e WHEN 0 THEN 'ran, ' + CAST(@rows AS varchar(10)) + ' rows' ELSE 'error ' + CAST(@e AS varchar(10)) END),
    ('C', 'version store in tempdb, MB',             CAST(@vsMB AS varchar(20))),
    ('C', 'tempdb the default group holds, KB',      CAST(@grpKB AS varchar(20)));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('C', 'the version store does not count: 20+ MB of versions, no error',
     CAST(@vsMB AS varchar(20)) + ' MB of versions, group holds ' + CAST(@grpKB AS varchar(20)) + ' KB, update '
       + CASE @e WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e AS varchar(10)) END,
     CASE WHEN @e = 0 AND @vsMB > 20 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
    EXEC Demo.usp_Drain;
GO


/*==============================================================================
  D. Hitting the limit inside a transaction.
==============================================================================*/
PRINT '=== D. inside a transaction ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @e int, @xs int;
    CREATE TABLE #kept (ID int NOT NULL);
    BEGIN TRANSACTION;
        INSERT #kept (ID) VALUES (1);
        EXEC Demo.usp_Try N'CREATE TABLE #t (Pad char(8000) NOT NULL);
                            INSERT #t (Pad) SELECT ''x'' FROM Demo.Numbers WHERE N <= 6400;', @e OUTPUT;
        SET @xs = XACT_STATE();
    IF XACT_STATE() = 1 COMMIT; ELSE IF XACT_STATE() = -1 ROLLBACK;
    DECLARE @kept int = (SELECT COUNT(*) FROM #kept);
    DROP TABLE #kept;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('D', '50 MB inside a transaction',         CASE @e WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e AS varchar(10)) END),
    ('D', 'XACT_STATE() after the error',       CAST(@xs AS varchar(5))),
    ('D', 'rows kept from before the error',    CAST(@kept AS varchar(5)));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('D', 'error 1138 dooms the transaction: the work before it is rolled back',
     'error ' + CAST(@e AS varchar(10)) + ', XACT_STATE ' + CAST(@xs AS varchar(5)) + ', rows kept ' + CAST(@kept AS varchar(5)),
     CASE WHEN @e = 1138 AND @xs = -1 AND @kept = 0 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
    EXEC Demo.usp_Drain;
GO


/*==============================================================================
  E. A percentage limit instead: 1% of tempdb. It applies only when every
     tempdb data file has a fixed size (no autogrowth, or a MAXSIZE).
==============================================================================*/
PRINT '=== E. a percentage limit ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @e int, @growing int;
    SELECT @growing = COUNT(*) FROM tempdb.sys.database_files WHERE type = 0 AND growth > 0 AND max_size = -1;
    EXEC Demo.usp_ApplyRG NULL, 1.0;
    EXEC Demo.usp_Try N'CREATE TABLE #t (Pad char(8000) NOT NULL);
                        INSERT #t (Pad) SELECT ''x'' FROM Demo.Numbers WHERE N <= 6400;', @e OUTPUT;
    EXEC Demo.usp_Drain;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('E', 'tempdb data files that autogrow with no MAXSIZE', CAST(@growing AS varchar(5))),
    ('E', 'GROUP_MAX_TEMPDB_DATA_PERCENT = 1: 50 MB into a temporary table',
     CASE @e WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e AS varchar(10)) END);

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('E', 'on a tempdb that autogrows, a percentage limit is not enforced',
     CAST(@growing AS varchar(5)) + ' autogrowing files, 50 MB ' + CASE @e WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e AS varchar(10)) END,
     CASE WHEN @growing = 0 THEN 'INCONCLUSIVE'
          WHEN @e = 0 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  Put Resource Governor back as 01-setup.sql found it, and check.
==============================================================================*/
PRINT '=== restore the Resource Governor settings ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    EXEC Demo.usp_RestoreRG;
    DECLARE @ok bit;
    EXEC sys.sp_executesql N'
        SELECT @ok = CASE WHEN c.is_enabled = o.IsEnabled
                           AND EXISTS (SELECT g.group_max_tempdb_data_mb, g.group_max_tempdb_data_percent
                                       INTERSECT SELECT o.MaxMB, o.MaxPercent)
                          THEN 1 ELSE 0 END
        FROM   Demo.OriginalRG AS o
        CROSS JOIN sys.resource_governor_configuration AS c
        CROSS JOIN sys.resource_governor_workload_groups AS g
        WHERE  g.name = N''default'';', N'@ok bit OUTPUT', @ok = @ok OUTPUT;
    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('E', 'Resource Governor is back as setup found it',
     (SELECT 'enabled ' + CAST(IsEnabled AS varchar(1)) + ', MB ' + ISNULL(CAST(MaxMB AS varchar(20)), 'none')
             + ', percent ' + ISNULL(CAST(MaxPercent AS varchar(20)), 'none') FROM Demo.OriginalRG),
     CASE WHEN @ok = 1 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
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
PRINT ' Resource Governor has been put back as setup found it.';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
