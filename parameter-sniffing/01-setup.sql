/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few minutes.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  Creates, all inside a Demo schema so 03-cleanup.sql can remove it cleanly:
     Demo.DemoState                        - remembers settings we change
     Demo.OrderLinesSkewed                 - WWI order lines + one huge customer
     Demo.usp_CustomerLinesByPrice         - THE procedure that sniffs badly
     Demo.usp_CustomerLinesByPrice_Recompile - same query, OPTION (RECOMPILE)
     Demo.DemoResults                      - where 02-demo.sql records evidence
     Demo.usp_Capture                      - evidence collector used by 02
     Demo.vw_GrantStats / Demo.vw_CachedPlan - for ad-hoc poking around
     Demo_ParamSniffing                    - Extended Events session (optional)

  CHANGES TO YOUR DATABASE (all recorded in Demo.DemoState, all restored by
  03-cleanup.sql):
     - compatibility level is raised to the highest this engine supports.
       WideWorldImporters ships at 130; row mode memory grant feedback needs
       150 and Parameter Sensitive Plan optimization needs 160.
     - on SQL Server 2022+, PARAMETER_SENSITIVE_PLAN_OPTIMIZATION is turned OFF.
       PSP targets exactly this query shape and will fix the demo out from under
       you. Scenario E in 02-demo.sql turns it back on to show the contrast.

  COST: ~500,000 extra rows carrying a char(200) column. Budget a few hundred MB
  of data plus transaction log. 03-cleanup.sql drops it all.

  UNTESTED: written without access to a SQL Server instance. Run it on a scratch
  copy of WideWorldImporters first.
==============================================================================*/

USE WideWorldImporters;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 0: environment ===';
GO

/*------------------------------------------------------------------------------
  0. Ground truth. Read this output -- which mitigations exist is decided here,
     and the knob names differ across 2017 / 2019 / 2022 / 2025. Don't take a
     configuration name on faith from any blog post, including the comments in
     this file.
------------------------------------------------------------------------------*/
SELECT  ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS sysname),
        EngineMajor    = CAST(SERVERPROPERTY('ProductMajorVersion') AS int),
        Edition        = CAST(SERVERPROPERTY('Edition') AS sysname),
        DatabaseName   = DB_NAME(),
        CompatLevel    = d.compatibility_level,
        QueryStoreOn   = d.is_query_store_on
FROM    sys.databases AS d
WHERE   d.database_id = DB_ID();

SELECT  name, value, value_for_secondary
FROM    sys.database_scoped_configurations
WHERE   name LIKE '%FEEDBACK%' OR name LIKE '%PARAMETER_SENSITIVE%'
ORDER BY name;
GO

IF OBJECT_ID('Sales.OrderLines') IS NULL OR OBJECT_ID('Warehouse.StockItems') IS NULL
BEGIN
    RAISERROR('This does not look like WideWorldImporters. Aborting.', 16, 1);
    SET NOEXEC ON;
END
GO


PRINT '=== STEP 1: schema and state ===';
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO

DROP TABLE IF EXISTS Demo.DemoState;
CREATE TABLE Demo.DemoState
(
    SettingName  sysname       NOT NULL PRIMARY KEY,
    SettingValue nvarchar(256) NULL,
    CapturedAt   datetime2(0)  NOT NULL CONSTRAINT DF_DemoState_CapturedAt DEFAULT SYSDATETIME()
);
GO

-- Record what we are about to change, BEFORE changing it.
INSERT Demo.DemoState (SettingName, SettingValue)
SELECT 'OriginalCompatLevel', CAST(compatibility_level AS nvarchar(10))
FROM   sys.databases WHERE database_id = DB_ID();

INSERT Demo.DemoState (SettingName, SettingValue)
SELECT 'DSC_' + name, CAST(value AS nvarchar(256))
FROM   sys.database_scoped_configurations
WHERE  name IN (N'PARAMETER_SENSITIVE_PLAN_OPTIMIZATION',
                N'ROW_MODE_MEMORY_GRANT_FEEDBACK',
                N'BATCH_MODE_MEMORY_GRANT_FEEDBACK');

