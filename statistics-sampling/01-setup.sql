/*==============================================================================
  01-setup.sql          RUN ONCE. Takes under a minute.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, StatsSamplingDemo, and puts everything
     inside it. Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched
        - no instance-wide plan cache flush (sp_recompile only, object scoped)

  Creates, all inside StatsSamplingDemo:
     Demo.Orders            - 5,000,000 orders with a deliberately skewed
                              CustomerID, and an index on it
     Demo.usp_Estimates     - six estimates, compiled together
     Demo.Estimates         - one row per estimate per statistics state
     Demo.StatsStates       - the statistics header at each state
     Demo.usp_Capture       - records both

  COST: about 400 MB of data plus transaction log, all inside
  StatsSamplingDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), compatibility
  level 160.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;   -- Demo.usp_Capture uses XML methods
GO

PRINT '=== STEP 1: create StatsSamplingDemo ===';
GO

IF DB_ID('StatsSamplingDemo') IS NOT NULL
BEGIN
    RAISERROR('StatsSamplingDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE StatsSamplingDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE StatsSamplingDemo;
END
GO

CREATE DATABASE StatsSamplingDemo;
GO

ALTER DATABASE StatsSamplingDemo SET RECOVERY SIMPLE;
GO

USE StatsSamplingDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: Demo.Orders, 5,000,000 rows, skewed ===';
GO

/*------------------------------------------------------------------------------
  CustomerID is skewed on purpose, in four tiers:

     customer 1                       1,000,000 orders   the whale
     customers 2 to 21                   50,000 each      1,000,000 in all
     customers 50,001 to 51,000       jagged: EVEN ids 1,900 each, ODD ids
                                      100 each            1,000,000 in all
     customers 100,001 to 1,100,000           2 each      2,000,000 in all

  The jagged tier is there for the 200-step limit: a histogram has at most
  200 steps, these 1,000 customers alone have two very different sizes
  side by side, and a value that is not a step is estimated from the
  AVERAGE of its step range.

  Rows are stored in an order unrelated to CustomerID, so a sample of pages
  is a fair sample of customers -- the best case for sampling.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.Orders;
GO

CREATE TABLE Demo.Orders
(
    OrderID    int  NOT NULL,
    CustomerID int  NOT NULL,
    Amount     int  NOT NULL,
    CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderID)
);
GO

;WITH n AS
(
    SELECT TOP (5000000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b CROSS JOIN sys.all_columns AS c
),
c AS
(
    SELECT rn,
           CustomerID = CASE WHEN rn <= 1000000 THEN 1
                             WHEN rn <= 2000000 THEN 2 + (rn - 1000001) % 20
                             WHEN rn <= 3000000 THEN 50000 + 2 * ((rn - 2000001) / 2000)
                                                     + CASE WHEN (rn - 2000001) % 2000 < 1900 THEN 2 ELSE 1 END
                             ELSE 100001 + (rn - 3000001) % 1000000 END
    FROM   n
)
INSERT Demo.Orders WITH (TABLOCK) (OrderID, CustomerID, Amount)
SELECT ROW_NUMBER() OVER (ORDER BY CHECKSUM(CAST(rn AS bigint) * 7919, rn % 104729)),   -- scatter the tiers across the table
       CustomerID, rn % 1000
FROM   c;
GO

CREATE INDEX IX_Orders_CustomerID ON Demo.Orders (CustomerID);
GO

SELECT Tier = CASE WHEN CustomerID = 1 THEN '1 whale'
                   WHEN CustomerID <= 21 THEN '2 big'
                   WHEN CustomerID <= 51000 THEN '3 medium'
                   ELSE '4 tail' END,
       Customers = COUNT(DISTINCT CustomerID), Orders = COUNT_BIG(*)
FROM   Demo.Orders
GROUP BY CASE WHEN CustomerID = 1 THEN '1 whale'
              WHEN CustomerID <= 21 THEN '2 big'
              WHEN CustomerID <= 51000 THEN '3 medium'
              ELSE '4 tail' END
ORDER BY Tier;
GO


PRINT '=== STEP 3: the estimates, and the harness ===';
GO

/*------------------------------------------------------------------------------
  Six equality predicates, one per kind of value, compiled together:

     S1  CustomerID = 1          the whale              1,000,000
     S2  CustomerID = 7          a big customer            50,000
     S3  CustomerID = 50500      a medium, EVEN id          1,900
     S4  CustomerID = 50501      a medium, ODD id             100
     S5  CustomerID = 600000     a tail customer                2
     S6  CustomerID = 2000000    nobody                         0
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Estimates
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @c bigint;
    SELECT @c = COUNT_BIG(*) /* S1 */ FROM Demo.Orders WHERE CustomerID = 1;
    SELECT @c = COUNT_BIG(*) /* S2 */ FROM Demo.Orders WHERE CustomerID = 7;
    SELECT @c = COUNT_BIG(*) /* S3 */ FROM Demo.Orders WHERE CustomerID = 50500;
    SELECT @c = COUNT_BIG(*) /* S4 */ FROM Demo.Orders WHERE CustomerID = 50501;
    SELECT @c = COUNT_BIG(*) /* S5 */ FROM Demo.Orders WHERE CustomerID = 600000;
    SELECT @c = COUNT_BIG(*) /* S6 */ FROM Demo.Orders WHERE CustomerID = 2000000;
