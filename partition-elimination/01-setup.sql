/*==============================================================================
  01-setup.sql          RUN ONCE. Takes about half a minute.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, PartitionDemo, and puts everything inside
     it. Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched

  Creates, all inside PartitionDemo:
     PF_Monthly / PS_Monthly  - monthly partitions for 2024 and 2025
                                (25 partitions: one empty before 2024-01)
     Demo.Sales               - 2,400,000 sales, clustered on (SaleDate,
                                SaleID), partitioned by SaleDate
     IX_Sales_SaleID          - nonclustered on SaleID, ALIGNED (partitioned)
     Demo.SwitchTest          - a small copy, partitioned the same way, for
                                the SWITCH test (scenario E)
     Demo.SalesStage          - an empty table to switch into
     Demo.Touches             - one row per measured query
     Demo.usp_Touch           - runs a query and counts partitions it read

  The NON-aligned indexes that scenarios D and E need are created and
  dropped by 02-demo.sql itself, so most of the demo runs without them.

  COST: about 500 MB of data plus transaction log, all inside PartitionDemo.
  Partitioning is available in every edition from SQL Server 2016 SP1.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create PartitionDemo ===';
GO

IF DB_ID('PartitionDemo') IS NOT NULL
BEGIN
    RAISERROR('PartitionDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE PartitionDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE PartitionDemo;
END
GO

CREATE DATABASE PartitionDemo;
GO

ALTER DATABASE PartitionDemo SET RECOVERY SIMPLE;
GO

USE PartitionDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: monthly partitions ===';
GO

-- 24 boundaries, the first of each month of 2024 and 2025. RANGE RIGHT, so
-- each boundary starts a partition: partition 2 is January 2024 and
-- partition 25 is December 2025. Partition 1 holds anything earlier, and is
-- empty.
DECLARE @b nvarchar(max) = N'', @m int = 0;
WHILE @m < 24
BEGIN
    SET @b += CASE WHEN @m > 0 THEN N', ' ELSE N'' END
            + N'''' + CONVERT(nvarchar(10), DATEADD(month, @m, CAST('20240101' AS date)), 112) + N'''';
    SET @m += 1;
END
EXEC (N'CREATE PARTITION FUNCTION PF_Monthly (date) AS RANGE RIGHT FOR VALUES (' + @b + N');');
GO

CREATE PARTITION SCHEME PS_Monthly AS PARTITION PF_Monthly ALL TO ([PRIMARY]);
GO


PRINT '=== STEP 3: Demo.Sales, 2,400,000 rows ===';
GO

CREATE TABLE Demo.Sales
(
    SaleID   int        NOT NULL,
    SaleDate date       NOT NULL,
    Amount   int        NOT NULL,
    pad      char(100)  NOT NULL CONSTRAINT DF_Sales_pad DEFAULT ('x'),
    CONSTRAINT PK_Sales PRIMARY KEY CLUSTERED (SaleDate, SaleID) ON PS_Monthly (SaleDate)
);
GO

;WITH n AS
(
    SELECT TOP (2400000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b CROSS JOIN sys.all_columns AS c
)
INSERT Demo.Sales WITH (TABLOCK) (SaleID, SaleDate, Amount)
SELECT rn, DATEADD(day, (rn - 1) % 731, CAST('20240101' AS date)), rn % 1000
FROM   n;
GO

-- Aligned: built on the same partition scheme, so each partition of the
-- table has its own slice of this index.
CREATE INDEX IX_Sales_SaleID ON Demo.Sales (SaleID) ON PS_Monthly (SaleDate);
GO

SELECT PartitionNumber = partition_number, Rows = rows
FROM   sys.partitions
WHERE  object_id = OBJECT_ID('Demo.Sales') AND index_id = 1 AND partition_number IN (1, 2, 15, 25)
ORDER BY partition_number;
GO

/*------------------------------------------------------------------------------
  Scenario E's tables. Switching is tested on its OWN small partitioned table,
  Demo.SwitchTest, not on Demo.Sales: a SWITCH (even one rolled back) and the
  index DDL around it reset the per-partition counters that every other
  scenario relies on.
------------------------------------------------------------------------------*/
CREATE TABLE Demo.SwitchTest
(
    SaleID   int        NOT NULL,
    SaleDate date       NOT NULL,
    Amount   int        NOT NULL,
    pad      char(100)  NOT NULL CONSTRAINT DF_SwitchTest_pad DEFAULT ('x'),
    CONSTRAINT PK_SwitchTest PRIMARY KEY CLUSTERED (SaleDate, SaleID) ON PS_Monthly (SaleDate)
);
CREATE INDEX IX_SwitchTest_SaleID ON Demo.SwitchTest (SaleID) ON PS_Monthly (SaleDate);
INSERT Demo.SwitchTest (SaleID, SaleDate, Amount)
SELECT SaleID, SaleDate, Amount FROM Demo.Sales WHERE SaleID % 100 = 0;
GO

