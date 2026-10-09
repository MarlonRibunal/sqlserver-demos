/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  REQUIRES SQL Server 2019 or later. Scalar UDF inlining arrived in 2019 and
  needs database compatibility level 150 or higher. On an older instance this
  script stops at STEP 0 and says so.

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, UdfInliningDemo, and puts everything inside
     it. Nothing else on the instance is modified:

        - no compatibility level is changed (the new database takes the
          instance default, which is 150+ on 2019 and later)
        - no database scoped configuration is changed -- TSQL_SCALAR_UDF_INLINING
          stays at its default, ON. The comparison is made per FUNCTION, with
          WITH INLINE = ON and WITH INLINE = OFF on otherwise identical bodies.
        - no trace flag is set
        - no existing database is touched

  Creates, all inside UdfInliningDemo:
     Demo.Orders, Demo.Customers   - 500,000 orders, 10,000 customers
     Demo.fn_*                     - scalar functions, in ON / OFF pairs
     Demo.usp_*                    - one procedure per query being compared
     Demo.Runs                     - where 02-demo.sql records each execution
     Demo.usp_Run                  - runs one procedure and records the cost

  COST: about 150 MB of data plus transaction log, all inside UdfInliningDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers,
  MAXDOP 0, cost threshold for parallelism 5, compatibility level 160.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;   -- Demo.usp_Run uses XML methods
GO

PRINT '=== STEP 0: environment ===';
GO

SELECT  ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS sysname),
        EngineMajor    = CAST(SERVERPROPERTY('ProductMajorVersion') AS int);

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) < 15
BEGIN
    RAISERROR('Scalar UDF inlining needs SQL Server 2019 or later. This instance is older; stopping.', 16, 1);
    SET NOEXEC ON;
END
GO


PRINT '=== STEP 1: create UdfInliningDemo ===';
GO

IF DB_ID('UdfInliningDemo') IS NOT NULL
BEGIN
    RAISERROR('UdfInliningDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE UdfInliningDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE UdfInliningDemo;
END
GO

CREATE DATABASE UdfInliningDemo;
GO

ALTER DATABASE UdfInliningDemo SET RECOVERY SIMPLE;
GO

USE UdfInliningDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO

SELECT  CompatibilityLevel = compatibility_level,
        InliningConfig     = (SELECT CAST(value AS int) FROM sys.database_scoped_configurations
                              WHERE name = 'TSQL_SCALAR_UDF_INLINING')
FROM    sys.databases WHERE name = DB_NAME();
GO


PRINT '=== STEP 2: data ===';
GO

DROP TABLE IF EXISTS Demo.Orders, Demo.Customers;
GO

CREATE TABLE Demo.Customers
(
    CustomerID int         NOT NULL,
    Region     char(2)     NOT NULL,
    CONSTRAINT PK_Customers PRIMARY KEY CLUSTERED (CustomerID)
);

CREATE TABLE Demo.Orders
(
    OrderID    int            NOT NULL,
    CustomerID int            NOT NULL,
    Amount     decimal(10,2)  NOT NULL,
    pad        char(100)      NOT NULL CONSTRAINT DF_Orders_pad DEFAULT ('x'),
    CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderID)
);
GO