SELECT SettingName, SettingValue FROM Demo.DemoState ORDER BY SettingName;
GO


PRINT '=== STEP 2: compatibility level and PSP ===';
GO

DECLARE @major   int = CAST(SERVERPROPERTY('ProductMajorVersion') AS int);
DECLARE @target  int = @major * 10;      -- 14->140, 15->150, 16->160, 17->170
DECLARE @current int = (SELECT compatibility_level FROM sys.databases WHERE database_id = DB_ID());
DECLARE @sql     nvarchar(400);

IF @current < @target
BEGIN
    SET @sql = N'ALTER DATABASE ' + QUOTENAME(DB_NAME())
             + N' SET COMPATIBILITY_LEVEL = ' + CAST(@target AS nvarchar(10)) + N';';
    RAISERROR('Raising compatibility level %d -> %d (03-cleanup.sql restores it).', 0, 1, @current, @target) WITH NOWAIT;
    EXEC sys.sp_executesql @sql;
END
ELSE
    RAISERROR('Compatibility level already %d. Leaving it alone.', 0, 1, @current) WITH NOWAIT;

-- Turn PSP off if this build has it, so classic sniffing is visible.
IF EXISTS (SELECT 1 FROM sys.database_scoped_configurations
           WHERE name = N'PARAMETER_SENSITIVE_PLAN_OPTIMIZATION')
BEGIN
    RAISERROR('Disabling PARAMETER_SENSITIVE_PLAN_OPTIMIZATION for the demo.', 0, 1) WITH NOWAIT;
    ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = OFF;
END
ELSE
    RAISERROR('No PARAMETER_SENSITIVE_PLAN_OPTIMIZATION on this build. Nothing to disable.', 0, 1) WITH NOWAIT;
GO


PRINT '=== STEP 3: build the skewed table (this is the slow part) ===';
GO

/*------------------------------------------------------------------------------
  Why a new table?

  WideWorldImporters is generated with near-uniform distributions. No equality
  predicate on the stock OLTP tables has enough skew to flip a plan hard, so
  the skew here is created deliberately and in the open rather than hunted for.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.OrderLinesSkewed;
GO

CREATE TABLE Demo.OrderLinesSkewed
(
    OrderLineID int           IDENTITY(1,1) NOT NULL,
    OrderID     int           NOT NULL,
    CustomerID  int           NOT NULL,
    StockItemID int           NOT NULL,
    Description nvarchar(100) NOT NULL,
    Quantity    int           NOT NULL,
    UnitPrice   decimal(18,2) NOT NULL,
    OrderDate   date          NOT NULL,
    -- Filler makes rows wide. A memory grant is estimated rows * estimated row
    -- width, so width is half of what makes the grant wrong.
    Filler      char(200)     NOT NULL,
    CONSTRAINT PK_OrderLinesSkewed PRIMARY KEY CLUSTERED (OrderLineID)
);
GO

/* 3a. Pick the whale and the minnow FROM the data and print them. Do not
       hardcode CustomerIDs -- WWI ships in more than one shape. */
DECLARE @Whale int, @Minnow int;

;WITH LineCounts AS
(
    SELECT o.CustomerID, LineCount = COUNT_BIG(*)
    FROM   Sales.Orders     AS o
    JOIN   Sales.OrderLines AS ol ON ol.OrderID = o.OrderID
    GROUP BY o.CustomerID
)
SELECT  @Whale  = (SELECT TOP (1) CustomerID FROM LineCounts ORDER BY LineCount DESC, CustomerID),
        @Minnow = (SELECT TOP (1) CustomerID FROM LineCounts ORDER BY LineCount ASC,  CustomerID);

DELETE Demo.DemoState WHERE SettingName IN ('WhaleCustomerID','MinnowCustomerID');
INSERT Demo.DemoState (SettingName, SettingValue)
VALUES ('WhaleCustomerID',  CAST(@Whale  AS nvarchar(20))),
       ('MinnowCustomerID', CAST(@Minnow AS nvarchar(20)));

