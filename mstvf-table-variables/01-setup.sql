/*==============================================================================
  01-setup.sql          RUN ONCE. Takes about 10 seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, TvfDemo, and puts everything inside it.
     Nothing else on the instance is modified. Inside TvfDemo it sets:

        - COMPATIBILITY_LEVEL = 150, so every supported version (2019, 2022,
          2025) compiles the same way: interleaved execution (140+) and
          table variable deferred compilation (150+) are on, and the demo
          turns each off per query with a USE HINT to show the older
          behaviour
        - LAST_QUERY_PLAN_STATS = ON (a database scoped configuration), so
          the demo can read each query's last ACTUAL plan: the rows that
          really came out of each operator, and whether a sort spilled

     No instance setting, no trace flag, no other database.

  Creates, all inside TvfDemo:
     Demo.Orders          - 500,000 orders, 274 a day from 2020 to the end
                            of 2024
     Demo.fn_Orders       - multi-statement TVF: orders since @Since
     Demo.ifn_Orders      - the same as an inline TVF
     Demo.q_*             - one procedure per measured query
     Demo.usp_Run         - run one of them and record what its plan did
     Demo.Runs            - one row per measured run
     Demo.Verdicts        - one row per claim

  REQUIRES SQL Server 2019 or later (compatibility level 150,
  sys.dm_exec_query_plan_stats, the DISABLE_DEFERRED_COMPILATION_TV hint).

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create TvfDemo ===';
GO

IF DB_ID('TvfDemo') IS NOT NULL
BEGIN
    RAISERROR('TvfDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE TvfDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE TvfDemo;
END
GO

CREATE DATABASE TvfDemo;
GO

ALTER DATABASE TvfDemo SET RECOVERY SIMPLE;
ALTER DATABASE TvfDemo SET COMPATIBILITY_LEVEL = 150;
GO

USE TvfDemo;
GO
SET NOCOUNT ON;
GO

ALTER DATABASE SCOPED CONFIGURATION SET LAST_QUERY_PLAN_STATS = ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: Demo.Orders ===';
GO

-- 274 orders a day from 1 Jan 2020 to 29 Dec 2024; 1 in 20 is Closed.
CREATE TABLE Demo.Orders
(
    OrderID    int            NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    CustomerID int            NOT NULL,
    OrderDate  date           NOT NULL,
    Status     varchar(10)    NOT NULL,
    Amount     decimal(12,2)  NOT NULL,
    pad        char(100)      NOT NULL CONSTRAINT DF_Orders_pad DEFAULT ('x')
);
;WITH n AS
(
    SELECT TOP (500000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.Orders WITH (TABLOCK) (OrderID, CustomerID, OrderDate, Status, Amount)
SELECT rn, rn % 20000 + 1, DATEADD(day, rn / 274, '20200101'),
       CASE WHEN rn % 20 = 0 THEN 'Closed' ELSE 'Open' END,
       rn % 1000 + 0.50
FROM   n;

CREATE INDEX IX_Orders_Customer ON Demo.Orders (CustomerID) INCLUDE (OrderDate, Amount);
CREATE INDEX IX_Orders_Date     ON Demo.Orders (OrderDate)  INCLUDE (CustomerID, Amount);
GO


PRINT '=== STEP 3: the functions ===';
GO

-- Multi-statement: fills a table variable, then returns it.
CREATE FUNCTION Demo.fn_Orders (@Since date)
RETURNS @r TABLE
(
    OrderID    int            NOT NULL PRIMARY KEY,
    CustomerID int            NOT NULL,
    OrderDate  date           NOT NULL,
    Amount     decimal(12,2)  NOT NULL
)
AS
BEGIN
    INSERT @r (OrderID, CustomerID, OrderDate, Amount)
    SELECT OrderID, CustomerID, OrderDate, Amount
    FROM   Demo.Orders
    WHERE  OrderDate >= @Since;
    RETURN;
END
GO

-- Inline: one SELECT, expanded into the calling query like a view.
CREATE FUNCTION Demo.ifn_Orders (@Since date)
RETURNS TABLE
AS
RETURN SELECT OrderID, CustomerID, OrderDate, Amount
       FROM   Demo.Orders
       WHERE  OrderDate >= @Since;
GO


PRINT '=== STEP 4: the measured queries ===';
GO

/*------------------------------------------------------------------------------
  Most of the queries share one shape: take a set of orders (from a
  function, a table variable or a temp table), join back to Demo.Orders for
  the wide columns, and keep each customer's top 3. The join and the sort
  are where a wrong row estimate costs: a nested loops join sized for a
  handful of rows, and a sort granted memory for a handful.

  Every query runs at MAXDOP 1, so the numbers don't depend on the number of
  cores. The last statement in each procedure is the one measured.
------------------------------------------------------------------------------*/

