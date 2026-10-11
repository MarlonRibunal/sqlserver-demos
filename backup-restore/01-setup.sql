/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, BackupDemo, in FULL recovery, and puts
     everything inside it. Nothing else on the instance is modified:

        - no instance setting is changed (not 'backup compression default',
          not 'backup checksum default': the demo says what it wants on each
          BACKUP statement)
        - no compatibility level is changed
        - no trace flag is set
        - no existing database is touched

     The DEMO goes further, and says so at the top of 02-demo.sql: it writes
     backup files into this instance's default backup folder, all named
     BackupDemo_*.bak; it restores them into a second database,
     BackupDemo_Copy; and every backup and restore adds history rows to
     msdb. 03-cleanup.sql removes all three: the files (one by one, by
     name), both databases, and their msdb history.

  Creates, all inside BackupDemo:
     Demo.Orders            - 100,000 orders
     Demo.Results           - one row per measurement
     Demo.usp_File          - the full path of one of the demo's backup files
     Demo.usp_Backup        - take a backup into one of those files
     Demo.usp_RestoreCopy   - restore a chain of them as BackupDemo_Copy
     Demo.usp_Reload        - put Demo.Orders back to its 100,000 rows

  COST: about 50 MB of data, plus up to about 150 MB of backup files.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create BackupDemo ===';
GO

