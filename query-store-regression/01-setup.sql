/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, QueryStoreDemo, and puts everything inside
     it. Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched
        - no instance-wide plan cache flush (sp_recompile only, object scoped)

     Query Store is turned on for QueryStoreDemo with settings suited to a
     demo (capture every query, one-minute intervals), and 02-demo.sql clears
     QueryStoreDemo's Query Store at its start. Both are this database only.

  Creates, all inside QueryStoreDemo:
     Demo.Orders                 - 1,000,000 orders; customer 1 owns 300,000
     Demo.usp_CustomerSummary    - the query that will regress
     Demo.Calls                  - one row per measured call
     Demo.usp_Call               - calls it and records the reads
     Demo.QsPlans                - snapshots of its Query Store plans
     Demo.usp_QueryId / usp_QsSnapshot - read them out of Query Store

  COST: about 250 MB of data plus transaction log, all inside QueryStoreDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), compatibility
  level 160.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;   -- Demo.usp_QsSnapshot uses XML methods
GO

PRINT '=== STEP 1: create QueryStoreDemo, with Query Store ===';
GO

IF DB_ID('QueryStoreDemo') IS NOT NULL
BEGIN
    RAISERROR('QueryStoreDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE QueryStoreDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE QueryStoreDemo;
END
GO

CREATE DATABASE QueryStoreDemo;
GO

ALTER DATABASE QueryStoreDemo SET RECOVERY SIMPLE;
-- Capture mode ALL: the default (AUTO) skips queries it considers too cheap
-- to matter, which can include a demo's. One-minute intervals keep the
-- runtime statistics fine-grained.
ALTER DATABASE QueryStoreDemo SET QUERY_STORE = ON
    (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL, INTERVAL_LENGTH_MINUTES = 1);
GO

USE QueryStoreDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: Demo.Orders, deliberately skewed ===';
GO

/*------------------------------------------------------------------------------
  Customer 1 owns 300,000 of the 1,000,000 orders; every other customer about
  15. The index on CustomerID does not include Amount, so a small customer is
  best served by a seek plus lookups, and customer 1 by a scan. Which plan
  gets cached depends on which customer is asked for first after a compile
  -- which is how a perfectly good query regresses overnight.
------------------------------------------------------------------------------*/
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


PRINT '=== STEP 3: the query, and the harness ===';
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

CREATE TABLE Demo.Calls
(
    CallID       int           IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Scenario     varchar(60)   NOT NULL,
    CustomerID   int           NOT NULL,
    LogicalReads bigint        NULL,
    Succeeded    bit           NOT NULL,
    CapturedAt   datetime2(3)  NOT NULL CONSTRAINT DF_QSCalls_CapturedAt DEFAULT SYSDATETIME()
);
GO

-- Call the procedure @Times times for one customer; record each call's reads
-- (a delta of sys.dm_exec_requests for this session).
CREATE OR ALTER PROCEDURE Demo.usp_Call
    @Scenario   varchar(60),
    @CustomerID int,
    @Times      int = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @i int = 0, @r0 bigint, @ok bit;
    WHILE @i < @Times
    BEGIN
        SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
        SET @ok = 1;
        BEGIN TRY
            EXEC Demo.usp_CustomerSummary @CustomerID = @CustomerID;
        END TRY
        BEGIN CATCH
            SET @ok = 0;
        END CATCH
        INSERT Demo.Calls (Scenario, CustomerID, LogicalReads, Succeeded)
        SELECT @Scenario, @CustomerID, logical_reads - @r0, @ok
        FROM   sys.dm_exec_requests WHERE session_id = @@SPID;
        SET @i += 1;
    END
END
GO


CREATE TABLE Demo.QsPlans
(
    Label           varchar(60)    NOT NULL,
    PlanID          bigint         NOT NULL,
    PlanShape       varchar(30)    NULL,
    Executions      bigint         NULL,
    AvgReads        decimal(18,1)  NULL,
    IsForced        bit            NULL,
    ForceFailures   bigint         NULL,
    LastFailure     nvarchar(60)   NULL,
    CapturedAt      datetime2(3)   NOT NULL CONSTRAINT DF_QSPlans_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  Demo.usp_QueryId -- the Query Store query_id of the SELECT inside
  Demo.usp_CustomerSummary.

  Demo.usp_QsSnapshot -- every Query Store plan for that query: its shape,
  how many times it ran, its average logical reads (an execution-weighted
  average over all its runtime-statistics intervals), and its forcing state.
  Query Store's catalog views include statistics still held in memory, so
  nothing needs to be flushed to disk first.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_QueryId
    @QueryID bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (1) @QueryID = q.query_id
    FROM   sys.query_store_query AS q
    JOIN   sys.query_store_query_text AS t ON t.query_text_id = q.query_text_id
    WHERE  q.object_id = OBJECT_ID('Demo.usp_CustomerSummary')
      AND  t.query_sql_text LIKE N'%COUNT_BIG%'
    ORDER BY q.query_id;
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_QsSnapshot
    @Label varchar(60)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @q bigint;
    EXEC Demo.usp_QueryId @q OUTPUT;

    INSERT Demo.QsPlans (Label, PlanID, PlanShape, Executions, AvgReads, IsForced, ForceFailures, LastFailure)
    SELECT  @Label, p.plan_id,
            CASE WHEN TRY_CAST(p.query_plan AS xml).exist('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan"; //IndexScan[@Lookup="1"]') = 1
                 THEN 'seek + lookups' ELSE 'scan' END,
            SUM(rs.count_executions),
            SUM(rs.avg_logical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0),
            p.is_forced_plan, p.force_failure_count, p.last_force_failure_reason_desc
    FROM    sys.query_store_plan AS p
    LEFT JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
    WHERE   p.query_id = @q
    GROUP BY p.plan_id, p.query_plan, p.is_forced_plan, p.force_failure_count, p.last_force_failure_reason_desc;
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the QueryStoreDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