-- A. The MSTVF, three ways, and the inline function.
CREATE OR ALTER PROCEDURE Demo.q_A_Legacy AS
    DECLARE @c int, @s decimal(18,2);
    SELECT @c = COUNT(*), @s = SUM(x.Amount)
    FROM  (SELECT o.Amount, rn = ROW_NUMBER() OVER (PARTITION BY f.CustomerID ORDER BY o.pad, f.Amount DESC)
           FROM   Demo.fn_Orders('20230101') AS f JOIN Demo.Orders AS o ON o.OrderID = f.OrderID) AS x
    WHERE  rn <= 3
    OPTION (MAXDOP 1, USE HINT('FORCE_LEGACY_CARDINALITY_ESTIMATION', 'DISABLE_INTERLEAVED_EXECUTION_TVF'));
GO
CREATE OR ALTER PROCEDURE Demo.q_A_Fixed AS
    DECLARE @c int, @s decimal(18,2);
    SELECT @c = COUNT(*), @s = SUM(x.Amount)
    FROM  (SELECT o.Amount, rn = ROW_NUMBER() OVER (PARTITION BY f.CustomerID ORDER BY o.pad, f.Amount DESC)
           FROM   Demo.fn_Orders('20230101') AS f JOIN Demo.Orders AS o ON o.OrderID = f.OrderID) AS x
    WHERE  rn <= 3
    OPTION (MAXDOP 1, USE HINT('DISABLE_INTERLEAVED_EXECUTION_TVF'));
GO
CREATE OR ALTER PROCEDURE Demo.q_A_Interleaved AS
    DECLARE @c int, @s decimal(18,2);
    SELECT @c = COUNT(*), @s = SUM(x.Amount)
    FROM  (SELECT o.Amount, rn = ROW_NUMBER() OVER (PARTITION BY f.CustomerID ORDER BY o.pad, f.Amount DESC)
           FROM   Demo.fn_Orders('20230101') AS f JOIN Demo.Orders AS o ON o.OrderID = f.OrderID) AS x
    WHERE  rn <= 3
    OPTION (MAXDOP 1);
GO
CREATE OR ALTER PROCEDURE Demo.q_A_Inline AS
    DECLARE @c int, @s decimal(18,2);
    SELECT @c = COUNT(*), @s = SUM(x.Amount)
    FROM  (SELECT o.Amount, rn = ROW_NUMBER() OVER (PARTITION BY f.CustomerID ORDER BY o.pad, f.Amount DESC)
           FROM   Demo.ifn_Orders('20230101') AS f JOIN Demo.Orders AS o ON o.OrderID = f.OrderID) AS x
    WHERE  rn <= 3
    OPTION (MAXDOP 1);
GO

-- B. One customer's orders, filtered outside the function.
CREATE OR ALTER PROCEDURE Demo.q_B_Mstvf AS
    DECLARE @c int, @s decimal(18,2);
    SELECT @c = COUNT(*), @s = SUM(Amount) FROM Demo.fn_Orders('20200101') WHERE CustomerID = 42 OPTION (MAXDOP 1);
GO
CREATE OR ALTER PROCEDURE Demo.q_B_Inline AS
    DECLARE @c int, @s decimal(18,2);
    SELECT @c = COUNT(*), @s = SUM(Amount) FROM Demo.ifn_Orders('20200101') WHERE CustomerID = 42 OPTION (MAXDOP 1);
GO

-- C. A's interleaved query, as INSERT ... SELECT.
CREATE OR ALTER PROCEDURE Demo.q_C_InsertMstvf AS
    CREATE TABLE #top3 (Amount decimal(12,2), rn bigint);
    INSERT #top3 (Amount, rn)
    SELECT x.Amount, x.rn
    FROM  (SELECT o.Amount, rn = ROW_NUMBER() OVER (PARTITION BY f.CustomerID ORDER BY o.pad, f.Amount DESC)
           FROM   Demo.fn_Orders('20230101') AS f JOIN Demo.Orders AS o ON o.OrderID = f.OrderID) AS x
    WHERE  rn <= 3
    OPTION (MAXDOP 1);
