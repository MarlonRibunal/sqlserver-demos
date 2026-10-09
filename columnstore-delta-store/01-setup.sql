/*==============================================================================
  01-setup.sql          RUN ONCE. Takes about a minute.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, ColumnstoreDemo, and puts everything inside
     it. Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched

  Creates, all inside ColumnstoreDemo:
     Demo.Source            - 6,000,000 rows, a plain heap: the data every
                              columnstore table here is loaded from
     Demo.Ordered           - clustered columnstore, rowgroups in date order
     Demo.Unordered         - the same rows, rowgroups in no date order
     Demo.RowGroups         - one row per rowgroup per snapshot
     Demo.ScanCosts         - one row per measured query
     Demo.usp_SnapshotRowGroups, Demo.usp_MeasureScan

  Scenarios A to C in 02-demo.sql build their own small columnstore tables,
  so the demo can be re-run without re-running this.

  COST: about 1 GB of data plus transaction log at its peak, all inside
  ColumnstoreDemo. Columnstore is available in every edition from SQL Server
  2016 SP1.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create ColumnstoreDemo ===';
GO

IF DB_ID('ColumnstoreDemo') IS NOT NULL
BEGIN
    RAISERROR('ColumnstoreDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE ColumnstoreDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE ColumnstoreDemo;
END
GO

CREATE DATABASE ColumnstoreDemo;
GO

ALTER DATABASE ColumnstoreDemo SET RECOVERY SIMPLE;
GO

USE ColumnstoreDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: Demo.Source, 6,000,000 rows ===';
GO

/*------------------------------------------------------------------------------
  Six million sales rows, 2,000 a day from 2018-01-01: SaleDate ascends with
  SaleID. Amount cycles 0..999, so it is spread evenly across every date.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.Source;
GO

CREATE TABLE Demo.Source
(
    SaleID   int  NOT NULL,
    SaleDate date NOT NULL,
    Amount   int  NOT NULL,
    StoreID  int  NOT NULL
);
GO

;WITH n AS
(
    SELECT TOP (6000000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b CROSS JOIN sys.all_columns AS c
)
INSERT Demo.Source WITH (TABLOCK) (SaleID, SaleDate, Amount, StoreID)
SELECT rn, DATEADD(day, (rn - 1) / 2000, CAST('20180101' AS date)), rn % 1000, rn % 50
FROM   n;
GO


PRINT '=== STEP 3: two columnstore tables, ordered and not (scenario D) ===';
GO

/*------------------------------------------------------------------------------
  The same 6,000,000 rows, compressed into six rowgroups of about a million
  rows each. The difference is which rows share a rowgroup.

     Demo.Ordered    rowstore clustered index on SaleDate first, then
                     converted with DROP_EXISTING and MAXDOP 1. Each rowgroup
                     holds a contiguous range of dates.

     Demo.Unordered  the same, but the rowstore index is on Amount. Every
                     rowgroup holds every date.

  This is the reliable way to order a columnstore on SQL Server 2016-2019.
  INSERT ... SELECT ... ORDER BY into a columnstore does NOT order its
  rowgroups -- the README has the measurement. (SQL Server 2022 also adds an
  ORDER clause to CREATE CLUSTERED COLUMNSTORE INDEX.)

  MAXDOP 1 matters: a parallel build splits the input across threads, and
  each thread's rowgroups interleave the ranges again.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.Ordered, Demo.Unordered;
GO

SELECT SaleID, SaleDate, Amount, StoreID INTO Demo.Ordered   FROM Demo.Source;
SELECT SaleID, SaleDate, Amount, StoreID INTO Demo.Unordered FROM Demo.Source;
GO

CREATE CLUSTERED INDEX CCI_Ordered   ON Demo.Ordered   (SaleDate);
CREATE CLUSTERED INDEX CCI_Unordered ON Demo.Unordered (Amount);
GO

CREATE CLUSTERED COLUMNSTORE INDEX CCI_Ordered   ON Demo.Ordered   WITH (DROP_EXISTING = ON, MAXDOP = 1);
CREATE CLUSTERED COLUMNSTORE INDEX CCI_Unordered ON Demo.Unordered WITH (DROP_EXISTING = ON, MAXDOP = 1);
GO


PRINT '=== STEP 4: evidence tables and procedures ===';
GO

DROP TABLE IF EXISTS Demo.RowGroups;
CREATE TABLE Demo.RowGroups
(
    Label       varchar(60)   NOT NULL,
    TableName   sysname       NOT NULL,
    RowGroupID  int           NOT NULL,
    State       varchar(20)   NULL,     -- OPEN / CLOSED = delta store (rowstore); COMPRESSED; TOMBSTONE
    TotalRows   bigint        NULL,
    SizeKB      decimal(18,1) NULL,
    TrimReason  varchar(40)   NULL,
    CapturedAt  datetime2(3)  NOT NULL CONSTRAINT DF_CSRG_CapturedAt DEFAULT SYSDATETIME()
);

DROP TABLE IF EXISTS Demo.ScanCosts;
CREATE TABLE Demo.ScanCosts
(
    Label        varchar(60)  NOT NULL,
    TableName    sysname      NOT NULL,
    LogicalReads bigint       NULL,
    CpuMs        int          NULL,
    Answer       bigint       NULL,
    CapturedAt   datetime2(3) NOT NULL CONSTRAINT DF_CSScan_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  Rowgroup states, from sys.dm_db_column_store_row_group_physical_stats:

     OPEN        a delta store still accepting rows. It is a ROWSTORE b-tree:
                 uncompressed, read row by row.
     CLOSED      a full delta store (1,048,576 rows), waiting for the
                 background tuple mover to compress it.
     COMPRESSED  real columnstore.
     TOMBSTONE   a delta store that has been compressed and is waiting to be
                 deallocated.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_SnapshotRowGroups
    @Label varchar(60),
    @Table sysname
AS
BEGIN
    SET NOCOUNT ON;
    INSERT Demo.RowGroups (Label, TableName, RowGroupID, State, TotalRows, SizeKB, TrimReason)
    SELECT @Label, @Table, row_group_id, state_desc, total_rows, size_in_bytes / 1024.0, trim_reason_desc
    FROM   sys.dm_db_column_store_row_group_physical_stats
    WHERE  object_id = OBJECT_ID(@Table);
END
GO

/*------------------------------------------------------------------------------
  Total Amount for one day -- optionally a predicate on SaleDate -- measured
  warm: run twice, record the second. Reads and CPU are deltas of
  sys.dm_exec_requests for this session, which include the LOB reads that
  columnstore segments are counted as.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_MeasureScan
    @Label     varchar(60),
    @Table     sysname,
    @OneDay    date = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tbl nvarchar(300) = QUOTENAME(PARSENAME(@Table, 2)) + N'.' + QUOTENAME(PARSENAME(@Table, 1));
    DECLARE @sql nvarchar(max) =
        N'SELECT @a = SUM(CAST(Amount AS bigint)) FROM ' + @tbl
      + CASE WHEN @OneDay IS NULL THEN N'' ELSE N' WHERE SaleDate = @d' END
      + N' OPTION (MAXDOP 1);';
    DECLARE @a bigint, @r0 bigint, @c0 int, @reads bigint, @cpu int;

    EXEC sys.sp_executesql @sql, N'@d date, @a bigint OUTPUT', @d = @OneDay, @a = @a OUTPUT;
    SELECT @r0 = logical_reads, @c0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    EXEC sys.sp_executesql @sql, N'@d date, @a bigint OUTPUT', @d = @OneDay, @a = @a OUTPUT;
    SELECT @reads = logical_reads - @r0, @cpu = cpu_time - @c0 FROM sys.dm_exec_requests WHERE session_id = @@SPID;

    INSERT Demo.ScanCosts (Label, TableName, LogicalReads, CpuMs, Answer)
    VALUES (@Label, @Table, @reads, @cpu, @a);
END
GO

EXEC Demo.usp_SnapshotRowGroups 'setup: ordered',   'Demo.Ordered';
EXEC Demo.usp_SnapshotRowGroups 'setup: unordered', 'Demo.Unordered';
SELECT TableName, RowGroups = COUNT(*), Rows = SUM(TotalRows), SizeMB = CAST(SUM(SizeKB) / 1024 AS decimal(8,1))
FROM   Demo.RowGroups GROUP BY TableName;
TRUNCATE TABLE Demo.RowGroups;
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the ColumnstoreDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