END
GO

DROP TABLE IF EXISTS Demo.Estimates;
CREATE TABLE Demo.Estimates
(
    StatsState   varchar(40)    NOT NULL,
    Marker       varchar(4)     NOT NULL,
    EstimateRows decimal(18,1)  NULL,
    CapturedAt   datetime2(3)   NOT NULL CONSTRAINT DF_SSEst_CapturedAt DEFAULT SYSDATETIME()
);

DROP TABLE IF EXISTS Demo.StatsStates;
CREATE TABLE Demo.StatsStates
(
    StatsState      varchar(40)    NOT NULL,
    RowsInTable     bigint         NULL,
    RowsSampled     bigint         NULL,
    SamplePct       decimal(6,2)   NULL,
    Steps           int            NULL,
    PersistedPct    decimal(6,2)   NULL,
    LastUpdated     datetime2(3)   NULL,
    CapturedAt      datetime2(3)   NOT NULL CONSTRAINT DF_SSStates_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  Demo.usp_Capture -- recompile Demo.usp_Estimates (object scoped), run it,
  record each statement's estimate from inside its own StmtSimple node, then
  record the IX_Orders_CustomerID statistics header.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Capture
    @StatsState varchar(40)
AS
BEGIN
    SET NOCOUNT ON;

    EXEC sys.sp_recompile N'Demo.usp_Estimates';
    EXEC Demo.usp_Estimates;

    DECLARE @plan xml;
    SELECT TOP (1) @plan = qp.query_plan
    FROM   sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
    WHERE  st.objectid = OBJECT_ID('Demo.usp_Estimates') AND st.dbid = DB_ID()
      AND  qp.query_plan IS NOT NULL;

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
     s AS
     (
        SELECT  Txt = n.value('@StatementText', 'nvarchar(400)'),
                Est = n.value('(.//RelOp[IndexScan or TableScan]/@EstimateRows)[1]', 'float')
        FROM    @plan.nodes('//StmtSimple') AS x(n)
     )
    INSERT Demo.Estimates (StatsState, Marker, EstimateRows)
    SELECT @StatsState, SUBSTRING(Txt, CHARINDEX('/* S', Txt) + 3, 2), Est
    FROM   s
    WHERE  Txt LIKE '%/* S%';

    -- The header is read AFTER the compile: compiling the queries is what
    -- triggers an automatic statistics update, when one is due.
    INSERT Demo.StatsStates (StatsState, RowsInTable, RowsSampled, SamplePct, Steps, PersistedPct, LastUpdated)
    SELECT @StatsState, sp.[rows], sp.rows_sampled, 100.0 * sp.rows_sampled / NULLIF(sp.[rows], 0),
           sp.steps, sp.persisted_sample_percent, sp.last_updated
    FROM   sys.stats AS s
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
    WHERE  s.object_id = OBJECT_ID('Demo.Orders') AND s.name = 'IX_Orders_CustomerID';
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the StatsSamplingDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