SELECT Role = 'Whale',  CustomerID = @Whale,
       CustomerName = (SELECT CustomerName FROM Sales.Customers WHERE CustomerID = @Whale)
UNION ALL
SELECT 'Minnow', @Minnow,
       (SELECT CustomerName FROM Sales.Customers WHERE CustomerID = @Minnow);
GO

/* 3b. Every real WWI order line except the whale's -- the "normal" population:
       several hundred customers with a few hundred rows each. */
DECLARE @Whale int = (SELECT CAST(SettingValue AS int) FROM Demo.DemoState WHERE SettingName = 'WhaleCustomerID');

INSERT Demo.OrderLinesSkewed
       (OrderID, CustomerID, StockItemID, Description, Quantity, UnitPrice, OrderDate, Filler)
SELECT ol.OrderID, o.CustomerID, ol.StockItemID, ol.Description,
       ol.Quantity, ol.UnitPrice, o.OrderDate, REPLICATE('x', 200)
FROM   Sales.OrderLines AS ol
JOIN   Sales.Orders     AS o ON o.OrderID = ol.OrderID
WHERE  o.CustomerID <> @Whale;

RAISERROR('  baseline rows loaded: %d', 0, 1, @@ROWCOUNT) WITH NOWAIT;
GO

/* 3c. Make one customer enormous. Batched so the log can clear between batches. */
DECLARE @Whale     int = (SELECT CAST(SettingValue AS int) FROM Demo.DemoState WHERE SettingName = 'WhaleCustomerID'),
        @WhaleRows int = 500000,
        @BatchSize int = 100000,
        @Loaded    int = 0,
        @ThisBatch int,
        @ItemCount int = (SELECT COUNT(*) FROM Warehouse.StockItems);

WHILE @Loaded < @WhaleRows
BEGIN
    SET @ThisBatch = CASE WHEN @WhaleRows - @Loaded < @BatchSize
                          THEN @WhaleRows - @Loaded ELSE @BatchSize END;

    ;WITH Nums AS
    (
        SELECT TOP (@ThisBatch)
               n = CAST(@Loaded AS bigint) + ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
        FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
    ),
    Items AS
    (
        SELECT StockItemID, StockItemName, UnitPrice,
               rn = ROW_NUMBER() OVER (ORDER BY StockItemID) - 1
        FROM   Warehouse.StockItems
    )
    INSERT Demo.OrderLinesSkewed
           (OrderID, CustomerID, StockItemID, Description, Quantity, UnitPrice, OrderDate, Filler)
    SELECT CAST(1000000 + nums.n AS int),
           @Whale,
           i.StockItemID,
           i.StockItemName,
           1 + CAST(nums.n % 20 AS int),
           -- Spread prices out so the sort has real work and cannot be short-circuited.
           CAST(i.UnitPrice * (1.0 + ((nums.n % 997) / 1000.0)) AS decimal(18,2)),
           DATEADD(day, -CAST(nums.n % 1500 AS int), CAST('2016-05-31' AS date)),
           REPLICATE('x', 200)
    FROM   Nums AS nums
    JOIN   Items AS i ON i.rn = nums.n % @ItemCount;

    SET @Loaded += @ThisBatch;
    RAISERROR('  whale rows loaded: %d of %d', 0, 1, @Loaded, @WhaleRows) WITH NOWAIT;
END
GO

/* 3d. One NARROW non-clustered index. Narrow on purpose: it forces the optimizer
       to choose between (seek + key lookup) and (clustered scan), which is the
       plan-shape half of parameter sniffing. Add INCLUDE columns and you get a
       covering index, the choice disappears, and only the memory grant half of
       the demo survives. */
CREATE NONCLUSTERED INDEX IX_OrderLinesSkewed_CustomerID
    ON Demo.OrderLinesSkewed (CustomerID);
GO

