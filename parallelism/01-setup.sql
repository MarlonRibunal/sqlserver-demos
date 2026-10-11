/*==============================================================================
  01-setup.sql          RUN ONCE. Takes under a minute.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, ParallelDemo, and puts everything inside
     it. Nothing else on the instance is modified:

        - no instance setting is changed: not 'max degree of parallelism',
          not 'cost threshold for parallelism' (the demo only reads them,
          and sets DOP per query with OPTION (MAXDOP n))
        - no compatibility level is changed
        - no trace flag is set
        - no existing database is touched
        - no instance-wide plan cache flush (sp_recompile only, object scoped)

     ONE database scoped configuration is set, on ParallelDemo itself:
     LAST_QUERY_PLAN_STATS = ON. It keeps the last actual plan of each
     cached query, with rows per thread, which is how the demo sees inside a
     parallel plan without SSMS. It goes when the database is dropped.

  Creates, all inside ParallelDemo:
     Demo.Sales               - 2,000,000 rows; SkewKey is 1 for 90% of them,
                                EvenKey is spread evenly
     Demo.usp_*               - one procedure per measured query (below)
     Demo.Runs                - CPU, elapsed and DOP of each measured run
     Demo.usp_Measure         - run a procedure N times and record it
     Demo.usp_ThreadRows      - rows per thread at one operator, from the
                                last actual plan
     Demo.usp_PlanFacts       - DOP, cost and NonParallelPlanReason from a
                                cached plan

  COST: about 400 MB of data plus transaction log, all inside ParallelDemo.

  REQUIRES SQL Server 2019 or later (LAST_QUERY_PLAN_STATS,
  sys.dm_exec_query_plan_stats, the DISALLOW_BATCH_MODE hint).

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers,
  Linux container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;   -- the plan readers use XML methods
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) < 15
BEGIN
    RAISERROR('This topic needs SQL Server 2019 or later.', 16, 1);
    SET NOEXEC ON;
END
GO

PRINT '=== STEP 1: create ParallelDemo ===';
GO

IF DB_ID('ParallelDemo') IS NOT NULL
BEGIN
    RAISERROR('ParallelDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE ParallelDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE ParallelDemo;
END
GO

CREATE DATABASE ParallelDemo;
GO

ALTER DATABASE ParallelDemo SET RECOVERY SIMPLE;
GO

USE ParallelDemo;
GO
SET NOCOUNT ON;
GO

ALTER DATABASE SCOPED CONFIGURATION SET LAST_QUERY_PLAN_STATS = ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: Demo.Sales ===';
GO

CREATE TABLE Demo.Sales
(
    SaleID   int            NOT NULL CONSTRAINT PK_Sales PRIMARY KEY CLUSTERED,
    SkewKey  int            NOT NULL,     -- 1 for 90% of rows
    EvenKey  int            NOT NULL,     -- 5,000 values, 400 rows each
    Amount   decimal(12,2)  NOT NULL,
    pad      char(100)      NOT NULL CONSTRAINT DF_Sales_pad DEFAULT ('x')
);
GO

;WITH n AS
(
    SELECT TOP (2000000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b CROSS JOIN sys.all_columns AS c
)
INSERT Demo.Sales WITH (TABLOCK) (SaleID, SkewKey, EvenKey, Amount)
SELECT rn,
       CASE WHEN rn % 10 = 0 THEN rn % 5000 + 2 ELSE 1 END,
       rn % 5000 + 1,
       (rn % 1000) / 10.0
FROM   n;
GO


PRINT '=== STEP 3: the measured queries ===';
GO

/*------------------------------------------------------------------------------
  One procedure per query, so that each has its own cached plan and its own
  row in sys.dm_exec_query_stats. Every DOP is set by hint, never inherited
  from the instance: MAXDOP 4 is "parallel", MAXDOP 1 is "serial".
------------------------------------------------------------------------------*/

-- A: a big scan and aggregate.
CREATE OR ALTER PROCEDURE Demo.usp_Big_Serial AS
    DECLARE @n bigint, @s decimal(18,2), @c int;
    SELECT @n = COUNT_BIG(*), @s = SUM(Amount * 1.1), @c = MAX(CHECKSUM(pad)) FROM Demo.Sales OPTION (MAXDOP 1);
GO
CREATE OR ALTER PROCEDURE Demo.usp_Big_Parallel AS
    DECLARE @n bigint, @s decimal(18,2), @c int;
    SELECT @n = COUNT_BIG(*), @s = SUM(Amount * 1.1), @c = MAX(CHECKSUM(pad)) FROM Demo.Sales OPTION (MAXDOP 4);
GO

-- B: a window function partitioned by a skewed key, then by an even one.
-- Row mode, so the plan repartitions rows across threads by the key.
CREATE OR ALTER PROCEDURE Demo.usp_Window_Skewed AS
    DECLARE @m bigint;
    SELECT @m = MAX(rn) FROM (SELECT rn = ROW_NUMBER() OVER (PARTITION BY SkewKey ORDER BY Amount) FROM Demo.Sales) AS x
    OPTION (MAXDOP 4, USE HINT ('DISALLOW_BATCH_MODE'));
