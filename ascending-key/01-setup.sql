/*==============================================================================
  01-setup.sql          RUN ONCE. Takes under a minute.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, AscendingKeyDemo, and puts everything inside
     it. Nothing else on the instance is modified:

        - no compatibility level is changed (the new database keeps the
          instance default; the legacy estimator is reached by query hint)
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched
        - no instance-wide plan cache flush (sp_recompile only, object scoped)

  Creates, all inside AscendingKeyDemo:
     Demo.DemoState            - environment facts recorded at setup time
     Demo.DemoResults          - where 02-demo.sql records evidence
     Demo.ReportRuns           - one row per report execution (D and E)
     Demo.usp_Record           - the evidence collector used by 02
     Demo.Orders               - 1,000,000 orders across 2025, plus one week
                                 of 2026 that the statistics have not seen
     Demo.usp_MakeStale        - puts the statistics back into that state
     Demo.usp_B_Estimates      - scenario B: six estimates, one compile
     Demo.usp_Report*          - the "last week" report, three variants
     Demo.usp_RunReport        - runs a report variant, records its cost

  COST: by the end of 02-demo.sql the database has grown to about 650 MB:
  390 MB of data and 260 MB of log. All of it is inside AscendingKeyDemo, and
  03-cleanup.sql releases it.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers,
  MAXDOP 0, cost threshold for parallelism 5, database compatibility level 160.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
-- Demo.usp_RunReport uses XML methods, which fail with Msg 1934 unless the
-- procedure was CREATED under QUOTED_IDENTIFIER ON. SSMS defaults it ON;
-- sqlcmd does not (pass -I). Setting it here makes the file safe either way.
SET QUOTED_IDENTIFIER ON;
GO

PRINT '=== STEP 0: environment ===';
GO

SELECT  ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS sysname),
        EngineMajor    = CAST(SERVERPROPERTY('ProductMajorVersion') AS int),
        Edition        = CAST(SERVERPROPERTY('Edition') AS sysname);

SELECT  Schedulers = cpu_count FROM sys.dm_os_sys_info;

SELECT  name, value_in_use
FROM    sys.configurations
WHERE   name IN ('max degree of parallelism','cost threshold for parallelism')
ORDER BY name;
GO


PRINT '=== STEP 1: create AscendingKeyDemo ===';
GO

IF DB_ID('AscendingKeyDemo') IS NOT NULL
BEGIN
    RAISERROR('AscendingKeyDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE AscendingKeyDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE AscendingKeyDemo;
END
GO

CREATE DATABASE AscendingKeyDemo;
GO

ALTER DATABASE AscendingKeyDemo SET RECOVERY SIMPLE;
GO

USE AscendingKeyDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: state and evidence tables ===';
GO

DROP TABLE IF EXISTS Demo.DemoState;
CREATE TABLE Demo.DemoState
(
    SettingName  sysname       NOT NULL PRIMARY KEY,
    SettingValue nvarchar(256) NULL,
    CapturedAt   datetime2(0)  NOT NULL CONSTRAINT DF_AKState_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  The automatic statistics update thresholds depend on the compatibility
  level and the AUTO_UPDATE_STATISTICS settings, so they are recorded here, in
  the open, rather than assumed. Scenario C reads them back.
------------------------------------------------------------------------------*/
INSERT Demo.DemoState (SettingName, SettingValue)
SELECT 'ProductVersion',     CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(256)) UNION ALL
SELECT 'Schedulers',         CAST((SELECT cpu_count FROM sys.dm_os_sys_info) AS nvarchar(256)) UNION ALL
SELECT 'CompatibilityLevel', CAST(compatibility_level AS nvarchar(256))
                             FROM sys.databases WHERE name = DB_NAME() UNION ALL
SELECT 'AutoUpdateStats',    CASE is_auto_update_stats_on WHEN 1 THEN N'ON' ELSE N'OFF' END
                             FROM sys.databases WHERE name = DB_NAME() UNION ALL
SELECT 'AutoUpdateAsync',    CASE is_auto_update_stats_async_on WHEN 1 THEN N'ON' ELSE N'OFF' END
                             FROM sys.databases WHERE name = DB_NAME();

