/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  ZSTD backup compression, SQL Server 2025, against MS_XPRESS (the only
  algorithm before 2025, used by plain WITH COMPRESSION):

     A  size: no compression, MS_XPRESS, and ZSTD at LOW, MEDIUM and HIGH
     B  time: the same backups, best of three
     C  data that doesn't compress
     D  writing ZSTD to a file that holds an MS_XPRESS backup
     E  restoring a ZSTD backup

  On SQL Server 2022 and earlier every scenario reports SKIPPED.

  WHAT THIS CHANGES: it writes backup files named ZstdDemo_*.bak to the
  instance's default backup folder, overwriting them on every run, and
  restores one as ZstdDemo_Copy, which it drops at the end. 03-cleanup.sql
  deletes the files.

  TESTED end to end on SQL Server 2025 RTM-CU9-GDR (17.0.5015.4), Linux
  container.
==============================================================================*/

USE ZstdDemo;
GO
SET NOCOUNT ON;
GO

TRUNCATE TABLE Demo.Results;
TRUNCATE TABLE Demo.Verdicts;
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) < 17
    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'ZSTD: backup size',                      'needs SQL Server 2025 or later', 'SKIPPED'),
    ('B', 'ZSTD: backup time',                      'needs SQL Server 2025 or later', 'SKIPPED'),
    ('C', 'ZSTD: data that doesn''t compress',      'needs SQL Server 2025 or later', 'SKIPPED'),
    ('D', 'ZSTD: an MS_XPRESS media set',           'needs SQL Server 2025 or later', 'SKIPPED'),
    ('E', 'ZSTD: restore',                          'needs SQL Server 2025 or later', 'SKIPPED');
GO


/*==============================================================================
  A and B. Five backups of ZstdDemo, three times each. Sizes are the same
  every time; the time kept is the best of three.
==============================================================================*/
PRINT '=== A and B. size and time ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @o TABLE (k varchar(10) PRIMARY KEY, opt nvarchar(200), ms int NULL, bytes bigint NULL, alg nvarchar(40) NULL);
    INSERT @o (k, opt) VALUES
        ('none',   N'NO_COMPRESSION'),
        ('xpress', N'COMPRESSION'),
        ('low',    N'COMPRESSION (ALGORITHM = ZSTD, LEVEL = LOW)'),
        ('medium', N'COMPRESSION (ALGORITHM = ZSTD, LEVEL = MEDIUM)'),
        ('high',   N'COMPRESSION (ALGORITHM = ZSTD, LEVEL = HIGH)');

    DECLARE @i int = 1, @k varchar(10), @opt nvarchar(200), @ms int, @bytes bigint, @alg nvarchar(40);
    WHILE @i <= 3
    BEGIN
        DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT k, opt FROM @o;
        OPEN c;
        FETCH NEXT FROM c INTO @k, @opt;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC Demo.usp_Backup N'ZstdDemo', @k, @opt, @ms OUTPUT, @bytes OUTPUT, @alg OUTPUT;
            UPDATE @o SET ms = CASE WHEN ms IS NULL OR @ms < ms THEN @ms ELSE ms END, bytes = @bytes, alg = @alg WHERE k = @k;
            FETCH NEXT FROM c INTO @k, @opt;
        END
        CLOSE c; DEALLOCATE c;
        SET @i += 1;
    END

    INSERT Demo.Results (Scenario, Item, Value)
    SELECT 'A', k + ' (' + alg + ')', CAST(CAST(bytes / 1048576.0 AS decimal(9,1)) AS varchar(20)) + ' MB' FROM @o;
    INSERT Demo.Results (Scenario, Item, Value)
    SELECT 'B', k, CAST(ms AS varchar(20)) + ' ms' FROM @o;

    DECLARE @bNone bigint, @bX bigint, @bL bigint, @bM bigint, @bH bigint, @tX int, @tL int, @tH int;
    SELECT @bNone = bytes FROM @o WHERE k = 'none';
    SELECT @bX = bytes, @tX = ms FROM @o WHERE k = 'xpress';
    SELECT @bL = bytes, @tL = ms FROM @o WHERE k = 'low';
    SELECT @bM = bytes FROM @o WHERE k = 'medium';
    SELECT @bH = bytes, @tH = ms FROM @o WHERE k = 'high';

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'every ZSTD level makes a smaller backup than MS_XPRESS',
     'MS_XPRESS ' + CAST(@bX / 1048576 AS varchar(20)) + ' MB; ZSTD LOW ' + CAST(@bL / 1048576 AS varchar(20))
     + ', MEDIUM ' + CAST(@bM / 1048576 AS varchar(20)) + ', HIGH ' + CAST(@bH / 1048576 AS varchar(20)) + ' MB',
     CASE WHEN @bL < @bX AND @bM < @bX AND @bH < @bX THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('A', 'the higher the level, the smaller the backup',
     'LOW ' + CAST(@bL AS varchar(20)) + ', MEDIUM ' + CAST(@bM AS varchar(20)) + ', HIGH ' + CAST(@bH AS varchar(20)) + ' bytes',
     CASE WHEN @bH <= @bM AND @bM <= @bL THEN 'CONFIRMED' ELSE 'unexpected' END),
    -- Times are reported, not judged: they depend on the CPU and the disk.
    -- On the emulated test container HIGH took three times as long as LOW;
    -- on GitHub's native x64 runners the two took the same time.
    ('B', 'backup time, ZSTD LOW against MS_XPRESS (depends on hardware)',
     'LOW ' + CAST(@tL AS varchar(20)) + ' ms, MS_XPRESS ' + CAST(@tX AS varchar(20)) + ' ms', 'INFO'),
    ('B', 'backup time, ZSTD HIGH against LOW (depends on hardware)',
     'HIGH ' + CAST(@tH AS varchar(20)) + ' ms, LOW ' + CAST(@tL AS varchar(20)) + ' ms', 'INFO');