GO
CREATE OR ALTER PROCEDURE Demo.usp_Window_Even AS
    DECLARE @m bigint;
    SELECT @m = MAX(rn) FROM (SELECT rn = ROW_NUMBER() OVER (PARTITION BY EvenKey ORDER BY Amount) FROM Demo.Sales) AS x
    OPTION (MAXDOP 4, USE HINT ('DISALLOW_BATCH_MODE'));
GO
CREATE OR ALTER PROCEDURE Demo.usp_Window_Skewed_Serial AS
    DECLARE @m bigint;
    SELECT @m = MAX(rn) FROM (SELECT rn = ROW_NUMBER() OVER (PARTITION BY SkewKey ORDER BY Amount) FROM Demo.Sales) AS x
    OPTION (MAXDOP 1, USE HINT ('DISALLOW_BATCH_MODE'));
GO
-- C: the skewed query again, batch mode allowed.
CREATE OR ALTER PROCEDURE Demo.usp_Window_Skewed_Batch AS
    DECLARE @m bigint;
    SELECT @m = MAX(rn) FROM (SELECT rn = ROW_NUMBER() OVER (PARTITION BY SkewKey ORDER BY Amount) FROM Demo.Sales) AS x
    OPTION (MAXDOP 4);
GO

-- D: a query just over the default cost threshold (5): 400,000 rows, serial cost about 6.5.
CREATE OR ALTER PROCEDURE Demo.usp_Small_Serial AS
    DECLARE @s decimal(18,2);
    SELECT @s = SUM(Amount) FROM Demo.Sales WHERE SaleID <= 400000 GROUP BY EvenKey % 7 OPTION (MAXDOP 1);
GO
CREATE OR ALTER PROCEDURE Demo.usp_Small_Parallel AS
    DECLARE @s decimal(18,2);
    SELECT @s = SUM(Amount) FROM Demo.Sales WHERE SaleID <= 400000 GROUP BY EvenKey % 7 OPTION (MAXDOP 4);
GO
-- ... and with no hint at all: what the instance's own settings decide.
CREATE OR ALTER PROCEDURE Demo.usp_Small_Default AS
    DECLARE @s decimal(18,2);
    SELECT @s = SUM(Amount) FROM Demo.Sales WHERE SaleID <= 400000 GROUP BY EvenKey % 7;
GO

-- E: things that keep a plan serial, each asking for DOP 4.
-- A scalar function that reads GETDATE() can't be inlined (2019+), so it
-- stays a function call per row.
CREATE OR ALTER FUNCTION Demo.fn_Tax (@Amount decimal(12,2))
RETURNS decimal(12,2)
AS
BEGIN
    RETURN @Amount * CASE WHEN DATEPART(month, GETDATE()) > 0 THEN 0.1 ELSE 0 END;
END
GO
CREATE OR ALTER PROCEDURE Demo.usp_Blocker_ScalarUdf AS
    DECLARE @s decimal(18,2);
    SELECT @s = SUM(Demo.fn_Tax(Amount)) FROM Demo.Sales WHERE SaleID <= 200000 OPTION (MAXDOP 4);
GO
CREATE OR ALTER PROCEDURE Demo.usp_Blocker_TableVariable AS
    DECLARE @t TABLE (EvenKey int, Total decimal(18,2));
    INSERT @t (EvenKey, Total) SELECT EvenKey, SUM(Amount) FROM Demo.Sales GROUP BY EvenKey OPTION (MAXDOP 4);
GO
CREATE OR ALTER PROCEDURE Demo.usp_Blocker_Maxdop1 AS
    DECLARE @s decimal(18,2);
    SELECT @s = SUM(Amount) FROM Demo.Sales OPTION (MAXDOP 1);
GO
CREATE OR ALTER PROCEDURE Demo.usp_Blocker_Cheap AS
    DECLARE @s decimal(18,2);
    SELECT @s = SUM(Amount) FROM Demo.Sales WHERE SaleID <= 1000 OPTION (MAXDOP 4);
GO


PRINT '=== STEP 4: the harness ===';
GO