;WITH n AS
(
    SELECT TOP (500000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.Orders WITH (TABLOCK) (OrderID, CustomerID, Amount)
SELECT rn, rn % 10000 + 1, (rn % 50000) / 100.0 FROM n;

INSERT Demo.Customers (CustomerID, Region)
SELECT TOP (10000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)),
       CASE ABS(CHECKSUM(NEWID())) % 3 WHEN 0 THEN 'EU' WHEN 1 THEN 'US' ELSE 'AP' END
FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b;
GO


PRINT '=== STEP 3: the functions, in pairs ===';
GO

/*------------------------------------------------------------------------------
  Each pair is the same body twice. The only difference is WITH INLINE:

     ON   the optimizer may rewrite the function into the calling query, as
          if its body had been typed there -- one plan, set-based.
     OFF  the function stays a black box called once per row, as it always
          was before 2019.

  fn_Tax*      pure arithmetic, no data access
  fn_Region*   reads Demo.Customers -- one lookup per call

  fn_TaxNow is a third case: it calls GETDATE(), one of the constructs that
  makes a function NOT inlineable at all, whatever WITH INLINE says.
  sys.sql_modules.is_inlineable reports which is which.
------------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION Demo.fn_TaxInline (@amount decimal(10,2))
RETURNS decimal(12,2)
WITH INLINE = ON
AS
BEGIN
    RETURN CASE WHEN @amount >= 100 THEN @amount * 0.2 ELSE @amount * 0.1 END;
END
GO

CREATE OR ALTER FUNCTION Demo.fn_TaxNoInline (@amount decimal(10,2))
RETURNS decimal(12,2)
WITH INLINE = OFF
AS
BEGIN
    RETURN CASE WHEN @amount >= 100 THEN @amount * 0.2 ELSE @amount * 0.1 END;
END
GO

CREATE OR ALTER FUNCTION Demo.fn_RegionInline (@customerId int)
RETURNS char(2)
WITH INLINE = ON
AS
BEGIN
    RETURN (SELECT Region FROM Demo.Customers WHERE CustomerID = @customerId);
END
GO

CREATE OR ALTER FUNCTION Demo.fn_RegionNoInline (@customerId int)
RETURNS char(2)
WITH INLINE = OFF
AS
BEGIN
    RETURN (SELECT Region FROM Demo.Customers WHERE CustomerID = @customerId);
END
GO

CREATE OR ALTER FUNCTION Demo.fn_TaxNow (@amount decimal(10,2))
RETURNS decimal(12,2)
AS
BEGIN
    -- GETDATE() is time-dependent; a function that calls it cannot be inlined.
    RETURN CASE WHEN YEAR(GETDATE()) >= 2000 AND @amount >= 100 THEN @amount * 0.2
                ELSE @amount * 0.1 END;
END
GO

SELECT  FunctionName  = OBJECT_NAME(object_id),
        is_inlineable,
        inline_type   -- 1 = WITH INLINE = ON (or default), 0 = OFF
FROM    sys.sql_modules
WHERE   OBJECT_NAME(object_id) LIKE 'fn[_]%'
ORDER BY FunctionName;
GO


PRINT '=== STEP 4: the queries ===';
GO

/*------------------------------------------------------------------------------
  One procedure per query, so each has its own entry in
  sys.dm_exec_query_stats and its own plan to read. Each returns one row.

  The ExplicitSql pair writes the function's logic out by hand -- the
  baseline inlining is trying to reach.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Tax_Inline AS
    SELECT Total = SUM(Demo.fn_TaxInline(Amount)) FROM Demo.Orders;
GO
CREATE OR ALTER PROCEDURE Demo.usp_Tax_NoInline AS
    SELECT Total = SUM(Demo.fn_TaxNoInline(Amount)) FROM Demo.Orders;
GO
CREATE OR ALTER PROCEDURE Demo.usp_Tax_NotInlineable AS
    SELECT Total = SUM(Demo.fn_TaxNow(Amount)) FROM Demo.Orders;
GO
CREATE OR ALTER PROCEDURE Demo.usp_Tax_ExplicitSql AS
    SELECT Total = SUM(CASE WHEN Amount >= 100 THEN Amount * 0.2 ELSE Amount * 0.1 END) FROM Demo.Orders;
GO
CREATE OR ALTER PROCEDURE Demo.usp_Region_Inline AS
    SELECT EuOrders = COUNT_BIG(*) FROM Demo.Orders WHERE Demo.fn_RegionInline(CustomerID) = 'EU';
GO
CREATE OR ALTER PROCEDURE Demo.usp_Region_NoInline AS
    SELECT EuOrders = COUNT_BIG(*) FROM Demo.Orders WHERE Demo.fn_RegionNoInline(CustomerID) = 'EU';
GO
CREATE OR ALTER PROCEDURE Demo.usp_Region_ExplicitSql AS
    SELECT EuOrders = COUNT_BIG(*)
    FROM   Demo.Orders AS o
    JOIN   Demo.Customers AS c ON c.CustomerID = o.CustomerID
    WHERE  c.Region = 'EU';
GO


PRINT '=== STEP 5: the evidence table and the harness ===';
GO

DROP TABLE IF EXISTS Demo.Runs;
CREATE TABLE Demo.Runs
(
    RunID          int            IDENTITY(1,1) NOT NULL PRIMARY KEY,
    ProcName       sysname        NOT NULL,
    Answer         decimal(18,2)  NULL,     -- what the query returned
    ElapsedMs      int            NULL,
    CpuMs          int            NULL,
    Dop            int            NULL,
    QueryReads     bigint         NULL,     -- reads charged to the QUERY
    FnCalls        bigint         NULL,     -- executions of the function, from sys.dm_exec_function_stats
    FnReads        bigint         NULL,     -- reads charged to the FUNCTION
    UdfInPlan      bit            NULL,     -- the plan still calls a UDF
    SerialReason   nvarchar(100)  NULL,     -- NonParallelPlanReason, if any
    CapturedAt     datetime2(3)   NOT NULL CONSTRAINT DF_UIRuns_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  Demo.usp_Run -- recompile one query procedure (object scoped), run it twice,
  and record the second, warm execution.

  The query's own numbers come from sys.dm_exec_query_stats. The FUNCTION's
  come from sys.dm_exec_function_stats (2016+), as a delta around the
  measured execution -- because a scalar function that is not inlined does
  its reads in its own execution context, and they are NOT charged to the
  query that called it. That is the "hidden cost" this topic measures.

  From the plan: whether it still contains a UserDefinedFunction call, and
  the NonParallelPlanReason attribute, if the plan was forced serial.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Run
    @Proc sysname,
    @Fn   sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    EXEC sys.sp_recompile @Proc;

    DECLARE @sink TABLE (v decimal(18,2));
    DECLARE @sql nvarchar(300) = N'EXEC ' + @Proc + N';';
    INSERT @sink EXEC sys.sp_executesql @sql;          -- warm-up and compile
    DELETE @sink;

    DECLARE @calls0 bigint = 0, @reads0 bigint = 0;
    SELECT @calls0 = ISNULL(SUM(execution_count), 0), @reads0 = ISNULL(SUM(total_logical_reads), 0)
    FROM   sys.dm_exec_function_stats
    WHERE  database_id = DB_ID() AND object_id = OBJECT_ID(@Fn);

    INSERT @sink EXEC sys.sp_executesql @sql;          -- measured

    DECLARE @calls1 bigint = 0, @reads1 bigint = 0;
    SELECT @calls1 = ISNULL(SUM(execution_count), 0), @reads1 = ISNULL(SUM(total_logical_reads), 0)
    FROM   sys.dm_exec_function_stats
    WHERE  database_id = DB_ID() AND object_id = OBJECT_ID(@Fn);

    DECLARE @plan xml, @ms int, @cpu int, @dop int, @reads bigint;
    SELECT TOP (1)
           @plan  = qp.query_plan,
           @ms    = qs.last_elapsed_time / 1000,
           @cpu   = qs.last_worker_time / 1000,
           @dop   = qs.last_dop,
           @reads = qs.last_logical_reads
    FROM   sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
    WHERE  st.objectid = OBJECT_ID(@Proc) AND st.dbid = DB_ID()
    ORDER BY qs.last_execution_time DESC;

    DECLARE @udf bit, @reason nvarchar(100);
    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT @udf    = @plan.exist('//UserDefinedFunction'),
           @reason = @plan.value('(//QueryPlan/@NonParallelPlanReason)[1]', 'nvarchar(100)');

    INSERT Demo.Runs (ProcName, Answer, ElapsedMs, CpuMs, Dop, QueryReads, FnCalls, FnReads, UdfInPlan, SerialReason)
    VALUES (@Proc, (SELECT TOP (1) v FROM @sink), @ms, @cpu, @dop, @reads,
            @calls1 - @calls0, @reads1 - @reads0, @udf, @reason);
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the UdfInliningDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