-- FULLSCAN matters. Sampled statistics may not describe the skew sharply enough
-- for the two plans to differ.
UPDATE STATISTICS Demo.OrderLinesSkewed WITH FULLSCAN;
GO

SELECT TotalRows = COUNT_BIG(*), DistinctCustomers = COUNT(DISTINCT CustomerID)
FROM   Demo.OrderLinesSkewed;

SELECT Label = 'Top 5 by row count', CustomerID, Rows = COUNT_BIG(*)
FROM   Demo.OrderLinesSkewed GROUP BY CustomerID ORDER BY Rows DESC
OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY;

SELECT Label = 'Bottom 5 by row count', CustomerID, Rows = COUNT_BIG(*)
FROM   Demo.OrderLinesSkewed GROUP BY CustomerID ORDER BY Rows ASC
OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY;
GO


PRINT '=== STEP 4: the procedures ===';
GO

/*------------------------------------------------------------------------------
  THE procedure. Deliberately plain: no TOP, no window function.

  A TOP (n) ... ORDER BY produces a Top N Sort, whose memory grant is sized from
  n rather than from the input row count -- that would quietly delete the memory
  grant half of the demo. Filtering a ROW_NUMBER() against a constant has the
  same hazard, because the optimizer can rewrite it into a Top.

  02-demo.sql records the plan shape for you. If it ever reports "Top N Sort",
  the demo is not measuring what you think it is.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_CustomerLinesByPrice
    @CustomerID int
AS
BEGIN
    SET NOCOUNT ON;

    SELECT  ol.OrderLineID,
            ol.OrderID,
            ol.CustomerID,
            ol.StockItemID,
            ol.Description,
            ol.Quantity,
            ol.UnitPrice,
            ol.OrderDate,
            ol.Filler           -- wide column: this is what makes the grant big
    FROM    Demo.OrderLinesSkewed AS ol
    WHERE   ol.CustomerID = @CustomerID
    ORDER BY ol.UnitPrice DESC, ol.Description;
END
GO

/*  Identical query, plus OPTION (RECOMPILE). Used by scenario D.
    Note what you will NOT find afterwards: a cached plan. That is the point --
    there is no retained plan for memory grant feedback to attach to.           */
CREATE OR ALTER PROCEDURE Demo.usp_CustomerLinesByPrice_Recompile
    @CustomerID int
AS
BEGIN
    SET NOCOUNT ON;

    SELECT  ol.OrderLineID,
            ol.OrderID,
            ol.CustomerID,
            ol.StockItemID,
            ol.Description,
            ol.Quantity,
            ol.UnitPrice,
            ol.OrderDate,
            ol.Filler
    FROM    Demo.OrderLinesSkewed AS ol
    WHERE   ol.CustomerID = @CustomerID
    ORDER BY ol.UnitPrice DESC, ol.Description
    OPTION (RECOMPILE);
END
GO


PRINT '=== STEP 5: evidence collection ===';
GO

