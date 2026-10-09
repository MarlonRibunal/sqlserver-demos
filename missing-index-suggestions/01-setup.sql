/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, MissingIndexDemo, and puts everything
     inside it. Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched

     The missing-index DMVs are instance-wide views, but they are only READ,
     and only for this database.

  Creates, all inside MissingIndexDemo:
     Demo.Orders        - 1,000,000 orders, clustered on OrderID, and NO
                          nonclustered indexes: the workload has to ask
     Demo.usp_Q1..Q6    - the workload, six queries
     Demo.Suggestions   - what the missing-index DMVs suggested
     Demo.Measures      - reads and plan facts per query per index design
     Demo.usp_Measure   - runs one query and records it
     Demo.usp_DropNonclustered - removes every nonclustered index on Orders

  COST: about 1 GB of data plus transaction log at the peak of the demo,
  all inside MissingIndexDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;   -- Demo.usp_Measure uses XML methods
GO

PRINT '=== STEP 1: create MissingIndexDemo ===';
GO

IF DB_ID('MissingIndexDemo') IS NOT NULL
BEGIN
    RAISERROR('MissingIndexDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE MissingIndexDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE MissingIndexDemo;
END
GO

CREATE DATABASE MissingIndexDemo;
GO

ALTER DATABASE MissingIndexDemo SET RECOVERY SIMPLE;
GO

USE MissingIndexDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: Demo.Orders ===';
GO

/*------------------------------------------------------------------------------
  1,000,000 orders: 50,000 customers with 20 orders each, six years of dates
  (about 457 orders a day), and three statuses -- 'Open' on 2% of rows.
  Notes is a 200-byte column nobody should index.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.Orders;
GO

CREATE TABLE Demo.Orders
(
    OrderID    int            NOT NULL,
    CustomerID int            NOT NULL,
    Status     varchar(10)    NOT NULL,
    OrderDate  date           NOT NULL,
    Amount     decimal(10,2)  NOT NULL,
    ShipCity   varchar(30)    NOT NULL,
    Notes      char(200)      NOT NULL,
    CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderID)
);
GO

;WITH n AS
(
    SELECT TOP (1000000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b CROSS JOIN sys.all_columns AS c
)
INSERT Demo.Orders WITH (TABLOCK) (OrderID, CustomerID, Status, OrderDate, Amount, ShipCity, Notes)
SELECT rn,
       rn % 50000 + 1,
       CASE WHEN rn % 50 = 0 THEN 'Open' WHEN rn % 3 = 0 THEN 'Cancelled' ELSE 'Shipped' END,
       DATEADD(day, rn % 2190, CAST('20200101' AS date)),
       (rn % 10000) / 100.0,
       'City' + CAST(rn % 300 AS varchar(10)),
       'n'
FROM   n;
GO


PRINT '=== STEP 3: the workload ===';
GO

/*------------------------------------------------------------------------------
  Six queries, each in its own procedure with typed parameters. Results go
  into variables, so nothing is printed and the queries read exactly the
  columns they name.

     Q1  one customer's orders: dates and amounts
     Q2  one customer's spend since a date
     Q3  one customer's order statuses
     Q4  one customer's spend in one status
     Q5  every column of one day's orders           (a SELECT * in disguise)
     Q6  the 50 most recent Open orders             (TOP ... ORDER BY)
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Q1 @c int AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @d date, @a decimal(10,2);
    SELECT @d = OrderDate, @a = Amount FROM Demo.Orders WHERE CustomerID = @c;
END
GO
CREATE OR ALTER PROCEDURE Demo.usp_Q2 @c int, @f date AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @a decimal(18,2);
    SELECT @a = SUM(Amount) FROM Demo.Orders WHERE CustomerID = @c AND OrderDate >= @f;
END
GO
CREATE OR ALTER PROCEDURE Demo.usp_Q3 @c int AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s varchar(10);
    SELECT @s = Status FROM Demo.Orders WHERE CustomerID = @c;
END
GO
CREATE OR ALTER PROCEDURE Demo.usp_Q4 @c int, @s varchar(10) AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @a decimal(18,2);
    SELECT @a = SUM(Amount) FROM Demo.Orders WHERE CustomerID = @c AND Status = @s;
END
GO
CREATE OR ALTER PROCEDURE Demo.usp_Q5 @d date AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @i int, @c int, @s varchar(10), @a decimal(10,2), @city varchar(30), @n char(200);
    SELECT @i = OrderID, @c = CustomerID, @s = Status, @a = Amount, @city = ShipCity, @n = Notes
    FROM   Demo.Orders WHERE OrderDate = @d;
END
GO
CREATE OR ALTER PROCEDURE Demo.usp_Q6 @s varchar(10) AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @last date, @a decimal(18,2);
    SELECT @last = MIN(OrderDate), @a = SUM(Amount)
    FROM  (SELECT TOP (50) OrderDate, Amount FROM Demo.Orders WHERE Status = @s ORDER BY OrderDate DESC) AS t;
END
GO


PRINT '=== STEP 4: evidence tables and procedures ===';
GO

DROP TABLE IF EXISTS Demo.Suggestions;
CREATE TABLE Demo.Suggestions
(
    SuggestionID   int            IDENTITY(1,1) NOT NULL PRIMARY KEY,
    EqualityCols   nvarchar(400)  NULL,
    InequalityCols nvarchar(400)  NULL,
    IncludedCols   nvarchar(400)  NULL,
    UserSeeks      bigint         NULL,
    AvgUserImpact  decimal(6,2)   NULL,     -- the DMV's own estimate, in percent
    CreateStmt     nvarchar(max)  NULL      -- built exactly as the DMV describes it
);

DROP TABLE IF EXISTS Demo.Measures;
CREATE TABLE Demo.Measures
(
    Design        varchar(20)   NOT NULL,   -- none | dmv | hand
    QueryName     sysname       NOT NULL,
    LogicalReads  bigint        NULL,
    HasSort       bit           NULL,
    HasLookup     bit           NULL,
    AccessIndex   sysname       NULL,
    CapturedAt    datetime2(3)  NOT NULL CONSTRAINT DF_MIMeasures_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  Demo.usp_RunWorkload -- every query once, with fixed arguments.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_RunWorkload
AS
BEGIN
    SET NOCOUNT ON;
    EXEC Demo.usp_Q1 @c = 123;
    EXEC Demo.usp_Q2 @c = 123, @f = '20240101';
    EXEC Demo.usp_Q3 @c = 123;
    EXEC Demo.usp_Q4 @c = 123, @s = 'Open';
    EXEC Demo.usp_Q5 @d = '20230315';
    EXEC Demo.usp_Q6 @s = 'Open';
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_Measure -- recompile one workload query, run it twice, record the
  second run's reads (a delta of sys.dm_exec_requests for this session) and,
  from its cached plan, whether it sorted, whether it looked rows up, and
  which index it read.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Measure
    @Design varchar(20),
    @Query  sysname
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @proc sysname = N'Demo.usp_' + @Query;
    DECLARE @sql nvarchar(400) =
        N'EXEC ' + @proc + CASE @Query
            WHEN 'Q1' THEN N' @c = 123;'
            WHEN 'Q2' THEN N' @c = 123, @f = ''20240101'';'
            WHEN 'Q3' THEN N' @c = 123;'
            WHEN 'Q4' THEN N' @c = 123, @s = ''Open'';'
            WHEN 'Q5' THEN N' @d = ''20230315'';'
            WHEN 'Q6' THEN N' @s = ''Open'';' END;
    DECLARE @r0 bigint, @reads bigint;

    EXEC sys.sp_recompile @proc;
    EXEC sys.sp_executesql @sql;
    SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    EXEC sys.sp_executesql @sql;
    SELECT @reads = logical_reads - @r0 FROM sys.dm_exec_requests WHERE session_id = @@SPID;

    DECLARE @plan xml;
    SELECT TOP (1) @plan = qp.query_plan
    FROM   sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
    WHERE  st.objectid = OBJECT_ID(@proc) AND st.dbid = DB_ID()
    ORDER BY qs.last_execution_time DESC;

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    INSERT Demo.Measures (Design, QueryName, LogicalReads, HasSort, HasLookup, AccessIndex)
    SELECT @Design, @Query, @reads,
           @plan.exist('//RelOp[@PhysicalOp="Sort" or @PhysicalOp="Top N Sort"]'),
           @plan.exist('//IndexScan[@Lookup="1"]'),
           REPLACE(REPLACE(@plan.value('(//RelOp[IndexScan][1]/IndexScan/Object/@Index)[1]', 'sysname'), '[', ''), ']', '');
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_DropNonclustered
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql nvarchar(max) = N'';
    SELECT @sql += N'DROP INDEX ' + QUOTENAME(name) + N' ON Demo.Orders;'
    FROM   sys.indexes
    WHERE  object_id = OBJECT_ID('Demo.Orders') AND index_id > 1;
    EXEC sys.sp_executesql @sql;
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the MissingIndexDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