GO
CREATE OR ALTER PROCEDURE Demo.q_C_InsertInline AS
    CREATE TABLE #top3 (Amount decimal(12,2), rn bigint);
    INSERT #top3 (Amount, rn)
    SELECT x.Amount, x.rn
    FROM  (SELECT o.Amount, rn = ROW_NUMBER() OVER (PARTITION BY f.CustomerID ORDER BY o.pad, f.Amount DESC)
           FROM   Demo.ifn_Orders('20230101') AS f JOIN Demo.Orders AS o ON o.OrderID = f.OrderID) AS x
    WHERE  rn <= 3
    OPTION (MAXDOP 1);
GO

-- D. Table variables: the row count, the distribution, and plan reuse.
CREATE OR ALTER PROCEDURE Demo.q_D_TvLegacy AS
    DECLARE @t TABLE (OrderID int NOT NULL PRIMARY KEY, Status varchar(10) NOT NULL);
    INSERT @t (OrderID, Status) SELECT OrderID, Status FROM Demo.Orders WHERE OrderDate >= '20230101';
    DECLARE @c int, @s decimal(18,2);
    SELECT @c = COUNT(*), @s = SUM(x.Amount)
    FROM  (SELECT o.Amount, rn = ROW_NUMBER() OVER (PARTITION BY o.CustomerID ORDER BY o.pad, o.Amount DESC)
           FROM   @t AS t JOIN Demo.Orders AS o ON o.OrderID = t.OrderID) AS x
    WHERE  rn <= 3
    OPTION (MAXDOP 1, USE HINT('DISABLE_DEFERRED_COMPILATION_TV'));
GO
CREATE OR ALTER PROCEDURE Demo.q_D_TvDeferred AS
    DECLARE @t TABLE (OrderID int NOT NULL PRIMARY KEY, Status varchar(10) NOT NULL);
    INSERT @t (OrderID, Status) SELECT OrderID, Status FROM Demo.Orders WHERE OrderDate >= '20230101';
    DECLARE @c int, @s decimal(18,2);
    SELECT @c = COUNT(*), @s = SUM(x.Amount)
    FROM  (SELECT o.Amount, rn = ROW_NUMBER() OVER (PARTITION BY o.CustomerID ORDER BY o.pad, o.Amount DESC)
           FROM   @t AS t JOIN Demo.Orders AS o ON o.OrderID = t.OrderID) AS x
    WHERE  rn <= 3
    OPTION (MAXDOP 1);
GO
CREATE OR ALTER PROCEDURE Demo.q_D_TvOpen AS
    DECLARE @t TABLE (OrderID int NOT NULL PRIMARY KEY, Status varchar(10) NOT NULL);
    INSERT @t (OrderID, Status) SELECT OrderID, Status FROM Demo.Orders WHERE OrderDate >= '20230101';
    DECLARE @c int, @s decimal(18,2);
    SELECT @c = COUNT(*), @s = SUM(x.Amount)
    FROM  (SELECT o.Amount, rn = ROW_NUMBER() OVER (PARTITION BY o.CustomerID ORDER BY o.pad, o.Amount DESC)
           FROM   @t AS t JOIN Demo.Orders AS o ON o.OrderID = t.OrderID
           WHERE  t.Status = 'Open') AS x
    WHERE  rn <= 3
    OPTION (MAXDOP 1);
GO
CREATE OR ALTER PROCEDURE Demo.q_D_TempOpen AS
    CREATE TABLE #t (OrderID int NOT NULL PRIMARY KEY, Status varchar(10) NOT NULL);
    INSERT #t (OrderID, Status) SELECT OrderID, Status FROM Demo.Orders WHERE OrderDate >= '20230101';
    DECLARE @c int, @s decimal(18,2);
    SELECT @c = COUNT(*), @s = SUM(x.Amount)
    FROM  (SELECT o.Amount, rn = ROW_NUMBER() OVER (PARTITION BY o.CustomerID ORDER BY o.pad, o.Amount DESC)
           FROM   #t AS t JOIN Demo.Orders AS o ON o.OrderID = t.OrderID
           WHERE  t.Status = 'Open') AS x
    WHERE  rn <= 3
    OPTION (MAXDOP 1);
GO
CREATE OR ALTER PROCEDURE Demo.q_D_TvReuse @Since date AS
    DECLARE @t TABLE (OrderID int NOT NULL PRIMARY KEY, Status varchar(10) NOT NULL);
    INSERT @t (OrderID, Status) SELECT OrderID, Status FROM Demo.Orders WHERE OrderDate >= @Since;
    DECLARE @c int, @s decimal(18,2);
    SELECT @c = COUNT(*), @s = SUM(x.Amount)
    FROM  (SELECT o.Amount, rn = ROW_NUMBER() OVER (PARTITION BY o.CustomerID ORDER BY o.pad, o.Amount DESC)
           FROM   @t AS t JOIN Demo.Orders AS o ON o.OrderID = t.OrderID) AS x
    WHERE  rn <= 3
    OPTION (MAXDOP 1);
