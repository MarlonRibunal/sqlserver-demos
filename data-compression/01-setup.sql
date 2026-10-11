/*==============================================================================
  01-setup.sql          RUN ONCE. Takes under a minute.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, CompressionDemo, and puts everything inside
     it. Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched

  Creates, all inside CompressionDemo:
     Demo.Source          - 1,000,000 order rows, the data every copy is made
                            from: realistic repetition (6 countries, 4
                            statuses, 3 notes, small numbers)
     Demo.Results         - one row per measurement
     Demo.usp_Build       - copy Demo.Source into a table with a given
                            compression, and record its size and build cost
     Demo.usp_Scan        - scan a copy, and record reads and CPU
     Demo.usp_Pages       - pages a table uses (in-row and LOB)

  The demo builds every compressed copy itself, so each run starts from the
  same state.

  COST: about 600 MB of data plus transaction log at the demo's peak, all
  inside CompressionDemo.

  Data compression is in every edition since SQL Server 2016 SP1.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create CompressionDemo ===';
GO

IF DB_ID('CompressionDemo') IS NOT NULL
BEGIN
    RAISERROR('CompressionDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE CompressionDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE CompressionDemo;
END
GO

CREATE DATABASE CompressionDemo;
GO

ALTER DATABASE CompressionDemo SET RECOVERY SIMPLE;
GO

USE CompressionDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: Demo.Source ===';
GO

/*------------------------------------------------------------------------------
  Order data as most order tables look: dates that advance, customer IDs
  that fit in two bytes, a handful of countries and statuses, amounts with
  far fewer digits than decimal(19,4) allows, and a fixed-width char column
  mostly made of trailing spaces. That repetition is what compression feeds
  on; scenario D shows data without it.
------------------------------------------------------------------------------*/
CREATE TABLE Demo.Source
(
    OrderID    int            NOT NULL CONSTRAINT PK_Source PRIMARY KEY CLUSTERED,
    OrderDate  datetime2(0)   NOT NULL,
    CustomerID int            NOT NULL,
    Country    varchar(30)    NOT NULL,
    Status     char(12)       NOT NULL,
    Amount     decimal(19,4)  NOT NULL,
    Quantity   int            NOT NULL,
    Note       char(60)       NOT NULL
);

;WITH n AS
(
    SELECT TOP (1000000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b CROSS JOIN sys.all_columns AS c
)
INSERT Demo.Source WITH (TABLOCK)
SELECT rn,
       DATEADD(minute, rn / 3, '2025-01-01'),
       rn % 20000 + 1,
       CHOOSE(rn % 6 + 1, 'United States', 'Germany', 'Japan', 'Brazil', 'India', 'Philippines'),
       CHOOSE(rn % 4 + 1, 'Shipped', 'Pending', 'Cancelled', 'Returned'),
       (rn % 5000) * 1.25,
       rn % 10 + 1,
       CHOOSE(rn % 3 + 1, 'Standard delivery', 'Express', 'Pickup in store')
FROM   n;
GO


PRINT '=== STEP 3: the harness ===';
GO

CREATE TABLE Demo.Results
(
    Scenario   char(1)        NOT NULL,
    Label      varchar(60)    NOT NULL,
    Pages      bigint         NULL,
    LobPages   bigint         NULL,
    Reads      bigint         NULL,
    CpuMs      decimal(12,1)  NULL,
    Note       varchar(200)   NULL,
    CapturedAt datetime2(3)   NOT NULL CONSTRAINT DF_Results_CapturedAt DEFAULT SYSDATETIME()
);
GO

-- Pages a table uses, in all: in-row, row-overflow and LOB.
CREATE OR ALTER PROCEDURE Demo.usp_Pages
    @Table    sysname,
    @Pages    bigint OUTPUT,
    @LobPages bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @Pages = SUM(used_page_count), @LobPages = SUM(lob_used_page_count)
    FROM   sys.dm_db_partition_stats
    WHERE  object_id = OBJECT_ID(@Table);
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_Build -- (re)create @Table as a copy of Demo.Source with
  @Compression: NONE, ROW or PAGE (a clustered primary key), or COLUMNSTORE
  or COLUMNSTORE_ARCHIVE (a clustered columnstore index). The copy is loaded
  uncompressed, then the index is built with the compression -- the way
  you'd compress an existing table -- and the CPU of that step is recorded.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Build
    @Table       sysname,
    @Compression varchar(30)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql nvarchar(max), @c0 int, @c1 int, @pages bigint, @lob bigint;

    SET @sql = N'DROP TABLE IF EXISTS ' + @Table + N';
                 SELECT * INTO ' + @Table + N' FROM Demo.Source;';
    EXEC (@sql);

    IF @Compression LIKE 'COLUMNSTORE%'
        SET @sql = N'CREATE CLUSTERED COLUMNSTORE INDEX CCI_' + PARSENAME(@Table, 1) + N' ON ' + @Table
                 + N' WITH (DATA_COMPRESSION = ' + @Compression + N', MAXDOP = 1);';
    ELSE
        SET @sql = N'ALTER TABLE ' + @Table + N' ADD CONSTRAINT PK_' + PARSENAME(@Table, 1)
                 + N' PRIMARY KEY CLUSTERED (OrderID) WITH (DATA_COMPRESSION = ' + @Compression + N', MAXDOP = 1);';

    SELECT @c0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    EXEC (@sql);
    SELECT @c1 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;

    EXEC Demo.usp_Pages @Table, @pages OUTPUT, @lob OUTPUT;
    INSERT Demo.Results (Scenario, Label, Pages, LobPages, CpuMs)
    VALUES ('A', @Compression, @pages, @lob, @c1 - @c0);
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_Scan -- the same report query over @Table: total value and
  distinct customers of shipped orders. Serial (MAXDOP 1), so the CPU
  figure is the work done rather than how many threads did it. Run once to
  warm the cache, then 3 times measured; reads and CPU per run.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Scan
    @Table sysname,
    @Label varchar(60)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r0 bigint, @c0 int, @r1 bigint, @c1 int,
            @sql nvarchar(400) = N'DECLARE @s decimal(38,4), @n bigint;
                SELECT @s = SUM(Amount * Quantity), @n = COUNT(DISTINCT CustomerID)
                FROM ' + @Table + N' WHERE Status = ''Shipped'' OPTION (MAXDOP 1);';
    EXEC (@sql);
    SELECT @r0 = logical_reads, @c0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    EXEC (@sql); EXEC (@sql); EXEC (@sql);
    SELECT @r1 = logical_reads, @c1 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    INSERT Demo.Results (Scenario, Label, Reads, CpuMs)
    VALUES ('C', @Label, (@r1 - @r0) / 3, (@c1 - @c0) / 3.0);
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the CompressionDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