-- The SWITCH target: same columns and indexes, not partitioned, empty.
CREATE TABLE Demo.SalesStage
(
    SaleID   int        NOT NULL,
    SaleDate date       NOT NULL,
    Amount   int        NOT NULL,
    pad      char(100)  NOT NULL CONSTRAINT DF_SalesStage_pad DEFAULT ('x'),
    CONSTRAINT PK_SalesStage PRIMARY KEY CLUSTERED (SaleDate, SaleID)
);
CREATE INDEX IX_SalesStage_SaleID ON Demo.SalesStage (SaleID);
GO


PRINT '=== STEP 4: the evidence table and the harness ===';
GO

DROP TABLE IF EXISTS Demo.Touches;
CREATE TABLE Demo.Touches
(
    TouchID          int           IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Scenario         varchar(60)   NOT NULL,
    Item             varchar(90)   NOT NULL,
    PartitionsRead   int           NULL,
    LogicalReads     bigint        NULL,
    Expected         nvarchar(140) NULL,
    ExpectedParts    int           NULL,
    CapturedAt       datetime2(3)  NOT NULL CONSTRAINT DF_PDTouch_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  Demo.usp_Touch -- run @Sql twice and measure the second, warm run:

     PartitionsRead  partitions of Demo.Sales (any index) whose
                     range_scan_count or singleton_lookup_count in
                     sys.dm_db_index_operational_stats went up during the
                     run -- the partitions the query actually opened
     LogicalReads    a delta of sys.dm_exec_requests for this session

  Counting partitions this way needs no actual execution plan, which a
  script cannot capture for itself.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Touch
    @Scenario      varchar(60),
    @Item          varchar(90),
    @Sql           nvarchar(max),
    @Expected      nvarchar(140) = NULL,
    @ExpectedParts int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sys.sp_executesql @Sql;      -- warm-up and compile

    DECLARE @before TABLE (IndexID int, PartitionNumber int, Scans bigint, Lookups bigint);
    INSERT @before
    SELECT index_id, partition_number, range_scan_count, singleton_lookup_count
    FROM   sys.dm_db_index_operational_stats(DB_ID(), OBJECT_ID('Demo.Sales'), NULL, NULL);

    DECLARE @r0 bigint = (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID);
    EXEC sys.sp_executesql @Sql;
    DECLARE @reads bigint = (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0;

    -- LEFT JOIN: these counters live in a metadata cache, and an entry
    -- missing from the "before" snapshot simply had not been loaded yet --
    -- its counts start from zero, so anything above zero is this run's.
    INSERT Demo.Touches (Scenario, Item, PartitionsRead, LogicalReads, Expected, ExpectedParts)
    SELECT @Scenario, @Item, COUNT(DISTINCT a.partition_number), @reads, @Expected, @ExpectedParts
    FROM   sys.dm_db_index_operational_stats(DB_ID(), OBJECT_ID('Demo.Sales'), NULL, NULL) AS a
    LEFT JOIN @before AS b ON b.IndexID = a.index_id AND b.PartitionNumber = a.partition_number
    WHERE  a.range_scan_count > ISNULL(b.Scans, 0) OR a.singleton_lookup_count > ISNULL(b.Lookups, 0);
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the PartitionDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
