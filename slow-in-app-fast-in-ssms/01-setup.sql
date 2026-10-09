/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, SetOptionsDemo, and puts everything inside
     it. Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched
        - no instance-wide plan cache flush (sp_recompile only, object scoped)

     02-demo.sql changes SET ARITHABORT for its OWN session only, which is
     the whole point of the topic. Session SET options end with the session.

  Creates, all inside SetOptionsDemo:
     Demo.Orders                  - 1,000,000 orders; customer 1 owns 300,000
     Demo.usp_CustomerSummary     - the procedure "the app" and "SSMS" both call
     Demo.Calls                   - one row per measured call
     Demo.CachedPlans             - snapshots of the procedure's cached plans
     Demo.usp_Call                - calls the procedure and records it
     Demo.usp_SnapshotPlans       - records every cached plan for the procedure

  COST: about 250 MB of data plus transaction log, all inside SetOptionsDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;   -- Demo.usp_SnapshotPlans uses XML methods
GO

PRINT '=== STEP 1: create SetOptionsDemo ===';
GO

IF DB_ID('SetOptionsDemo') IS NOT NULL
BEGIN
    RAISERROR('SetOptionsDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE SetOptionsDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE SetOptionsDemo;
END
GO

CREATE DATABASE SetOptionsDemo;
GO

ALTER DATABASE SetOptionsDemo SET RECOVERY SIMPLE;
GO

USE SetOptionsDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: Demo.Orders, deliberately skewed ===';
GO

/*------------------------------------------------------------------------------
  Customer 1 is a giant: 300,000 of the 1,000,000 orders. Every other
  customer has about 15. That skew is manufactured on purpose -- it is what
  makes the plan for one customer wrong for the other, which is what
  parameter sniffing needs to do damage (see the parameter-sniffing topic).

  The index on CustomerID does not include Amount, so a small customer is
  best served by a seek plus lookups and the giant by a scan.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.Orders;
GO

CREATE TABLE Demo.Orders
(
    OrderID    int            NOT NULL,
    CustomerID int            NOT NULL,
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
INSERT Demo.Orders WITH (TABLOCK) (OrderID, CustomerID, Amount)
SELECT rn,
       CASE WHEN rn % 10 < 3 THEN 1 ELSE rn % 70000 + 2 END,
       (rn % 10000) / 100.0
FROM   n;
GO

CREATE INDEX IX_Orders_CustomerID ON Demo.Orders (CustomerID);
GO

SELECT Customer1 = SUM(CASE WHEN CustomerID = 1  THEN 1 ELSE 0 END),
       Customer45 = SUM(CASE WHEN CustomerID = 45 THEN 1 ELSE 0 END),
       Total = COUNT_BIG(*)
FROM   Demo.Orders;
GO


PRINT '=== STEP 3: the procedure, and the harness ===';
GO

CREATE OR ALTER PROCEDURE Demo.usp_CustomerSummary
    @CustomerID int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @n bigint, @total decimal(18,2);
    SELECT @n = COUNT_BIG(*), @total = SUM(Amount)
    FROM   Demo.Orders
    WHERE  CustomerID = @CustomerID;
END
GO

DROP TABLE IF EXISTS Demo.Calls;
CREATE TABLE Demo.Calls
(
    CallID       int           IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Scenario     varchar(60)   NOT NULL,
    StepNo       int           NOT NULL,
    WhoCalls     varchar(30)   NOT NULL,   -- 'app (ARITHABORT OFF)' or 'SSMS (ARITHABORT ON)'
    CustomerID   int           NOT NULL,
    ArithAbort   bit           NOT NULL,   -- read from @@OPTIONS at call time
    LogicalReads bigint        NULL,
    CpuMs        int           NULL,
    CapturedAt   datetime2(3)  NOT NULL CONSTRAINT DF_SOCalls_CapturedAt DEFAULT SYSDATETIME()
);

DROP TABLE IF EXISTS Demo.CachedPlans;
CREATE TABLE Demo.CachedPlans
(
    Scenario        varchar(60)   NOT NULL,
    StepNo          int           NOT NULL,
    SetOptions      int           NULL,     -- the plan's set_options cache key
    ArithAbortOn    bit           NULL,     -- bit 4096 of set_options
    CompiledFor     nvarchar(40)  NULL,     -- ParameterCompiledValue of @CustomerID
    PlanShape       varchar(30)   NULL,
    ExecutionCount  bigint        NULL,
    CapturedAt      datetime2(3)  NOT NULL CONSTRAINT DF_SOPlans_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  Demo.usp_Call -- call the procedure once and record the reads and CPU.

  ARITHABORT is NOT set here. It is set by the batch in 02-demo.sql that
  calls this, exactly as a client connection sets it, and read back from
  @@OPTIONS (bit 64) so the record shows what was really in effect.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Call
    @Scenario   varchar(60),
    @StepNo     int,
    @CustomerID int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @arith bit = CASE WHEN @@OPTIONS & 64 = 64 THEN 1 ELSE 0 END;
    DECLARE @r0 bigint, @c0 int;

    SELECT @r0 = logical_reads, @c0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    EXEC Demo.usp_CustomerSummary @CustomerID = @CustomerID;

    INSERT Demo.Calls (Scenario, StepNo, WhoCalls, CustomerID, ArithAbort, LogicalReads, CpuMs)
    SELECT @Scenario, @StepNo,
           CASE @arith WHEN 1 THEN 'SSMS (ARITHABORT ON)' ELSE 'app (ARITHABORT OFF)' END,
           @CustomerID, @arith,
           logical_reads - @r0, cpu_time - @c0
    FROM   sys.dm_exec_requests WHERE session_id = @@SPID;
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_SnapshotPlans -- every cached plan for Demo.usp_CustomerSummary,
  with the attribute that separates them: set_options. Two connections whose
  SET options differ cannot share a plan, so the same procedure can be cached
  several times over, each copy compiled -- sniffed -- for whatever
  parameter value happened to arrive first on that kind of connection.

  The plan XML records that value as ParameterCompiledValue.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_SnapshotPlans
    @Scenario varchar(60),
    @StepNo   int
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    INSERT Demo.CachedPlans (Scenario, StepNo, SetOptions, ArithAbortOn, CompiledFor, PlanShape, ExecutionCount)
    SELECT  @Scenario, @StepNo,
            so.v,
            CASE WHEN so.v & 4096 = 4096 THEN 1 ELSE 0 END,
            qp.query_plan.value('(//ParameterList/ColumnReference[@Column="@CustomerID"]/@ParameterCompiledValue)[1]', 'nvarchar(40)'),
            CASE WHEN qp.query_plan.exist('//IndexScan[@Lookup="1"]') = 1 THEN 'seek + lookups'
                 WHEN qp.query_plan.exist('//RelOp[@PhysicalOp="Clustered Index Scan"]') = 1 THEN 'clustered scan'
                 ELSE 'other' END,
            qs.execution_count
    FROM    sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
    CROSS APPLY (SELECT v = CAST(pa.value AS int)
                 FROM   sys.dm_exec_plan_attributes(qs.plan_handle) AS pa
                 WHERE  pa.attribute = 'set_options') AS so
    WHERE   st.objectid = OBJECT_ID('Demo.usp_CustomerSummary')
      AND   st.dbid     = DB_ID();
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the SetOptionsDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