DROP TABLE IF EXISTS Demo.DemoResults;
CREATE TABLE Demo.DemoResults
(
    ResultID        int           IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Scenario        varchar(60)   NOT NULL,
    StepNo          int           NOT NULL,
    StepDescription varchar(200)  NOT NULL,
    ObjectName      sysname       NULL,
    ParamUsed       int           NULL,
    ParamRole       varchar(20)   NULL,
    SniffedValue    nvarchar(128) NULL,   -- the value the cached plan was built for
    PlanShape       varchar(300)  NULL,
    EstimatedRows   float         NULL,
    ActualRows      bigint        NULL,
    GrantMB         decimal(18,2) NULL,   -- what the engine handed out
    UsedGrantMB     decimal(18,2) NULL,   -- what the query actually touched
    IdealGrantMB    decimal(18,2) NULL,   -- what it should have had
    LogicalReads    bigint        NULL,
    ElapsedMs       bigint        NULL,
    MGFeedbackState nvarchar(50)  NULL,   -- IsMemoryGrantFeedbackAdjusted
    ExecutionCount  bigint        NULL,
    PlanGenNum      bigint        NULL,
    CapturedAt      datetime2(3)  NOT NULL CONSTRAINT DF_DemoResults_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  Reads the DMVs immediately after an execution and files the result. This is
  what lets 02-demo.sql run start to finish without you stepping through it and
  reading actual execution plans by hand.

  sys.dm_exec_query_stats has no object_id column, so the owning object is
  resolved through sys.dm_exec_sql_text.

  The XQuery uses local-name() rather than declaring the showplan namespace or
  using a namespace wildcard. It is more verbose, but it is plain supported
  XQuery and cannot break on a namespace change -- and since this proc is what
  produces ALL of the demo's evidence, it is the wrong place to be clever.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Capture
    @Scenario        varchar(60),
    @StepNo          int,
    @StepDescription varchar(200),
    @ObjectName      sysname,
    @ParamUsed       int          = NULL,
    @ParamRole       varchar(20)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @objid int = OBJECT_ID(@ObjectName);

    DECLARE @plan_handle  varbinary(64),
            @grant_kb     bigint,
            @used_kb      bigint,
            @ideal_kb     bigint,
            @rows         bigint,
            @reads        bigint,
            @elapsed      bigint,
            @execs        bigint,
            @plangen      bigint;

    SELECT TOP (1)
           @plan_handle = qs.plan_handle,
           @grant_kb    = qs.last_grant_kb,
           @used_kb     = qs.last_used_grant_kb,
           @ideal_kb    = qs.last_ideal_grant_kb,
           @rows        = qs.last_rows,
           @reads       = qs.last_logical_reads,
           @elapsed     = qs.last_elapsed_time / 1000,
           @execs       = qs.execution_count,
           @plangen     = qs.plan_generation_num
    FROM   sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
    WHERE  st.objectid = @objid
      AND  st.dbid     = DB_ID()
    ORDER BY qs.last_execution_time DESC;

    DECLARE @plan xml = (SELECT query_plan FROM sys.dm_exec_query_plan(@plan_handle));

    DECLARE @sniffed nvarchar(128),
            @est     float,
            @mgf     nvarchar(50),
            @shape   varchar(300);

    IF @plan IS NULL
        SET @shape = '(no cached plan - expected for OPTION (RECOMPILE))';
    ELSE
    BEGIN
        SET @sniffed = @plan.value('(//*[local-name()="ColumnReference"]/@ParameterCompiledValue)[1]', 'nvarchar(128)');
        SET @est     = @plan.value('(//*[local-name()="QueryPlan"]/*[local-name()="RelOp"]/@EstimateRows)[1]', 'float');
        SET @mgf     = @plan.value('(//*[local-name()="MemoryGrantInfo"]/@IsMemoryGrantFeedbackAdjusted)[1]', 'nvarchar(50)');

        SET @shape = STUFF(
              CASE WHEN @plan.exist('//*[local-name()="RelOp"][@PhysicalOp="Index Seek"]')           = 1 THEN ' + Index Seek'           ELSE '' END
            + CASE WHEN @plan.exist('//*[local-name()="RelOp"][@PhysicalOp="Key Lookup"]')           = 1 THEN ' + Key Lookup'           ELSE '' END
            + CASE WHEN @plan.exist('//*[local-name()="RelOp"][@PhysicalOp="Clustered Index Scan"]') = 1 THEN ' + Clustered Index Scan' ELSE '' END
            + CASE WHEN @plan.exist('//*[local-name()="RelOp"][@PhysicalOp="Table Scan"]')           = 1 THEN ' + Table Scan'           ELSE '' END
            + CASE WHEN @plan.exist('//*[local-name()="RelOp"][@PhysicalOp="Sort"]')                 = 1 THEN ' + Sort'                 ELSE '' END
            + CASE WHEN @plan.exist('//*[local-name()="RelOp"][@PhysicalOp="Top N Sort"]')           = 1 THEN ' + Top N Sort (BROKEN DEMO - see 01-setup step 4)' ELSE '' END
            + CASE WHEN @plan.exist('//*[local-name()="RelOp"][@Parallel="1"]')                      = 1 THEN ' + PARALLEL'             ELSE '' END
            , 1, 3, '');
    END

    IF @plan_handle IS NULL
        SET @shape = ISNULL(@shape, '') + ' (no query_stats row found)';

    INSERT Demo.DemoResults
           (Scenario, StepNo, StepDescription, ObjectName, ParamUsed, ParamRole,
            SniffedValue, PlanShape, EstimatedRows, ActualRows,
            GrantMB, UsedGrantMB, IdealGrantMB, LogicalReads, ElapsedMs,
            MGFeedbackState, ExecutionCount, PlanGenNum)
    VALUES (@Scenario, @StepNo, @StepDescription, @ObjectName, @ParamUsed, @ParamRole,
            @sniffed, @shape, @est, @rows,
            @grant_kb / 1024.0, @used_kb / 1024.0, @ideal_kb / 1024.0, @reads, @elapsed,
            @mgf, @execs, @plangen);
END
GO


PRINT '=== STEP 6: ad-hoc views ===';
GO

CREATE OR ALTER VIEW Demo.vw_GrantStats
AS
SELECT  ObjectName       = OBJECT_NAME(st.objectid, st.dbid),
        qs.execution_count,
        qs.plan_generation_num,
        LastGrantMB      = qs.last_grant_kb       / 1024.0,
        LastUsedGrantMB  = qs.last_used_grant_kb  / 1024.0,
        LastIdealGrantMB = qs.last_ideal_grant_kb / 1024.0,
        MinGrantMB       = qs.min_grant_kb        / 1024.0,
        MaxGrantMB       = qs.max_grant_kb        / 1024.0,
        qs.last_rows,
        qs.last_logical_reads,
        LastElapsedMs    = qs.last_elapsed_time / 1000,
        qs.creation_time,
        qs.last_execution_time
FROM    sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
WHERE   st.objectid IN (OBJECT_ID('Demo.usp_CustomerLinesByPrice'),
                        OBJECT_ID('Demo.usp_CustomerLinesByPrice_Recompile'))
  AND   st.dbid = DB_ID();
GO

CREATE OR ALTER VIEW Demo.vw_CachedPlan
AS
SELECT  ObjectName             = OBJECT_NAME(st.objectid, st.dbid),
        cp.usecounts,
        ParameterCompiledValue = qp.query_plan.value('(//*[local-name()="ColumnReference"]/@ParameterCompiledValue)[1]', 'nvarchar(128)'),
        EstimatedRows          = qp.query_plan.value('(//*[local-name()="QueryPlan"]/*[local-name()="RelOp"]/@EstimateRows)[1]', 'float'),
        SerialRequiredKB       = qp.query_plan.value('(//*[local-name()="MemoryGrantInfo"]/@SerialRequiredMemory)[1]', 'bigint'),
        SerialDesiredKB        = qp.query_plan.value('(//*[local-name()="MemoryGrantInfo"]/@SerialDesiredMemory)[1]', 'bigint'),
        RequestedKB            = qp.query_plan.value('(//*[local-name()="MemoryGrantInfo"]/@RequestedMemory)[1]', 'bigint'),
        GrantedKB              = qp.query_plan.value('(//*[local-name()="MemoryGrantInfo"]/@GrantedMemory)[1]', 'bigint'),
        MaxUsedKB              = qp.query_plan.value('(//*[local-name()="MemoryGrantInfo"]/@MaxUsedMemory)[1]', 'bigint'),
        LastRequestedKB        = qp.query_plan.value('(//*[local-name()="MemoryGrantInfo"]/@LastRequestedMemory)[1]', 'bigint'),
        MGFeedbackState        = qp.query_plan.value('(//*[local-name()="MemoryGrantInfo"]/@IsMemoryGrantFeedbackAdjusted)[1]', 'nvarchar(50)'),
        QueryPlan              = qp.query_plan
FROM    sys.dm_exec_cached_plans   AS cp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle)   AS st
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) AS qp
WHERE   st.objectid IN (OBJECT_ID('Demo.usp_CustomerLinesByPrice'),
                        OBJECT_ID('Demo.usp_CustomerLinesByPrice_Recompile'))
  AND   st.dbid = DB_ID();
