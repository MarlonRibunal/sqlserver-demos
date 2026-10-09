/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, CatchAllDemo, and puts everything inside it.
     Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched
        - no instance-wide plan cache flush (sp_recompile only, object scoped)

  Creates, all inside CatchAllDemo:
     Demo.Orders              - 1,000,000 orders, three searchable columns
     Demo.usp_Search_*        - the same search, written five ways
     Demo.Calls               - one row per measured call
     Demo.usp_Call            - calls one variant with one set of arguments

  COST: about 300 MB of data plus transaction log, all inside CatchAllDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create CatchAllDemo ===';
GO

IF DB_ID('CatchAllDemo') IS NOT NULL
BEGIN
    RAISERROR('CatchAllDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE CatchAllDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE CatchAllDemo;
END
GO

CREATE DATABASE CatchAllDemo;
GO

ALTER DATABASE CatchAllDemo SET RECOVERY SIMPLE;
GO

USE CatchAllDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: Demo.Orders ===';
GO

/*------------------------------------------------------------------------------
  1,000,000 orders, each searchable column with its own index:

     CustomerID  50,000 customers, 20 orders each
     OrderDate   2020-01-01 to 2025-12-29, about 457 a day
     SalesRepID  500 reps -- and NULL on 10% of orders (no rep assigned).
                 That NULL is what scenario D needs.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.Orders;
GO

CREATE TABLE Demo.Orders
(
    OrderID    int            NOT NULL,
    CustomerID int            NOT NULL,
    OrderDate  date           NOT NULL,
    SalesRepID int            NULL,
    Amount     decimal(10,2)  NOT NULL,
    pad        char(150)      NOT NULL CONSTRAINT DF_Orders_pad DEFAULT ('x'),
    CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderID)
);
GO

;WITH n AS
(
    SELECT TOP (1000000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b CROSS JOIN sys.all_columns AS c
)
INSERT Demo.Orders WITH (TABLOCK) (OrderID, CustomerID, OrderDate, SalesRepID, Amount)
SELECT rn,
       rn % 50000 + 1,
       DATEADD(day, rn % 2190, CAST('20200101' AS date)),
       CASE WHEN rn % 10 = 0 THEN NULL ELSE rn % 500 + 1 END,
       (rn % 10000) / 100.0
FROM   n;
GO

CREATE INDEX IX_Orders_CustomerID ON Demo.Orders (CustomerID);
CREATE INDEX IX_Orders_OrderDate  ON Demo.Orders (OrderDate);
CREATE INDEX IX_Orders_SalesRepID ON Demo.Orders (SalesRepID);
GO


PRINT '=== STEP 3: one search, five ways ===';
GO

/*------------------------------------------------------------------------------
  "Find orders, optionally by customer, optionally since a date, optionally
  by sales rep." A NULL argument means "any". Each variant returns one row:
  the count and the total.

     usp_Search_CatchAll         WHERE (@p IS NULL OR col = @p) ...
     usp_Search_Recompile        the same, with OPTION (RECOMPILE)
     usp_Search_RecompileAssign  the same again, but assigning the result to
                                 variables (SELECT @n = COUNT_BIG(*) ...)
                                 instead of returning it -- scenario C
     usp_Search_Dynamic          builds only the predicates that were
                                 supplied, then sp_executesql with
                                 parameters -- never by concatenating the
                                 values into the string
     usp_Search_Coalesce         WHERE col = COALESCE(@p, col) -- shorter,
                                 and subtly wrong (scenario E)
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Search_CatchAll
    @CustomerID int = NULL, @FromDate date = NULL, @SalesRepID int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Rows = COUNT_BIG(*), Total = SUM(Amount)
    FROM   Demo.Orders
    WHERE  (@CustomerID IS NULL OR CustomerID = @CustomerID)
      AND  (@FromDate   IS NULL OR OrderDate >= @FromDate)
      AND  (@SalesRepID IS NULL OR SalesRepID = @SalesRepID);
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_Search_Recompile
    @CustomerID int = NULL, @FromDate date = NULL, @SalesRepID int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Rows = COUNT_BIG(*), Total = SUM(Amount)
    FROM   Demo.Orders
    WHERE  (@CustomerID IS NULL OR CustomerID = @CustomerID)
      AND  (@FromDate   IS NULL OR OrderDate >= @FromDate)
      AND  (@SalesRepID IS NULL OR SalesRepID = @SalesRepID)
    OPTION (RECOMPILE);
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_Search_RecompileAssign
    @CustomerID int = NULL, @FromDate date = NULL, @SalesRepID int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @n bigint, @total decimal(18,2);
    SELECT @n = COUNT_BIG(*), @total = SUM(Amount)
    FROM   Demo.Orders
    WHERE  (@CustomerID IS NULL OR CustomerID = @CustomerID)
      AND  (@FromDate   IS NULL OR OrderDate >= @FromDate)
      AND  (@SalesRepID IS NULL OR SalesRepID = @SalesRepID)
    OPTION (RECOMPILE);
    SELECT Rows = @n, Total = @total;
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_Search_Dynamic
    @CustomerID int = NULL, @FromDate date = NULL, @SalesRepID int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql nvarchar(max) =
        N'SELECT Rows = COUNT_BIG(*), Total = SUM(Amount) FROM Demo.Orders WHERE 1 = 1';
    IF @CustomerID IS NOT NULL SET @sql += N' AND CustomerID = @CustomerID';
    IF @FromDate   IS NOT NULL SET @sql += N' AND OrderDate >= @FromDate';
    IF @SalesRepID IS NOT NULL SET @sql += N' AND SalesRepID = @SalesRepID';
    SET @sql += N';';

    EXEC sys.sp_executesql @sql, N'@CustomerID int, @FromDate date, @SalesRepID int',
         @CustomerID = @CustomerID, @FromDate = @FromDate, @SalesRepID = @SalesRepID;
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_Search_Coalesce
    @CustomerID int = NULL, @FromDate date = NULL, @SalesRepID int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Rows = COUNT_BIG(*), Total = SUM(Amount)
    FROM   Demo.Orders
    WHERE  CustomerID = COALESCE(@CustomerID, CustomerID)
      AND  OrderDate >= COALESCE(@FromDate, OrderDate)
      AND  SalesRepID = COALESCE(@SalesRepID, SalesRepID);
END
GO


PRINT '=== STEP 4: the evidence table and the harness ===';
GO

DROP TABLE IF EXISTS Demo.Calls;
CREATE TABLE Demo.Calls
(
    CallID       int           IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Variant      varchar(20)   NOT NULL,
    Search       varchar(40)   NOT NULL,
    RowsFound    bigint        NULL,
    LogicalReads bigint        NULL,
    CpuMs        int           NULL,
    CapturedAt   datetime2(3)  NOT NULL CONSTRAINT DF_CACalls_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  Demo.usp_Call -- call one variant with one search's arguments, record the
  rows it found and the reads and CPU of the second of two calls (deltas of
  sys.dm_exec_requests for this session).

  The four searches:
     customer   @CustomerID = 123                      20 rows
     date       @FromDate = 2025-12-23                 last week, ~3,200 rows
     both       @CustomerID = 123, @FromDate = 2024-01-01
     none       everything NULL                        the whole table
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Call
    @Variant varchar(20),
    @Search  varchar(40)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @c int, @d date, @s int, @rows bigint, @r0 bigint, @c0 int;

    IF @Search IN ('customer', 'both') SET @c = 123;
    IF @Search = 'date'                SET @d = '20251223';
    IF @Search = 'both'                SET @d = '20240101';

    DECLARE @sql nvarchar(200) = N'EXEC Demo.usp_Search_' + @Variant
        + N' @CustomerID = @c, @FromDate = @d, @SalesRepID = @s;';
    DECLARE @sink TABLE (Rows bigint, Total decimal(18,2));

    -- Twice; the second call is measured. A plan that is cached is then
    -- measured without its compile, so the only variant still paying a
    -- compile in the numbers is the one that compiles on EVERY call.
    INSERT @sink EXEC sys.sp_executesql @sql, N'@c int, @d date, @s int', @c = @c, @d = @d, @s = @s;
    DELETE @sink;
    SELECT @r0 = logical_reads, @c0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    INSERT @sink EXEC sys.sp_executesql @sql, N'@c int, @d date, @s int', @c = @c, @d = @d, @s = @s;
    SELECT @rows = Rows FROM @sink;

    INSERT Demo.Calls (Variant, Search, RowsFound, LogicalReads, CpuMs)
    SELECT @Variant, @Search, @rows, logical_reads - @r0, cpu_time - @c0
    FROM   sys.dm_exec_requests WHERE session_id = @@SPID;
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the CatchAllDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