END
GO


/*==============================================================================
  C. Random bytes, which is what encrypted and already-compressed data look
  like to a compressor.
==============================================================================*/
PRINT '=== C. data that doesn''t compress ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @ms int, @none bigint, @x bigint, @z bigint, @alg nvarchar(40);
    EXEC Demo.usp_Backup N'ZstdDemoRandom', N'random_none',   N'NO_COMPRESSION',                                @ms OUTPUT, @none OUTPUT, @alg OUTPUT;
    EXEC Demo.usp_Backup N'ZstdDemoRandom', N'random_xpress', N'COMPRESSION',                                   @ms OUTPUT, @x OUTPUT,    @alg OUTPUT;
    EXEC Demo.usp_Backup N'ZstdDemoRandom', N'random_high',   N'COMPRESSION (ALGORITHM = ZSTD, LEVEL = HIGH)',  @ms OUTPUT, @z OUTPUT,    @alg OUTPUT;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('C', 'random data, no compression', CAST(CAST(@none / 1048576.0 AS decimal(9,1)) AS varchar(20)) + ' MB'),
    ('C', 'random data, MS_XPRESS',      CAST(CAST(@x / 1048576.0 AS decimal(9,1)) AS varchar(20)) + ' MB'),
    ('C', 'random data, ZSTD HIGH',      CAST(CAST(@z / 1048576.0 AS decimal(9,1)) AS varchar(20)) + ' MB');

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('C', 'on random data neither algorithm saves even 20%',
     'MS_XPRESS ' + CAST(CAST(100.0 * @x / @none AS int) AS varchar(10)) + '%, ZSTD HIGH ' + CAST(CAST(100.0 * @z / @none AS int) AS varchar(10)) + '% of the uncompressed size',
     CASE WHEN @x * 10 >= @none * 8 AND @z * 10 >= @none * 8 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  D. A file that holds an MS_XPRESS backup, overwritten WITH INIT by a ZSTD
  backup, then WITH FORMAT. A failed BACKUP raises two errors: the reason
  (3098 here: "'ZSTD' was requested after the media was formatted with an
  incompatible structure") and then 3013, "BACKUP DATABASE is terminating
  abnormally". A CATCH block sees only the last, 3013.
==============================================================================*/
PRINT '=== D. an MS_XPRESS media set ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @dir nvarchar(300) = CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(300));
    DECLARE @sep nchar(1) = CASE WHEN CHARINDEX(N'\', @dir) > 0 THEN N'\' ELSE N'/' END;
    IF RIGHT(@dir, 1) IN (N'\', N'/') SET @dir = LEFT(@dir, LEN(@dir) - 1);
    DECLARE @path nvarchar(400) = @dir + @sep + N'ZstdDemo_media.bak', @eInit int = 0, @eFormat int = 0;

    EXEC (N'BACKUP DATABASE ZstdDemoRandom TO DISK = N''' + @path + N''' WITH INIT, FORMAT, COMPRESSION;');
    BEGIN TRY
        EXEC (N'BACKUP DATABASE ZstdDemoRandom TO DISK = N''' + @path + N''' WITH INIT, COMPRESSION (ALGORITHM = ZSTD);');
    END TRY
    BEGIN CATCH
        SET @eInit = ERROR_NUMBER();
    END CATCH
    BEGIN TRY
        EXEC (N'BACKUP DATABASE ZstdDemoRandom TO DISK = N''' + @path + N''' WITH INIT, FORMAT, COMPRESSION (ALGORITHM = ZSTD);');
    END TRY
    BEGIN CATCH
        SET @eFormat = ERROR_NUMBER();
    END CATCH

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('D', 'ZSTD over an MS_XPRESS backup, WITH INIT',   CASE @eInit   WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eInit AS varchar(10)) END),
    ('D', 'ZSTD over an MS_XPRESS backup, WITH FORMAT', CASE @eFormat WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eFormat AS varchar(10)) END);

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('D', 'WITH INIT can''t switch a file from MS_XPRESS to ZSTD; WITH FORMAT can',
     'INIT: ' + CASE @eInit WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eInit AS varchar(10)) END
     + ', FORMAT: ' + CASE @eFormat WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eFormat AS varchar(10)) END,
     CASE WHEN @eInit = 3013 AND @eFormat = 0 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  E. Restore the ZSTD HIGH backup as ZstdDemo_Copy, and compare it.
==============================================================================*/
PRINT '=== E. restore ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @dir nvarchar(300) = CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(300)),
            @data nvarchar(300) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(300)),
            @log nvarchar(300) = CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(300));
    DECLARE @sep nchar(1) = CASE WHEN CHARINDEX(N'\', @dir) > 0 THEN N'\' ELSE N'/' END;
    IF RIGHT(@dir, 1)  IN (N'\', N'/') SET @dir = LEFT(@dir, LEN(@dir) - 1);
    IF RIGHT(@data, 1) IN (N'\', N'/') SET @data = LEFT(@data, LEN(@data) - 1);
    IF RIGHT(@log, 1)  IN (N'\', N'/') SET @log = LEFT(@log, LEN(@log) - 1);

    IF DB_ID(N'ZstdDemo_Copy') IS NOT NULL
        EXEC (N'ALTER DATABASE ZstdDemo_Copy SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ZstdDemo_Copy;');

    DECLARE @t0 datetime2 = SYSDATETIME(), @ms int, @rows bigint, @orig bigint, @e int = 0;
    BEGIN TRY
        EXEC (N'RESTORE DATABASE ZstdDemo_Copy FROM DISK = N''' + @dir + @sep + N'ZstdDemo_high.bak''
                WITH MOVE N''ZstdDemo''     TO N''' + @data + @sep + N'ZstdDemo_Copy.mdf'',
                     MOVE N''ZstdDemo_log'' TO N''' + @log  + @sep + N'ZstdDemo_Copy_log.ldf'';');
    END TRY
    BEGIN CATCH
        SET @e = ERROR_NUMBER();
    END CATCH
    SET @ms = DATEDIFF(ms, @t0, SYSDATETIME());

    IF @e = 0
        EXEC sys.sp_executesql N'SELECT @n = COUNT_BIG(*) FROM ZstdDemo_Copy.Demo.Orders;', N'@n bigint OUTPUT', @n = @rows OUTPUT;
    SELECT @orig = COUNT_BIG(*) FROM Demo.Orders;

    IF DB_ID(N'ZstdDemo_Copy') IS NOT NULL
        EXEC (N'ALTER DATABASE ZstdDemo_Copy SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ZstdDemo_Copy;');

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('E', 'restore of the ZSTD HIGH backup', CASE @e WHEN 0 THEN 'ran, ' + CAST(@ms AS varchar(20)) + ' ms' ELSE 'error ' + CAST(@e AS varchar(10)) END),
    ('E', 'rows in the copy / the original', ISNULL(CAST(@rows AS varchar(20)), '-') + ' / ' + CAST(@orig AS varchar(20)));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('E', 'a ZSTD backup restores like any other: no option names the algorithm',
     CASE @e WHEN 0 THEN 'restored, ' + CAST(@rows AS varchar(20)) + ' rows of ' + CAST(@orig AS varchar(20)) ELSE 'error ' + CAST(@e AS varchar(10)) END,
     CASE WHEN @e = 0 AND @rows = @orig THEN 'CONFIRMED' ELSE 'unexpected' END);
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