SELECT SettingName, SettingValue FROM Demo.DemoState ORDER BY SettingName;
GO

DROP TABLE IF EXISTS Demo.DemoResults;
CREATE TABLE Demo.DemoResults
(
    ResultID     int            IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Scenario     varchar(60)    NOT NULL,
    StepNo       int            NOT NULL,
    Item         varchar(90)    NOT NULL,   -- what was measured
    Measure      varchar(40)    NULL,       -- the unit / metric name
    NumericValue decimal(18,3)  NULL,
    TextValue    nvarchar(200)  NULL,
    Expected     nvarchar(140)  NULL,       -- what the scenario predicts
    Verdict      varchar(24)    NULL,       -- filled in by the scenario itself
    CapturedAt   datetime2(3)   NOT NULL CONSTRAINT DF_AKResults_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  One row per report execution in scenarios D and E. Wide, because the point
  is to read the estimate, the plan shape and the cost side by side.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.ReportRuns;
CREATE TABLE Demo.ReportRuns
(
    RunID        int           IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Scenario     varchar(60)   NOT NULL,
    StepNo       int           NOT NULL,
    Label        varchar(90)   NOT NULL,
    EstimateRows decimal(18,1) NULL,     -- on the operator that reads Demo.Orders
    ActualRows   bigint        NULL,     -- rows that match the predicate
    AccessOp     varchar(40)   NULL,
    LogicalReads bigint        NULL,
    Dop          int           NULL,
    GrantKB      bigint        NULL,
    ElapsedMs    int           NULL,
    CapturedAt   datetime2(3)  NOT NULL CONSTRAINT DF_AKRuns_CapturedAt DEFAULT SYSDATETIME()
);
GO

CREATE OR ALTER PROCEDURE Demo.usp_Record
    @Scenario     varchar(60),
    @StepNo       int,
    @Item         varchar(90),
    @Measure      varchar(40)   = NULL,
    @NumericValue decimal(18,3) = NULL,
    @TextValue    nvarchar(200) = NULL,
    @Expected     nvarchar(140) = NULL,
    @Verdict      varchar(24)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT Demo.DemoResults
           (Scenario, StepNo, Item, Measure, NumericValue, TextValue, Expected, Verdict)
    VALUES (@Scenario, @StepNo, @Item, @Measure, @NumericValue, @TextValue, @Expected, @Verdict);
END
GO


PRINT '=== STEP 3: Demo.Orders -- one year of history ===';
GO

/*------------------------------------------------------------------------------
  1,000,000 orders spread evenly over the 365 days of 2025: about 2,740 a day.
  OrderDate only ever grows, which is the whole point -- it is the "ascending
  key" of the title. Any table with a load date, an identity, or a sequence
  has one.

  The clustered key is OrderID. OrderDate has its own nonclustered index, and
  that index's statistics object is the one this topic is about. The report
  query needs CustomerID and Amount too, which the index does not carry, so
  the optimizer has a real choice to make: seek on OrderDate and look up each
  row, or scan the whole table. The estimate decides.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.Orders;
GO

CREATE TABLE Demo.Orders
(
    OrderID    int           IDENTITY(1,1) NOT NULL,
    OrderDate  date          NOT NULL,
    CustomerID int           NOT NULL,
    Amount     decimal(10,2) NOT NULL,
    pad        char(150)     NOT NULL CONSTRAINT DF_Orders_pad DEFAULT ('x'),
    CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderID)
);
GO

;WITH n AS
(
    SELECT TOP (1000000) rn = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b CROSS JOIN sys.all_columns AS c
)
INSERT Demo.Orders WITH (TABLOCK) (OrderDate, CustomerID, Amount)
SELECT DATEADD(day, CAST((rn - 1) * 365 / 1000000 AS int), CAST('20250101' AS date)),
       ABS(CHECKSUM(NEWID())) % 5000,
       ABS(CHECKSUM(NEWID())) % 100000 / 100.0
FROM   n
ORDER BY rn;
GO

CREATE INDEX IX_Orders_OrderDate ON Demo.Orders (OrderDate);
GO

SELECT HistoryRows = COUNT_BIG(*), FirstDay = MIN(OrderDate), LastDay = MAX(OrderDate)
FROM   Demo.Orders;
GO


PRINT '=== STEP 4: the procedures ===';
GO

/*------------------------------------------------------------------------------
  Demo.usp_MakeStale -- the state this whole topic is about, on demand.

    1. remove any 2026 rows left over from a previous run
    2. UPDATE STATISTICS WITH FULLSCAN: the histogram now ends at 2025-12-31,
       and every statistic's modification counter is reset to zero
    3. load @NewRows rows of 2026, 3,000 a day -- a busy week

  After step 3 the statistics are, by every measure SQL Server applies,
  perfectly healthy: built from a full scan, against a table that has since
  changed by about 2%. They simply do not know 2026 exists.

  02-demo.sql calls this before every scenario that changes the statistics,
  so each one starts from the same place and the file can be re-run.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_MakeStale
    @NewRows int = 21000
AS
BEGIN
    SET NOCOUNT ON;

    DELETE Demo.Orders WHERE OrderDate >= '20260101';

    UPDATE STATISTICS Demo.Orders WITH FULLSCAN;

    ;WITH n AS
    (
        SELECT TOP (@NewRows) rn = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
        FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
    )
    INSERT Demo.Orders (OrderDate, CustomerID, Amount)
    SELECT DATEADD(day, CAST((rn - 1) / 3000 AS int), CAST('20260101' AS date)),
           ABS(CHECKSUM(NEWID())) % 5000,
           ABS(CHECKSUM(NEWID())) % 100000 / 100.0
    FROM   n;
END
GO

/*------------------------------------------------------------------------------
  Scenario B: six statements, ONE procedure, so all six estimates come from a
  single compile against the same statistics. Each statement carries a marker
  (B1..B6) that 02-demo.sql finds in the plan XML.

  Three questions, each asked of both cardinality estimators:
     B1/B2  everything since 2026-01-01   -- entirely past the histogram
     B3/B4  one day, 2026-01-03           -- entirely past the histogram
     B5/B6  the last week of 2025         -- inside the histogram (control)

  The legacy estimator is reached with a query hint, not by changing the
  database's compatibility level or LEGACY_CARDINALITY_ESTIMATION setting.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_B_Estimates
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @c bigint;

    SELECT @c = COUNT_BIG(*) /* B1 */ FROM Demo.Orders
    WHERE  OrderDate >= '20260101';
    SELECT @c = COUNT_BIG(*) /* B2 */ FROM Demo.Orders
    WHERE  OrderDate >= '20260101'
    OPTION (USE HINT ('FORCE_LEGACY_CARDINALITY_ESTIMATION'));

    SELECT @c = COUNT_BIG(*) /* B3 */ FROM Demo.Orders
    WHERE  OrderDate = '20260103';
    SELECT @c = COUNT_BIG(*) /* B4 */ FROM Demo.Orders
    WHERE  OrderDate = '20260103'
    OPTION (USE HINT ('FORCE_LEGACY_CARDINALITY_ESTIMATION'));

    SELECT @c = COUNT_BIG(*) /* B5 */ FROM Demo.Orders
    WHERE  OrderDate >= '20251225' AND OrderDate < '20260101';
    SELECT @c = COUNT_BIG(*) /* B6 */ FROM Demo.Orders
    WHERE  OrderDate >= '20251225' AND OrderDate < '20260101'
    OPTION (USE HINT ('FORCE_LEGACY_CARDINALITY_ESTIMATION'));
END
GO

/*------------------------------------------------------------------------------
  The report: top 100 customers by spend since the start of the year. The
  sort of query a dashboard runs every morning, and the sort of query that
  is slow every morning until someone updates statistics.

  Three variants, identical except for the hint:
     usp_Report          the database's own estimator (compat 160 -> new CE)
     usp_Report_Legacy   FORCE_LEGACY_CARDINALITY_ESTIMATION
     usp_Report_Amended  legacy, plus ENABLE_HIST_AMENDMENT_FOR_ASC_KEYS --
                         the query-hint form of trace flag 4139, which lets
                         the optimizer extend the histogram at compile time
                         instead of assuming nothing lies past its last step

  A literal date, not a parameter, so that parameter sniffing cannot muddy
  which estimate produced which plan. That is a separate topic in this repo.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Report
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (100) CustomerID, Orders = COUNT_BIG(*), Total = SUM(Amount)
    FROM   Demo.Orders
    WHERE  OrderDate >= '20260101'
    GROUP BY CustomerID
    ORDER BY Total DESC;
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_Report_Legacy
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (100) CustomerID, Orders = COUNT_BIG(*), Total = SUM(Amount)
    FROM   Demo.Orders
    WHERE  OrderDate >= '20260101'
    GROUP BY CustomerID
    ORDER BY Total DESC
    OPTION (USE HINT ('FORCE_LEGACY_CARDINALITY_ESTIMATION'));
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_Report_Amended
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (100) CustomerID, Orders = COUNT_BIG(*), Total = SUM(Amount)
    FROM   Demo.Orders
    WHERE  OrderDate >= '20260101'
    GROUP BY CustomerID
    ORDER BY Total DESC
    OPTION (USE HINT ('FORCE_LEGACY_CARDINALITY_ESTIMATION',
                      'ENABLE_HIST_AMENDMENT_FOR_ASC_KEYS'));
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_RunReport -- recompile one report variant (object scoped), run it,
  and record what it cost in Demo.ReportRuns.

  Everything comes from sys.dm_exec_query_stats except two things only the
  plan knows: the estimated rows on the operator that reads Demo.Orders, and
  that operator's name -- "Index Seek" means seek on OrderDate and look up
  every row; "Clustered Index Scan" means read the whole table once.

  The plan for a stored procedure holds all of its statements. Each report
  procedure has exactly one, so the first RelOp that reads an index is the
  access operator. (The tempdb topic's README shows what goes wrong with
  '//RelOp' when a procedure has several statements.)

  The report's 100 rows go into a table variable via INSERT ... EXEC, so the
  demo does not print them on every execution.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_RunReport
    @Scenario  varchar(60),
    @StepNo    int,
    @Label     varchar(90),
    @Proc      sysname
AS
BEGIN
    SET NOCOUNT ON;

    EXEC sys.sp_recompile @Proc;

    DECLARE @sink TABLE (CustomerID int, Orders bigint, Total decimal(18,2));
    DECLARE @sql nvarchar(300) = N'EXEC ' + @Proc + N';';
    INSERT @sink EXEC sys.sp_executesql @sql;

    DECLARE @plan xml, @reads bigint, @dop int, @grant bigint, @ms int;

    SELECT TOP (1)
           @plan  = qp.query_plan,
           @reads = qs.last_logical_reads,
           @dop   = qs.last_dop,
           @grant = qs.last_grant_kb,
           @ms    = qs.last_elapsed_time / 1000
    FROM   sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
    WHERE  st.objectid = OBJECT_ID(@Proc)
      AND  st.dbid     = DB_ID()
    ORDER BY qs.last_execution_time DESC;

    DECLARE @est float, @op varchar(40);
    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT @est = @plan.value('(//RelOp[IndexScan]/@EstimateRows)[1]', 'float'),
           @op  = @plan.value('(//RelOp[IndexScan]/@PhysicalOp)[1]',   'varchar(40)');

    INSERT Demo.ReportRuns
           (Scenario, StepNo, Label, EstimateRows, ActualRows, AccessOp, LogicalReads, Dop, GrantKB, ElapsedMs)
    VALUES (@Scenario, @StepNo, @Label, @est,
            (SELECT COUNT_BIG(*) FROM Demo.Orders WHERE OrderDate >= '20260101'),
            @op, @reads, @dop, @grant, @ms);
END
GO

PRINT '=== STEP 5: make the statistics stale ===';
GO

EXEC Demo.usp_MakeStale @NewRows = 21000;
GO

SELECT  StatsName           = s.name,
        RowsAtLastUpdate    = sp.[rows],
        RowsSampled         = sp.rows_sampled,
        ModificationsSince  = sp.modification_counter,
        LastUpdated         = sp.last_updated
FROM    sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE   s.object_id = OBJECT_ID('Demo.Orders')
  AND   s.name = 'IX_Orders_OrderDate';

SELECT  TableRows = COUNT_BIG(*), LastDay = MAX(OrderDate) FROM Demo.Orders;
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the AscendingKeyDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
