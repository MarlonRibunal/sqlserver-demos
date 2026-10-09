/*==============================================================================
  01-setup.sql          RUN ONCE. Takes under a minute.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, TippingPointDemo, and puts everything inside
     it. Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched
        - no plan cache flush of any kind

  Creates, all inside TippingPointDemo:
     Demo.Narrow          - 1,000,000 rows of about 60 bytes
     Demo.Wide            - the same rows, about 320 bytes each
     Demo.Runs            - one row per measured execution
     Demo.usp_Measure     - runs the query one way and records what it cost

  COST: about 1.1 GB of data plus transaction log, all inside
  TippingPointDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
-- Demo.usp_Measure uses XML methods, which fail with Msg 1934 unless the
-- procedure was CREATED under QUOTED_IDENTIFIER ON. SSMS defaults it ON;
-- sqlcmd does not (pass -I). Setting it here makes the file safe either way.
SET QUOTED_IDENTIFIER ON;
GO

PRINT '=== STEP 1: create TippingPointDemo ===';
GO

IF DB_ID('TippingPointDemo') IS NOT NULL
BEGIN
    RAISERROR('TippingPointDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE TippingPointDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE TippingPointDemo;
END
GO

CREATE DATABASE TippingPointDemo;
GO

ALTER DATABASE TippingPointDemo SET RECOVERY SIMPLE;
GO

USE TippingPointDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: two tables, the same rows, different widths ===';
GO

/*------------------------------------------------------------------------------
  1,000,000 orders for 100,000 customers, exactly 10 orders each. So
  "CustomerID <= @n" matches exactly 10 x @n rows, and the demo can ask for
  any fraction of the table it likes.

  CustomerID is NOT the clustered key, and customers' orders are spread
  across the table (OrderID order is not CustomerID order) -- so the rows a
  range of customers needs are scattered over many pages, as they would be in
  a real orders table.

  The nonclustered index on CustomerID does not include Amount. Every row it
  finds has to be looked up in the clustered index to get Amount. That lookup
  is what this topic is about.

  Demo.Narrow and Demo.Wide differ only in the width of a pad column, so the
  same number of rows lives on very different numbers of pages.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.Narrow, Demo.Wide;
GO

CREATE TABLE Demo.Narrow
(
    OrderID    int       NOT NULL,
    CustomerID int       NOT NULL,
    Amount     int       NOT NULL,
    pad        char(40)  NOT NULL CONSTRAINT DF_Narrow_pad DEFAULT ('x'),
    CONSTRAINT PK_Narrow PRIMARY KEY CLUSTERED (OrderID)
);

CREATE TABLE Demo.Wide
(
    OrderID    int       NOT NULL,
    CustomerID int       NOT NULL,
    Amount     int       NOT NULL,
    pad        char(300) NOT NULL CONSTRAINT DF_Wide_pad DEFAULT ('x'),
    CONSTRAINT PK_Wide PRIMARY KEY CLUSTERED (OrderID)
);
GO

;WITH n AS
(
    SELECT TOP (1000000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b CROSS JOIN sys.all_columns AS c
)
INSERT Demo.Narrow WITH (TABLOCK) (OrderID, CustomerID, Amount)
SELECT rn,
       (rn - 1) % 100000 + 1,          -- customer 1 owns orders 1, 100001, 200001 ...
       rn % 1000
FROM   n;

INSERT Demo.Wide WITH (TABLOCK) (OrderID, CustomerID, Amount)
SELECT OrderID, CustomerID, Amount FROM Demo.Narrow;
GO

CREATE INDEX IX_Narrow_CustomerID ON Demo.Narrow (CustomerID);
CREATE INDEX IX_Wide_CustomerID   ON Demo.Wide   (CustomerID);
GO

SELECT  TableName   = OBJECT_SCHEMA_NAME(ps.object_id) + '.' + OBJECT_NAME(ps.object_id),
        Rows        = SUM(ps.row_count),
        DataPages   = SUM(ps.in_row_data_page_count),
        RowsPerPage = CAST(SUM(ps.row_count) * 1.0 / SUM(ps.in_row_data_page_count) AS decimal(8,1))
FROM    sys.dm_db_partition_stats AS ps
WHERE   ps.object_id IN (OBJECT_ID('Demo.Narrow'), OBJECT_ID('Demo.Wide'))
  AND   ps.index_id = 1
GROUP BY ps.object_id;
GO


PRINT '=== STEP 3: the evidence table and the harness ===';
GO

DROP TABLE IF EXISTS Demo.Runs;
CREATE TABLE Demo.Runs
(
    RunID        int           IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Scenario     varchar(60)   NOT NULL,
    TableName    sysname       NOT NULL,
    Mode         varchar(10)   NOT NULL,     -- auto | seek | scan | covered
    TargetRows   int           NOT NULL,
    PctOfTable   decimal(7,3)  NOT NULL,
    PlanShape    varchar(40)   NULL,         -- what the plan did to reach the rows
    EstimateRows decimal(18,1) NULL,
    LogicalReads bigint        NULL,
    CpuMs        int           NULL,
    CapturedAt   datetime2(3)  NOT NULL CONSTRAINT DF_TPRuns_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  Demo.usp_Measure -- run "total Amount for customers 1..@n" against @Table
  one way, and record what it cost.

     auto     no hint: the optimizer chooses
     seek     WITH (INDEX(IX_..._CustomerID)): seek + one lookup per row
     scan     WITH (INDEX(1)): read the whole clustered index once
     covered  as auto, for scenario C, after a covering index exists

  Each statement text carries a marker naming its table, mode and row count,
  so every run compiles its own plan for its own value -- no plan reuse
  across row counts, no parameter sniffing in the way -- and the harness can
  find that plan in the cache to read the shape and the estimate.

  Reads and CPU are deltas of sys.dm_exec_requests for this session, around
  the second of two executions (the first warms the cache and compiles).
  OPTION (MAXDOP 1) keeps the comparison serial: a parallel scan would make
  the scan side look cheaper on elapsed time without reading fewer pages.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Measure
    @Scenario   varchar(60),
    @Table      sysname,
    @Mode       varchar(10),
    @TargetRows int
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @name   sysname       = PARSENAME(@Table, 1);
    DECLARE @tbl    nvarchar(300) = QUOTENAME(PARSENAME(@Table, 2)) + N'.' + QUOTENAME(@name);
    DECLARE @marker nvarchar(60)  = N'TP:' + @name + N':' + @Mode + N':' + CAST(@TargetRows AS nvarchar(10));
    DECLARE @hint   nvarchar(100) =
        CASE @Mode WHEN 'seek' THEN N' WITH (INDEX(' + QUOTENAME(N'IX_' + @name + N'_CustomerID') + N'))'
                   WHEN 'scan' THEN N' WITH (INDEX(1))'
                   ELSE N'' END;
    DECLARE @sql nvarchar(max) =
        N'SELECT @t = SUM(CAST(Amount AS bigint)) /*' + @marker + N'*/ FROM ' + @tbl + @hint
      + N' WHERE CustomerID <= @n OPTION (MAXDOP 1);';
    DECLARE @n int = @TargetRows / 10, @t bigint, @r0 bigint, @c0 bigint, @reads bigint, @cpu int;

    EXEC sys.sp_executesql @sql, N'@n int, @t bigint OUTPUT', @n = @n, @t = @t OUTPUT;   -- warm-up

    SELECT @r0 = logical_reads, @c0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    EXEC sys.sp_executesql @sql, N'@n int, @t bigint OUTPUT', @n = @n, @t = @t OUTPUT;
    SELECT @reads = logical_reads - @r0, @cpu = cpu_time - @c0 FROM sys.dm_exec_requests WHERE session_id = @@SPID;

    DECLARE @plan xml;
    DECLARE @pattern nvarchar(80) = N'%' + @marker + N'*/%';

    SELECT TOP (1) @plan = qp.query_plan
    FROM   sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
    WHERE  st.text LIKE @pattern
      AND  st.text NOT LIKE N'%usp_Measure%'
      AND  qp.query_plan IS NOT NULL
    ORDER BY qs.last_execution_time DESC;

    DECLARE @shape varchar(40), @est float;

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT @shape = CASE WHEN @plan IS NULL                                   THEN 'NO PLAN FOUND'
                         WHEN @plan.exist('//IndexScan[@Lookup="1"]') = 1      THEN 'seek + lookups'
                         WHEN @plan.exist('//RelOp[@PhysicalOp="Clustered Index Scan"]') = 1 THEN 'clustered scan'
                         WHEN @plan.exist('//RelOp[@PhysicalOp="Index Seek"]') = 1 THEN 'index seek only'
                         ELSE 'other' END,
           @est   = @plan.value('(//RelOp[IndexScan][1]/@EstimateRows)[1]', 'float');

    INSERT Demo.Runs (Scenario, TableName, Mode, TargetRows, PctOfTable, PlanShape, EstimateRows, LogicalReads, CpuMs)
    VALUES (@Scenario, @Table, @Mode, @TargetRows, @TargetRows / 10000.0, @shape, @est, @reads, @cpu);
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the TippingPointDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