GO


PRINT '=== STEP 5: the harness ===';
GO

CREATE TABLE Demo.Runs
(
    Scenario    char(1)        NOT NULL,
    Label       varchar(80)    NOT NULL,
    Proc_       sysname        NOT NULL,
    EstRows     float          NULL,     -- the optimizer's estimate at the operator
    ActualRows  bigint         NULL,     -- what came out of it
    JoinType    varchar(40)    NULL,     -- the first inner join's physical operator
    Spilled     bit            NULL,     -- a sort or hash spilled to tempdb
    Reads       bigint         NULL,     -- the whole procedure
    CpuMs       int            NULL,
    FnRows      bigint         NULL,     -- rows the MSTVF's own INSERT wrote
    Seq         int            IDENTITY(1,1) NOT NULL
);
GO

CREATE TABLE Demo.Verdicts
(
    Scenario  char(1)        NOT NULL,
    Claim     varchar(200)   NOT NULL,
    Evidence  varchar(300)   NULL,
    Verdict   varchar(30)    NOT NULL,
    Seq       int            IDENTITY(1,1) NOT NULL
);
GO

/*------------------------------------------------------------------------------
  Demo.usp_Run -- run Demo.@Proc once (after sp_recompile, unless
  @Recompile = 0) and record, from its last ACTUAL plan's final statement:
  the estimated and actual rows at the operator reading @Source (a table
  name as the plan writes it: '[@t]', '[#t]', or '[fn_Orders]' for the
  multi-statement function's result), the join type, and whether anything
  spilled.
  Logical reads and CPU are the whole procedure's, from
  sys.dm_exec_requests.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Run
    @Scenario  char(1),
    @Label     varchar(80),
    @Proc      sysname,
    @Source    nvarchar(100),
    @Since     date = NULL,
    @Recompile bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @full nvarchar(300) = N'Demo.' + @Proc;
    IF @Recompile = 1 EXEC sys.sp_recompile @full;

    DECLARE @r0 bigint, @c0 int, @r1 bigint, @c1 int;
    SELECT @r0 = logical_reads, @c0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    IF @Since IS NULL EXEC @full; ELSE EXEC @full @Since = @Since;
    SELECT @r1 = logical_reads, @c1 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;

    DECLARE @plan xml, @st xml;
    SELECT TOP (1) @plan = qp.query_plan
    FROM   sys.dm_exec_procedure_stats AS ps
    CROSS APPLY sys.dm_exec_query_plan_stats(ps.plan_handle) AS qp
    WHERE  ps.database_id = DB_ID() AND ps.object_id = OBJECT_ID(@full);

    WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT @st = @plan.query('(//StmtSimple)[last()]');

    -- The operator that reads the rows. For an MSTVF that's the scan of its
    -- result table; the "Table-valued function" operator above it fills the
    -- table and reports 0 rows.
    DECLARE @op xml;
    WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT @op = @st.query('(//RelOp[@PhysicalOp != "Table-valued function"][*/Object/@Table = sql:variable("@Source")])[1]');

    -- For an MSTVF: how many rows the function itself built, from its own
    -- INSERT's last execution.
    DECLARE @fnRows bigint = NULL;
    IF @Source = N'[fn_Orders]'
        SELECT TOP (1) @fnRows = qs.last_rows
        FROM   sys.dm_exec_query_stats AS qs
        CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
        WHERE  t.dbid = DB_ID() AND t.objectid = OBJECT_ID(N'Demo.fn_Orders')
        ORDER BY qs.last_execution_time DESC;

    WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    INSERT Demo.Runs (Scenario, Label, Proc_, EstRows, ActualRows, JoinType, Spilled, Reads, CpuMs, FnRows)
    SELECT @Scenario, @Label, @Proc,
           @op.value('(RelOp/@EstimateRows)[1]', 'float'),
           CASE WHEN @op.exist('RelOp') = 1
                THEN CAST(@op.value('sum(RelOp/RunTimeInformation/RunTimeCountersPerThread/@ActualRows)', 'float') AS bigint) END,
           @st.value('(//RelOp[@LogicalOp = "Inner Join"]/@PhysicalOp)[1]', 'varchar(40)'),
           CASE WHEN @st.exist('//Warnings/SpillOccurred') = 1 OR @st.exist('//Warnings/SpillToTempDb') = 1 THEN 1 ELSE 0 END,
           @r1 - @r0, @c1 - @c0, @fnRows;
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the TvfDemo database.';
PRINT ' No instance setting was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
