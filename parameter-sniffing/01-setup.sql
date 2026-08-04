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
                N'BATCH_MODE_MEMORY_GRANT_FEEDBACK',
                N'MEMORY_GRANT_FEEDBACK_PERSISTENCE');

-- Scenario F needs Query Store, which is where persisted feedback lives.
INSERT Demo.DemoState (SettingName, SettingValue)
SELECT 'QueryStoreDesiredState', desired_state_desc
FROM   sys.database_query_store_options;

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

-- Scenario C is entirely about row mode memory grant feedback, so assert it
-- rather than hope for it. The original value was recorded in step 1 and
-- 03-cleanup.sql puts it back.
IF EXISTS (SELECT 1 FROM sys.database_scoped_configurations
           WHERE name = N'ROW_MODE_MEMORY_GRANT_FEEDBACK')
BEGIN
    RAISERROR('Enabling ROW_MODE_MEMORY_GRANT_FEEDBACK for scenario C.', 0, 1) WITH NOWAIT;
    ALTER DATABASE SCOPED CONFIGURATION SET ROW_MODE_MEMORY_GRANT_FEEDBACK = ON;
END
ELSE
    RAISERROR('No ROW_MODE_MEMORY_GRANT_FEEDBACK on this build. Scenario C needs 2019+ at compat 150+.', 0, 1) WITH NOWAIT;

/*------------------------------------------------------------------------------
  Persisted feedback is scenario F's subject and nobody else's.

  Left on, it leaks across scenarios: a fresh compile in scenario C arrives
  pre-loaded with a grant that scenario B taught the plan, and C's first row
  shows a 250 MB grant for fifteen rows before C has done anything. That is a
  real 2022+ behaviour, but reading it inside scenario C makes the in-cache
  feedback loop look like it is doing something it is not.

  So: OFF for the whole run. Scenarios A-E show the in-cache loop only, and
  scenario F turns it on for one arm and puts it back.
------------------------------------------------------------------------------*/
IF EXISTS (SELECT 1 FROM sys.database_scoped_configurations
           WHERE name = N'MEMORY_GRANT_FEEDBACK_PERSISTENCE')
BEGIN
    RAISERROR('Disabling MEMORY_GRANT_FEEDBACK_PERSISTENCE. Scenario F owns this one.', 0, 1) WITH NOWAIT;
    ALTER DATABASE SCOPED CONFIGURATION SET MEMORY_GRANT_FEEDBACK_PERSISTENCE = OFF;
END
ELSE
    RAISERROR('No MEMORY_GRANT_FEEDBACK_PERSISTENCE on this build. Scenario F needs 2022+.', 0, 1) WITH NOWAIT;
GO

/*------------------------------------------------------------------------------
  Scenario F watches feedback survive a recompile, and the place it survives in
  is Query Store. Without Query Store in READ_WRITE there is nowhere to persist
  it and the scenario has nothing to show, so turn it on -- recording the
  original desired state first, because this one is not a scoped configuration
  and 03-cleanup.sql restores it separately.

  Note what is NOT done here: no ALTER DATABASE ... SET QUERY_STORE CLEAR. If
  you already had Query Store collecting on this database, wiping it to tidy up
  a demo would be a poor trade. Scenario F is built to work without clearing.
------------------------------------------------------------------------------*/
DECLARE @qs_actual  nvarchar(60) = (SELECT actual_state_desc FROM sys.database_query_store_options);
DECLARE @qs_sql     nvarchar(400);

IF @qs_actual <> N'READ_WRITE'
BEGIN
    SET @qs_sql = N'ALTER DATABASE ' + QUOTENAME(DB_NAME())
                + N' SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);';
    RAISERROR('Query Store is %s. Setting it to READ_WRITE for scenario F.', 0, 1, @qs_actual) WITH NOWAIT;
    EXEC sys.sp_executesql @qs_sql;