CREATE TABLE Demo.Runs
(
    Label        varchar(40)    NOT NULL,
    Proc_        sysname        NOT NULL,
    Executions   int            NOT NULL,
    LastDop      bigint         NULL,
    CpuMsPer     decimal(12,2)  NULL,
    ElapsedMsPer decimal(12,2)  NULL,
    CxWaitMsPer  decimal(12,2)  NULL,     -- CXPACKET + CXCONSUMER, this session
    CapturedAt   datetime2(3)   NOT NULL CONSTRAINT DF_Runs_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  Demo.usp_Measure -- recompile @Proc (object scoped), run it once to warm
  the cache, then @Times more, and record CPU, elapsed and DOP per
  execution from sys.dm_exec_query_stats, plus this session's parallelism
  waits from sys.dm_exec_session_wait_stats.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Measure
    @Label varchar(40),
    @Proc  sysname,
    @Times int = 3
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @full nvarchar(300) = N'Demo.' + @Proc, @i int = 0, @cx0 bigint, @cx1 bigint;
    EXEC sys.sp_recompile @full;
    EXEC @full;                                     -- compile and warm up
    EXEC sys.sp_recompile @full;                    -- then start the counts clean

    SELECT @cx0 = ISNULL(SUM(wait_time_ms), 0) FROM sys.dm_exec_session_wait_stats
    WHERE session_id = @@SPID AND wait_type IN ('CXPACKET', 'CXCONSUMER');
    WHILE @i < @Times
    BEGIN
        EXEC @full;
        SET @i += 1;
    END
    SELECT @cx1 = ISNULL(SUM(wait_time_ms), 0) FROM sys.dm_exec_session_wait_stats
    WHERE session_id = @@SPID AND wait_type IN ('CXPACKET', 'CXCONSUMER');

    INSERT Demo.Runs (Label, Proc_, Executions, LastDop, CpuMsPer, ElapsedMsPer, CxWaitMsPer)
    SELECT TOP (1) @Label, @Proc, qs.execution_count, qs.last_dop,
           qs.total_worker_time / 1000.0 / qs.execution_count,
           qs.total_elapsed_time / 1000.0 / qs.execution_count,
           (@cx1 - @cx0) * 1.0 / @Times
    FROM   sys.dm_exec_procedure_stats AS ps
    JOIN   sys.dm_exec_query_stats AS qs ON qs.plan_handle = ps.plan_handle
    WHERE  ps.database_id = DB_ID() AND ps.object_id = OBJECT_ID(@full)
    ORDER BY qs.total_worker_time DESC;
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_ThreadRows -- from @Proc's last ACTUAL plan
  (sys.dm_exec_query_plan_stats), the rows each thread handled at the first
  operator called @PhysicalOp, and the busiest thread's share. Also says
  whether that operator ran in batch mode.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_ThreadRows
    @Proc        sysname,
    @PhysicalOp  varchar(40),
    @Threads     varchar(200)  OUTPUT,
    @MaxShare    decimal(5,1)  OUTPUT,
    @Mode        varchar(10)   OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @x xml;
    SELECT TOP (1) @x = qp.query_plan
    FROM   sys.dm_exec_procedure_stats AS ps
    CROSS APPLY sys.dm_exec_query_plan_stats(ps.plan_handle) AS qp
    WHERE  ps.database_id = DB_ID() AND ps.object_id = OBJECT_ID(N'Demo.' + @Proc);

    DECLARE @t TABLE (Thread int, Rows_ bigint);
    WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    INSERT @t
    SELECT c.c.value('@Thread', 'int'), c.c.value('@ActualRows', 'bigint')
    FROM   (SELECT op = @x.query('(//RelOp[@PhysicalOp = sql:variable("@PhysicalOp")])[1]')) AS o
    CROSS APPLY o.op.nodes('RelOp/RunTimeInformation/RunTimeCountersPerThread') AS c (c)
    WHERE  c.c.value('@Thread', 'int') > 0;    -- thread 0 coordinates; it does no rows here

    SELECT @Threads = STRING_AGG(CAST(Rows_ AS varchar(20)), ' / ') WITHIN GROUP (ORDER BY Thread),
           @MaxShare = 100.0 * MAX(Rows_) / NULLIF(SUM(Rows_), 0)
    FROM   @t;

    WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT @Mode = @x.value('(//RelOp[@PhysicalOp = sql:variable("@PhysicalOp")]/@EstimatedExecutionMode)[1]', 'varchar(10)');
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_PlanFacts -- from @Proc's cached plan: the degree of parallelism
  it was compiled for, its estimated cost, and NonParallelPlanReason (why
  the optimizer kept it serial, if it says).
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_PlanFacts
    @Proc    sysname,
    @Dop     int            OUTPUT,
    @Cost    decimal(12,3)  OUTPUT,
    @Reason  varchar(120)   OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @x xml;
    SELECT TOP (1) @x = qp.query_plan
    FROM   sys.dm_exec_procedure_stats AS ps
    CROSS APPLY sys.dm_exec_query_plan(ps.plan_handle) AS qp
    WHERE  ps.database_id = DB_ID() AND ps.object_id = OBJECT_ID(N'Demo.' + @Proc);

    -- The measured statement is the costliest one in the procedure.
    WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT TOP (1)
           @Dop    = ISNULL(s.s.value('(QueryPlan/@DegreeOfParallelism)[1]', 'int'), 1),
           @Cost   = s.s.value('@StatementSubTreeCost', 'decimal(12,3)'),
           @Reason = s.s.value('(QueryPlan/@NonParallelPlanReason)[1]', 'varchar(120)')
    FROM   @x.nodes('//StmtSimple') AS s (s)
    ORDER BY s.s.value('@StatementSubTreeCost', 'float') DESC;
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the ParallelDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