GO


PRINT '=== STEP 7: Extended Events session (optional) ===';
GO

/*------------------------------------------------------------------------------
  Proves sort spills and memory grant feedback adjustments without you watching
  actual execution plans go by. Needs ALTER ANY EVENT SESSION at server level;
  if you do not have it, this step fails harmlessly and the demo still runs on
  DMV evidence alone.

  Events are added only if they exist on this build, so this works on 2017
  through 2025 without edits.
------------------------------------------------------------------------------*/
BEGIN TRY
    IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'Demo_ParamSniffing')
        DROP EVENT SESSION Demo_ParamSniffing ON SERVER;

    DECLARE @dbid    nvarchar(10)  = CAST(DB_ID() AS nvarchar(10));
    DECLARE @events  nvarchar(max) = N'';
    DECLARE @evname  sysname;

    DECLARE ev CURSOR LOCAL FAST_FORWARD FOR
        SELECT o.name
        FROM   sys.dm_xe_objects AS o
        JOIN   sys.dm_xe_packages AS p ON p.guid = o.package_guid
        WHERE  o.object_type = 'event'
          AND  p.name = 'sqlserver'
          AND  o.name IN ('sort_warning',
                          'hash_warning',
                          'memory_grant_updated_by_feedback',
                          'memory_grant_feedback_loop_disabled');

    OPEN ev;
    FETCH NEXT FROM ev INTO @evname;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @events += N'ADD EVENT sqlserver.' + QUOTENAME(@evname)
                     + N' (ACTION (sqlserver.database_id, sqlserver.query_hash)'
                     + N'  WHERE (sqlserver.database_id = ' + @dbid + N')), ';
        FETCH NEXT FROM ev INTO @evname;
    END
    CLOSE ev; DEALLOCATE ev;

    IF @events = N''
        RAISERROR('None of the target events exist on this build. Skipping XE session.', 0, 1) WITH NOWAIT;
    ELSE
    BEGIN
        DECLARE @xe nvarchar(max) =
            N'CREATE EVENT SESSION Demo_ParamSniffing ON SERVER '
          + LEFT(@events, LEN(@events) - 1)      -- drop trailing comma
          + N' ADD TARGET package0.ring_buffer (SET max_events_limit = (1000))'
          + N' WITH (MAX_DISPATCH_LATENCY = 5 SECONDS, STARTUP_STATE = OFF);';
        EXEC sys.sp_executesql @xe;
        RAISERROR('Event session Demo_ParamSniffing created (stopped).', 0, 1) WITH NOWAIT;
    END
END TRY
BEGIN CATCH
    -- RAISERROR arguments must be variables or constants, never function calls.
    DECLARE @errmsg nvarchar(2048) = ERROR_MESSAGE();
    RAISERROR('Could not create the XE session: %s', 0, 1, @errmsg) WITH NOWAIT;
    RAISERROR('Not fatal -- 02-demo.sql falls back to DMV evidence.', 0, 1) WITH NOWAIT;
END CATCH
GO

-- Which events actually made it in:
SELECT SessionName = s.name, EventName = e.name
FROM   sys.server_event_sessions AS s
JOIN   sys.server_event_session_events AS e ON e.event_session_id = s.event_session_id
WHERE  s.name = 'Demo_ParamSniffing';
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Before running 02-demo.sql, turn ON:';
PRINT '   SSMS > Query Options > Results > Grid >';
PRINT '          "Discard results after execution"';
PRINT ' The procedure returns 500,000 wide rows several times.';
PRINT ' Without that setting you will be timing the grid, not';
PRINT ' the server, and SSMS may struggle.';
PRINT '';
PRINT ' Then open 02-demo.sql and run the whole file (F5).';
PRINT '========================================================';
GO