END
ELSE
    RAISERROR('Query Store already READ_WRITE. Leaving it alone.', 0, 1) WITH NOWAIT;
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

    A statement-level RECOMPILE does not empty the plan cache. The PROCEDURE's
    compiled plan is cached and reused like any other -- you can see it in
    sys.dm_exec_cached_plans with a rising usecounts -- and sys.dm_exec_query_plan
    returns the plan from the most recent compile of the statement. What does not
    happen is statement plan REUSE: every execution compiles that SELECT again
    against the actual parameter value, which is why the harness shows the plan
    shape and the grant changing from row to row, and why execution_count in
    sys.dm_exec_query_stats stays at 1. Nothing accumulates across executions,
    so memory grant feedback has nothing to learn from.                          */
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
    GrantKB         bigint        NULL,   -- raw last_grant_kb; joins to the XE event
    LogicalReads    bigint        NULL,
    ElapsedMs       bigint        NULL,
    -- Sort spills. There is no DMV that reports "this execution spilled":
    -- last_ideal_grant_kb is derived from the ESTIMATE, so on a sniffed plan it
    -- sits below the granted size even while the sort is spilling to tempdb.
    -- Back-filled from the sort_warning event, matched by time window.
    SpillWarnings   int           NULL,
    -- IsMemoryGrantFeedbackAdjusted. Not available from any DMV -- it exists
    -- only in an ACTUAL execution plan, so it is back-filled from Extended
    -- Events by Demo.usp_BackfillEvidence. See the note on that procedure.
    MGFeedbackState nvarchar(50)  NULL,
    ExecutionCount  bigint        NULL,
    PlanGenNum      bigint        NULL,
    CapturedAt      datetime2(3)  NOT NULL CONSTRAINT DF_DemoResults_CapturedAt DEFAULT SYSDATETIME(),
    -- UTC, because Extended Events timestamps are UTC and the spill back-fill
    -- matches events to rows by time window.
    CapturedUtc     datetime2(3)  NOT NULL CONSTRAINT DF_DemoResults_CapturedUtc DEFAULT SYSUTCDATETIME()
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
            @shape   varchar(300);

    IF @plan IS NULL
        SET @shape = '(no plan retrievable for this plan_handle)';
    ELSE
    BEGIN
        SET @sniffed = @plan.value('(//*[local-name()="ColumnReference"]/@ParameterCompiledValue)[1]', 'nvarchar(128)');
        SET @est     = @plan.value('(//*[local-name()="QueryPlan"]/*[local-name()="RelOp"]/@EstimateRows)[1]', 'float');

        SET @shape = STUFF(
              CASE WHEN @plan.exist('//*[local-name()="RelOp"][@PhysicalOp="Index Seek"]')           = 1 THEN ' + Index Seek'           ELSE '' END
            -- A key lookup is NOT PhysicalOp="Key Lookup" in showplan XML. It is
            -- a Clustered Index Seek carrying Lookup="1", and the graphical plan
            -- relabels it. Testing for the PhysicalOp never matched, so every
            -- seek+lookup plan in this demo reported as a bare "Index Seek".
            + CASE WHEN @plan.exist('//*[local-name()="IndexScan"][@Lookup="1"]')                   = 1 THEN ' + Key Lookup'           ELSE '' END
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
            GrantMB, UsedGrantMB, IdealGrantMB, GrantKB, LogicalReads, ElapsedMs,
            MGFeedbackState, ExecutionCount, PlanGenNum)
    VALUES (@Scenario, @StepNo, @StepDescription, @ObjectName, @ParamUsed, @ParamRole,
            @sniffed, @shape, @est, @rows,
            @grant_kb / 1024.0, @used_kb / 1024.0, @ideal_kb / 1024.0, @grant_kb, @reads, @elapsed,
            '(pending XE back-fill)', @execs, @plangen);
END
GO