IF DB_ID('BackupDemo') IS NOT NULL
BEGIN
    RAISERROR('BackupDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    -- A database left RESTORING by an interrupted demo can't be set to
    -- single user; it can be dropped as it is.
    IF DATABASEPROPERTYEX('BackupDemo', 'Status') = 'ONLINE'
        ALTER DATABASE BackupDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE BackupDemo;
END
GO

CREATE DATABASE BackupDemo;
GO

ALTER DATABASE BackupDemo SET RECOVERY FULL;
GO

USE BackupDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: tables ===';
GO

CREATE TABLE Demo.Orders
(
    OrderID    int            IDENTITY(1,1) NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    CustomerID int            NOT NULL,
    Amount     decimal(12,2)  NOT NULL,
    Batch      varchar(20)    NOT NULL,     -- which piece of work wrote the row
    pad        char(200)      NOT NULL CONSTRAINT DF_Orders_pad DEFAULT ('x')
);
GO

CREATE TABLE Demo.Results
(
    Scenario   char(1)        NOT NULL,
    Label      varchar(80)    NOT NULL,
    Value      bigint         NULL,
    Note       varchar(300)   NULL,
    CapturedAt datetime2(3)   NOT NULL CONSTRAINT DF_Results_CapturedAt DEFAULT SYSDATETIME()
);
GO


PRINT '=== STEP 3: procedures ===';
GO

-- Demo.Orders back to 100,000 rows, IDs from 1.
CREATE OR ALTER PROCEDURE Demo.usp_Reload
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE Demo.Orders;
    ;WITH n AS
    (
        SELECT TOP (100000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
        FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
    )
    INSERT Demo.Orders (CustomerID, Amount, Batch)
    SELECT rn % 5000 + 1, (rn % 1000) / 10.0, 'initial'
    FROM   n;
END
GO
EXEC Demo.usp_Reload;
GO

/*------------------------------------------------------------------------------
  Demo.usp_File -- the path of the demo's backup file @Name: this instance's
  default backup folder, then BackupDemo_<name>.bak. Every file the demo
  writes goes through here, so 03-cleanup.sql knows them all.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_File
    @Name sysname,
    @Path nvarchar(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @dir nvarchar(300) = CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(300));
    DECLARE @sep nchar(1) = CASE WHEN CHARINDEX(N'\', @dir) > 0 THEN N'\' ELSE N'/' END;
    IF RIGHT(@dir, 1) IN (N'\', N'/') SET @dir = LEFT(@dir, LEN(@dir) - 1);
    SET @Path = @dir + @sep + N'BackupDemo_' + @Name + N'.bak';
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_Backup -- BACKUP BackupDemo into file @Name, overwriting it.
  @Type: FULL, DIFF, LOG. @CopyOnly and @Compress as the names say. Every
  backup is taken WITH CHECKSUM.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Backup
    @Name     sysname,
    @Type     varchar(4),
    @CopyOnly bit = 0,
    @Compress bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @path nvarchar(400), @sql nvarchar(max);
    EXEC Demo.usp_File @Name, @path OUTPUT;
    SET @sql = CASE @Type WHEN 'LOG' THEN N'BACKUP LOG BackupDemo' ELSE N'BACKUP DATABASE BackupDemo' END
             + N' TO DISK = @p WITH INIT, FORMAT, CHECKSUM'
             + CASE WHEN @Type = 'DIFF' THEN N', DIFFERENTIAL' ELSE N'' END
             + CASE WHEN @CopyOnly = 1 THEN N', COPY_ONLY' ELSE N'' END
             + CASE WHEN @Compress = 1 THEN N', COMPRESSION' ELSE N', NO_COMPRESSION' END
             + N';';
    EXEC sys.sp_executesql @sql, N'@p nvarchar(400)', @p = @path;
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_RestoreCopy -- restore a chain of the demo's backups as
  BackupDemo_Copy, replacing any earlier copy. @Chain lists the files in
  order, each with its type: 'D:full|L:log1|L:log2' (D = full or
  differential database backup, L = log). Every file but the last is
  restored WITH NORECOVERY; the last WITH RECOVERY, and WITH STOPAT = @StopAt
  when given. The copy's files get their own names (MOVE).

  If a restore fails, @Error and @Message say why and the half-restored copy
  is dropped.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_RestoreCopy
    @Chain   nvarchar(400),
    @StopAt  datetime = NULL,
    @Error   int = NULL OUTPUT,
    @Message nvarchar(400) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @Error = 0, @Message = NULL;

    DECLARE @dataDir nvarchar(300) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(300));
    IF RIGHT(@dataDir, 1) NOT IN (N'\', N'/')
        SET @dataDir += CASE WHEN CHARINDEX(N'\', @dataDir) > 0 THEN N'\' ELSE N'/' END;

    IF DB_ID('BackupDemo_Copy') IS NOT NULL
    BEGIN
        IF DATABASEPROPERTYEX('BackupDemo_Copy', 'Status') = 'ONLINE'
            ALTER DATABASE BackupDemo_Copy SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        DROP DATABASE BackupDemo_Copy;
    END

    DECLARE @rest nvarchar(400) = @Chain + N'|', @item nvarchar(100), @type nchar(1), @name sysname,
            @path nvarchar(400), @last bit, @sql nvarchar(max),
            @mdf nvarchar(400) = @dataDir + N'BackupDemo_Copy.mdf', @ldf nvarchar(400) = @dataDir + N'BackupDemo_Copy_log.ldf';
    WHILE LEN(@rest) > 0
    BEGIN
        SET @item = LEFT(@rest, CHARINDEX(N'|', @rest) - 1);
        SET @rest = SUBSTRING(@rest, CHARINDEX(N'|', @rest) + 1, 400);
        SET @last = CASE WHEN LEN(@rest) = 0 THEN 1 ELSE 0 END;
        SET @type = LEFT(@item, 1);
        SET @name = SUBSTRING(@item, 3, 100);
        EXEC Demo.usp_File @name, @path OUTPUT;

        SET @sql = CASE @type WHEN N'L' THEN N'RESTORE LOG BackupDemo_Copy' ELSE N'RESTORE DATABASE BackupDemo_Copy' END
                 + N' FROM DISK = @p WITH CHECKSUM'
                 + CASE WHEN @type = N'D'
                        THEN N', REPLACE, MOVE N''BackupDemo'' TO @d, MOVE N''BackupDemo_log'' TO @l' ELSE N'' END
                 + CASE WHEN @last = 1 THEN N', RECOVERY' ELSE N', NORECOVERY' END
                 + CASE WHEN @last = 1 AND @StopAt IS NOT NULL AND @type = N'L' THEN N', STOPAT = @s' ELSE N'' END
                 + N';';
        BEGIN TRY
            EXEC sys.sp_executesql @sql, N'@p nvarchar(400), @d nvarchar(400), @l nvarchar(400), @s datetime',
                 @p = @path, @d = @mdf, @l = @ldf, @s = @StopAt;
        END TRY
        BEGIN CATCH
            SELECT @Error = ERROR_NUMBER(), @Message = LEFT(ERROR_MESSAGE(), 400);
            IF DB_ID('BackupDemo_Copy') IS NOT NULL DROP DATABASE BackupDemo_Copy;
            RETURN;
        END CATCH
    END
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the BackupDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It writes backup files: read its header first.';
PRINT '========================================================';
GO
