/*==============================================================================
  01-setup.sql          RUN ONCE. Takes about 15 seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates TWO new databases, and nothing else:

       ZstdDemo        - 1,000,000 rows of repetitive text and numbers,
                         about 170 MB: data that compresses well
       ZstdDemoRandom  - 100,000 rows of random bytes, about 45 MB: data
                         that doesn't, like encrypted or already-compressed
                         data

     02-demo.sql writes backup files to this instance's default backup
     folder, every one named ZstdDemo_*.bak, and restores one of them as a
     third database, ZstdDemo_Copy, which it drops again. 03-cleanup.sql
     deletes those files by name.

  ON SQL SERVER 2022 AND EARLIER the databases are created, and the demo
  reports every scenario as SKIPPED: ZSTD backup compression arrived in
  2025.

  TESTED end to end on SQL Server 2025 RTM-CU9-GDR (17.0.5015.4), Linux
  container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create the databases ===';
GO

DECLARE @db sysname;
DECLARE d CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM (VALUES (N'ZstdDemo_Copy'), (N'ZstdDemoRandom'), (N'ZstdDemo')) AS v (name);
OPEN d;
FETCH NEXT FROM d INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF DB_ID(@db) IS NOT NULL
    BEGIN
        RAISERROR('%s already exists. Dropping it first.', 0, 1, @db) WITH NOWAIT;
        EXEC (N'ALTER DATABASE ' + @db + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + @db + N';');
    END
    FETCH NEXT FROM d INTO @db;
END
CLOSE d; DEALLOCATE d;
GO

CREATE DATABASE ZstdDemo;
GO
CREATE DATABASE ZstdDemoRandom;
GO
ALTER DATABASE ZstdDemo SET RECOVERY SIMPLE;
ALTER DATABASE ZstdDemoRandom SET RECOVERY SIMPLE;
GO


PRINT '=== STEP 2: ZstdDemo: data that compresses ===';
GO

USE ZstdDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO

CREATE TABLE Demo.Orders
(
    OrderID  int            NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    Note     varchar(200)   NOT NULL,
    Code     char(100)      NOT NULL,
    Amount   decimal(12,2)  NOT NULL
);
GO

;WITH n AS
(
    SELECT TOP (1000000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.Orders WITH (TABLOCK) (OrderID, Note, Code, Amount)
SELECT rn,
       CONCAT('Customer ', rn % 5000, ' ordered item ', rn % 300, ' in region ', rn % 7),
       'x',
       rn % 1000
FROM   n;
GO

-- The harness lives here too.
CREATE TABLE Demo.Results
(
    Scenario  char(1)        NOT NULL,
    Item      varchar(120)   NOT NULL,
    Value     varchar(400)   NULL,
    Seq       int            IDENTITY(1,1) NOT NULL
);
GO

CREATE TABLE Demo.Verdicts
(
    Scenario  char(1)        NOT NULL,
    Claim     varchar(200)   NOT NULL,
    Evidence  varchar(400)   NULL,
    Verdict   varchar(30)    NOT NULL,
    Seq       int            IDENTITY(1,1) NOT NULL
);
GO

/*------------------------------------------------------------------------------
  Demo.usp_Backup -- back up @Database to <default backup folder>/ZstdDemo_
  <@File>.bak with the given compression, WITH FORMAT (a new media set every
  time), and return the elapsed ms, the compressed size in bytes, and the
  algorithm msdb recorded. @Option is the WITH clause's compression part,
  for example 'COMPRESSION (ALGORITHM = ZSTD, LEVEL = LOW)'.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Backup
    @Database   sysname,
    @File       sysname,
    @Option     nvarchar(200),
    @Ms         int           OUTPUT,
    @Bytes      bigint        OUTPUT,
    @Algorithm  nvarchar(40)  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @dir nvarchar(300) = CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(300));
    DECLARE @sep nchar(1) = CASE WHEN CHARINDEX(N'\', @dir) > 0 THEN N'\' ELSE N'/' END;
    IF RIGHT(@dir, 1) IN (N'\', N'/') SET @dir = LEFT(@dir, LEN(@dir) - 1);
    DECLARE @path nvarchar(400) = @dir + @sep + N'ZstdDemo_' + @File + N'.bak',
            @t0 datetime2 = SYSDATETIME();

    EXEC (N'BACKUP DATABASE ' + @Database + N' TO DISK = N''' + @path + N''' WITH INIT, FORMAT, ' + @Option + N';');
    SET @Ms = DATEDIFF(ms, @t0, SYSDATETIME());

    -- backupset.compression_algorithm exists from SQL Server 2022, so this is
    -- dynamic SQL: a static reference fails to compile on 2019.
    EXEC sys.sp_executesql N'
    SELECT TOP (1) @Bytes = bs.compressed_backup_size, @Algorithm = ISNULL(bs.compression_algorithm, N''none'')
    FROM   msdb.dbo.backupset AS bs
    JOIN   msdb.dbo.backupmediafamily AS mf ON mf.media_set_id = bs.media_set_id
    WHERE  mf.physical_device_name = @path
    ORDER BY bs.backup_set_id DESC;',
         N'@path nvarchar(400), @Bytes bigint OUTPUT, @Algorithm nvarchar(40) OUTPUT',
         @path = @path, @Bytes = @Bytes OUTPUT, @Algorithm = @Algorithm OUTPUT;
END
GO


PRINT '=== STEP 3: ZstdDemoRandom: data that doesn''t ===';
GO

USE ZstdDemoRandom;
GO
SET NOCOUNT ON;
GO

CREATE TABLE dbo.Blobs
(
    ID    int           NOT NULL CONSTRAINT PK_Blobs PRIMARY KEY CLUSTERED,
    Data  binary(400)   NOT NULL
);
GO

;WITH n AS
(
    SELECT TOP (100000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT dbo.Blobs WITH (TABLOCK) (ID, Data)
SELECT rn, CAST(CRYPT_GEN_RANDOM(400) AS binary(400))
FROM   n;
GO

USE master;
GO

PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Created ZstdDemo and ZstdDemoRandom.';
PRINT ' No instance setting was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