/*------------------------------------------------------------------------------
  Back-fills MGFeedbackState. Called once by 02-demo.sql after the last
  execution, never per capture.

  Why this is not just another column read in usp_Capture:

    IsMemoryGrantFeedbackAdjusted does not exist in the cached plan. It is a
    RUNTIME attribute -- it only appears on MemoryGrantInfo in an ACTUAL
    execution plan. sys.dm_exec_query_plan returns the compiled plan and never
    carries it, which is why an earlier version of this harness recorded NULL on
    every single row.

    sys.dm_exec_query_plan_stats (2019+, LAST_QUERY_PLAN_STATS) is not a way out
    either. It returns the last actual plan, but built from lightweight
    profiling, and its MemoryGrantInfo is trimmed to SerialRequiredMemory,
    SerialDesiredMemory, GrantedMemory and MaxUsedMemory. Verified on 2022 with
    feedback demonstrably adjusting on that same plan handle: the attribute is
    absent from that DMV, not NULL-valued.

    So the only in-script source is an actual plan, and the only way to collect
    actual plans without a human watching them go by is the
    query_post_execution_showplan event. That is why MGFeedbackState is the one
    column in this demo that depends on the Extended Events session.

  Matching events back to rows: on (object_id, granted_memory_kb), with ordinal
  position inside that pair as the tiebreaker. The event's granted_memory_kb is
  the same number as sys.dm_exec_query_stats.last_grant_kb, which usp_Capture
  stored raw in GrantKB for exactly this join. Matching on ordinal alone would
  desync the moment anyone runs an extra EXEC by hand -- which scenario D
  explicitly invites.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_BackfillEvidence
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @x xml;

    SELECT @x = CAST(t.target_data AS xml)
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name        = 'Demo_ParamSniffing'
      AND  t.target_name = 'ring_buffer';

    IF @x IS NULL
    BEGIN
        UPDATE Demo.DemoResults
        SET    MGFeedbackState = '(no XE session - state unavailable)'
        WHERE  MGFeedbackState = '(pending XE back-fill)';

        RAISERROR('No XE ring buffer. MGFeedbackState cannot be filled in -- see the README.', 0, 1) WITH NOWAIT;
        RETURN;
    END

    ;WITH ev AS
    (
        SELECT  EventTimeUTC = e.value('@timestamp', 'datetime2(3)'),
                ObjectID     = e.value('(data[@name="object_id"]/value)[1]', 'int'),
                GrantKB      = e.value('(data[@name="granted_memory_kb"]/value)[1]', 'bigint'),
                MGF          = e.value('(data[@name="showplan_xml"]/value//*[local-name()="MemoryGrantInfo"]/@IsMemoryGrantFeedbackAdjusted)[1]', 'nvarchar(50)')
        FROM    @x.nodes('/RingBufferTarget/event') AS n(e)
        WHERE   e.value('@name', 'sysname') = 'query_post_execution_showplan'
    ),
    ranked_ev AS
    (
        SELECT  *,
                rn = ROW_NUMBER() OVER (PARTITION BY ObjectID, GrantKB ORDER BY EventTimeUTC)
        FROM    ev
    ),
    ranked_rows AS
    (
        SELECT  r.MGFeedbackState,
                ObjectID = OBJECT_ID(r.ObjectName),
                r.GrantKB,
                rn = ROW_NUMBER() OVER (PARTITION BY OBJECT_ID(r.ObjectName), r.GrantKB
                                        ORDER BY r.ResultID)
        FROM    Demo.DemoResults AS r
        -- Only rows still awaiting a state. The ring buffer is emptied at the
        -- start of every run, so it holds this run's events and nothing else --
        -- ranking already-filled rows alongside them would shift the ordinals
        -- and hand rows the wrong state.
        WHERE   r.MGFeedbackState = '(pending XE back-fill)'
    )
    UPDATE  rr
    SET     MGFeedbackState = ISNULL(e.MGF, '(no MGF attribute in plan)')
    FROM    ranked_rows AS rr
    JOIN    ranked_ev   AS e
           ON  e.ObjectID = rr.ObjectID
           AND e.GrantKB  = rr.GrantKB
           AND e.rn       = rr.rn;

    -- Anything the ring buffer could not account for says so, rather than
    -- leaving a NULL that reads as "feedback never fired".
    UPDATE Demo.DemoResults
    SET    MGFeedbackState = '(no XE showplan event matched)'
    WHERE  MGFeedbackState = '(pending XE back-fill)';

    /*--------------------------------------------------------------------------
      Spills.

      There is no DMV answer to "did this execution spill". last_ideal_grant_kb
      is computed from the ESTIMATE, so on the sniffed plan this demo is built
      around it reports a fraction of a megabyte while the sort spills half a
      million rows to tempdb -- ideal ends up BELOW granted, and any
      ideal-vs-granted comparison reports no spill precisely when the demo is
      working.

      sort_warning has no object_id to join on, so match by time window: a
      warning belongs to the row whose capture closed the window it landed in.
      usp_Capture runs immediately after each execution, so the window is tight.
      Anything else spilling in this database during the run would land in a
      window too -- acceptable on the scratch instance this demo requires.
    --------------------------------------------------------------------------*/
    ;WITH sw AS
    (
        SELECT  EventTimeUTC = e.value('@timestamp', 'datetime2(3)')
        FROM    @x.nodes('/RingBufferTarget/event') AS n(e)
        WHERE   e.value('@name', 'sysname') = 'sort_warning'
    ),
    windows AS
    (
        SELECT  r.ResultID,
                WindowEnd   = r.CapturedUtc,
                WindowStart = LAG(r.CapturedUtc) OVER (ORDER BY r.ResultID)
        FROM    Demo.DemoResults AS r
    )
    UPDATE  d
    SET     SpillWarnings = (SELECT COUNT(*) FROM sw
                             WHERE sw.EventTimeUTC >  ISNULL(w.WindowStart, '1900-01-01')
                               AND sw.EventTimeUTC <= w.WindowEnd)
    FROM    Demo.DemoResults AS d
    JOIN    windows          AS w ON w.ResultID = d.ResultID;
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
  DMV evidence alone -- EXCEPT for MGFeedbackState, which has no DMV source at
  all. See the note on Demo.usp_BackfillEvidence in step 5.

  query_post_execution_showplan is the expensive one and is deliberately pinned
  to the two demo procedures by object_id rather than to the database. Without
  that predicate it would capture a full showplan XML for every statement
  running in WideWorldImporters, which is not something to leave switched on
  behind a reader's back.

  Which memory grant feedback event fires depends on the build:
    2019+    memory_grant_updated_by_feedback
    2022+    memory_grant_updated_by_percentile_grant  (percentile feedback --
             this is what actually fires on 2022 and up, and the older event
             may stay silent for the whole run)
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
                          'memory_grant_updated_by_percentile_grant',
                          'memory_grant_feedback_persistence_update',
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

    -- The actual plans. This is the only source of MGFeedbackState.
    DECLARE @o1 nvarchar(20) = CAST(OBJECT_ID('Demo.usp_CustomerLinesByPrice')           AS nvarchar(20)),
            @o2 nvarchar(20) = CAST(OBJECT_ID('Demo.usp_CustomerLinesByPrice_Recompile') AS nvarchar(20));

    IF @o1 IS NOT NULL AND @o2 IS NOT NULL
       AND EXISTS (SELECT 1 FROM sys.dm_xe_objects AS o
                   JOIN sys.dm_xe_packages AS p ON p.guid = o.package_guid
                   WHERE o.object_type = 'event' AND p.name = 'sqlserver'
                     AND o.name = 'query_post_execution_showplan')
        SET @events += N'ADD EVENT sqlserver.query_post_execution_showplan'
                     + N' (WHERE (sqlserver.database_id = ' + @dbid
                     + N' AND (object_id = ' + @o1 + N' OR object_id = ' + @o2 + N'))), ';

    IF @events = N''
        RAISERROR('None of the target events exist on this build. Skipping XE session.', 0, 1) WITH NOWAIT;
    ELSE
    BEGIN
        DECLARE @xe nvarchar(max) =
            N'CREATE EVENT SESSION Demo_ParamSniffing ON SERVER '
          + LEFT(@events, LEN(@events) - 1)      -- drop trailing comma
          + N' ADD TARGET package0.ring_buffer (SET max_events_limit = (1000))'
          -- Showplan XML is large. The default 4 MB session buffer is enough for
          -- this demo's two dozen executions, but not by a wide margin.
          + N' WITH (MAX_MEMORY = 16384 KB, MAX_DISPATCH_LATENCY = 5 SECONDS, STARTUP_STATE = OFF);';
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
