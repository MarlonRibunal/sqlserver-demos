/*==============================================================================
  01-setup.sql          RUN ONCE. Takes about 20 seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, IqpDemo, and puts everything inside it.
     Nothing else on the instance is modified. Inside IqpDemo it sets:

        - COMPATIBILITY_LEVEL = 160 (the demo moves it to 150 and back, to
          compare). Pinned, so 2025 (default 170) behaves like 2022.
        - QUERY_STORE = ON, READ_WRITE, capture mode ALL: the 2022 features
          keep what they learn there

     No instance setting, no trace flag, no other database.

  ON SQL SERVER 2019 AND EARLIER the database is created at its highest
  level, and the demo reports every scenario as SKIPPED: these features
  arrived in 2022.

  Creates, all inside IqpDemo:
     Demo.Orders          - 1,000,000 orders: customer 1 has half of them,
                            every other customer has one; Region and Area
                            are correlated (an Area is in one Region)
     Demo.q_*             - the measured queries, one procedure each
     Demo.usp_*           - the scenarios and the measuring harness
     Demo.Results         - one row per measurement
     Demo.Verdicts        - one row per claim

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create IqpDemo ===';
GO

IF DB_ID('IqpDemo') IS NOT NULL
BEGIN
    RAISERROR('IqpDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE IqpDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE IqpDemo;
END
GO

CREATE DATABASE IqpDemo;
GO

ALTER DATABASE IqpDemo SET RECOVERY SIMPLE;
ALTER DATABASE IqpDemo SET QUERY_STORE = ON;
ALTER DATABASE IqpDemo SET QUERY_STORE (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL);
GO

-- 160 only exists from 2022. Dynamic, so 2019 doesn't reject the batch.
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16
    EXEC (N'ALTER DATABASE IqpDemo SET COMPATIBILITY_LEVEL = 160;');
GO

USE IqpDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: Demo.Orders ===';
GO

CREATE TABLE Demo.Orders
(
    OrderID    int            NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    CustomerID int            NOT NULL,
    Region     int            NOT NULL,
    Area       int            NOT NULL,
    OrderDate  date           NOT NULL,
    Amount     decimal(12,2)  NOT NULL,
    pad        char(100)      NOT NULL CONSTRAINT DF_Orders_pad DEFAULT ('x')
);
;WITH n AS
(
    SELECT TOP (1000000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b CROSS JOIN sys.all_columns AS c
)
INSERT Demo.Orders WITH (TABLOCK) (OrderID, CustomerID, Region, Area, OrderDate, Amount)
SELECT rn,
       CASE WHEN rn <= 500000 THEN 1 ELSE rn END,     -- customer 1: 500,000 orders; the rest: 1 each
       (rn % 200) / 10,                                -- 20 regions
       rn % 200,                                       -- 200 areas, 10 per region
       DATEADD(day, rn % 1500, '20200101'),
       rn % 1000 + 0.50
FROM   n;

CREATE INDEX IX_Orders_Customer ON Demo.Orders (CustomerID);
CREATE INDEX IX_Orders_Region   ON Demo.Orders (Region);
CREATE INDEX IX_Orders_Area     ON Demo.Orders (Area);
UPDATE STATISTICS Demo.Orders WITH FULLSCAN;
GO


PRINT '=== STEP 3: the measured queries ===';
GO

-- A. One customer's orders. Customer 1 has 500,000; the others have 1.
CREATE OR ALTER PROCEDURE Demo.q_ByCustomer @CustomerID int AS
    SELECT SUM(Amount) AS Total, MAX(OrderDate) AS Latest, MAX(pad) AS p
    FROM   Demo.Orders
    WHERE  CustomerID = @CustomerID;
GO

-- B. Two correlated filters: Area 75 is in Region 7, so every Area 75 row
-- matches both. The estimator assumes they are partly independent.
CREATE OR ALTER PROCEDURE Demo.q_RegionArea AS
    SELECT SUM(Amount) AS Total, MAX(OrderDate) AS Latest, MAX(pad) AS p
    FROM   Demo.Orders
    WHERE  Region = 7 AND Area = 75;
GO

-- C. A sort compiled for customer 1 (500,000 rows) and run for customer
-- 600042 (1 row): its memory grant is sized for half a million rows. The
-- window function sorts every row it gets.
CREATE OR ALTER PROCEDURE Demo.q_Grant @CustomerID int AS
    SELECT COUNT(*) AS Days, SUM(Amount) AS Total, MAX(pad) AS p
    FROM  (SELECT Amount, pad, rn = ROW_NUMBER() OVER (PARTITION BY OrderDate ORDER BY pad, Amount DESC)
           FROM   Demo.Orders
           WHERE  CustomerID = @CustomerID) AS x
    WHERE  rn = 1
    OPTION (OPTIMIZE FOR (@CustomerID = 1));
GO


PRINT '=== STEP 4: the harness ===';
GO

CREATE TABLE Demo.Results
(
    Scenario  char(1)        NOT NULL,
    Label     varchar(100)   NOT NULL,
    Reads     bigint         NULL,
    GrantKB   bigint         NULL,
    Note      varchar(300)   NULL,
    Seq       int            IDENTITY(1,1) NOT NULL
);
GO

CREATE TABLE Demo.Verdicts
(
    Scenario  char(1)        NOT NULL,
    Claim     varchar(200)   NOT NULL,
    Evidence  varchar(400)   NULL,
    Verdict   varchar(30)    NOT NULL,
    Seq       int            IDENTITY(1,1) NOT NULL
);
GO

/*------------------------------------------------------------------------------
  Demo.usp_Exec -- run Demo.@Proc once (with @Arg, if given), discarding its
  rows, and return its logical reads (sys.dm_exec_requests) and its memory
  grant (sys.dm_exec_query_stats, last_grant_kb).
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Exec
    @Proc    sysname,
    @Arg     int     = NULL,
    @Reads   bigint  = NULL OUTPUT,
    @GrantKB bigint  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @full nvarchar(300) = N'Demo.' + @Proc, @r0 bigint, @r1 bigint;
    CREATE TABLE #sink (a decimal(18,2) NULL, b sql_variant NULL, c sql_variant NULL);

    SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    IF @Arg IS NULL INSERT #sink EXEC @full;
    ELSE            INSERT #sink EXEC @full @Arg;
    SELECT @r1 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;

    SET @Reads = @r1 - @r0;
    SELECT TOP (1) @GrantKB = qs.last_grant_kb
    FROM   sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
    WHERE  t.dbid = DB_ID() AND t.objectid = OBJECT_ID(@full)
    ORDER BY qs.last_execution_time DESC;
END
GO

-- The plan cache, for this database only.
CREATE OR ALTER PROCEDURE Demo.usp_ClearCache
AS
    ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
GO


PRINT '=== STEP 5: the scenarios (2022 and later) ===';
GO

/*------------------------------------------------------------------------------
  Everything below reads Query Store views and settings that only exist
  from 2022, so it runs as dynamic SQL: on 2019 these procedures can be
  created, and are never called.
------------------------------------------------------------------------------*/

/*------------------------------------------------------------------------------
  Demo.usp_A_Run -- parameter-sensitive plan optimization. With an empty
  plan cache, run customer 600042 (1 order) and then customer 1 (500,000).
  The demo calls it at compatibility level 150, where the second run reuses
  the first's plan, and at 160. (The level is changed by the demo, in a
  batch of its own: changed inside this procedure, it did not apply to the
  compilations that followed it.)
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_A_Run
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @reads bigint, @label varchar(100),
            @lvl varchar(3) = (SELECT CAST(compatibility_level AS varchar(3)) FROM sys.databases WHERE database_id = DB_ID());
    EXEC Demo.usp_ClearCache;

    EXEC Demo.usp_Exec 'q_ByCustomer', 600042, @Reads = @reads OUTPUT;
    SET @label = 'compat ' + @lvl + ': customer 600042 (1 order), first';
    INSERT Demo.Results (Scenario, Label, Reads) VALUES ('A', @label, @reads);

    EXEC Demo.usp_Exec 'q_ByCustomer', 1, @Reads = @reads OUTPUT;
    SET @label = 'compat ' + @lvl + ': customer 1 (500,000 orders), next';
    INSERT Demo.Results (Scenario, Label, Reads) VALUES ('A', @label, @reads);
END
GO

-- The variants Query Store recorded for q_ByCustomer's statement.
CREATE OR ALTER PROCEDURE Demo.usp_A_Variants
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @variants int, @dispatcher int;
    EXEC sys.sp_executesql N'
        SELECT @v = COUNT(*), @d = COUNT(DISTINCT v.dispatcher_plan_id)
        FROM   sys.query_store_query_variant AS v
        JOIN   sys.query_store_query AS q ON q.query_id = v.parent_query_id
        WHERE  q.object_id = OBJECT_ID(N''Demo.q_ByCustomer'');',
        N'@v int OUTPUT, @d int OUTPUT', @v = @variants OUTPUT, @d = @dispatcher OUTPUT;
    INSERT Demo.Results (Scenario, Label, Note)
    VALUES ('A', 'Query Store: variants of the statement',
            CAST(@variants AS varchar(10)) + ' variant queries under ' + CAST(@dispatcher AS varchar(10)) + ' dispatcher plan(s)');
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_B -- CE feedback. Run q_RegionArea until Query Store records CE
  feedback for it (at most @Max times), then report the feedback, the hint
  it attached, and the reads before and after.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_B
    @Max int = 60
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @i int = 0, @reads bigint, @first bigint, @state nvarchar(60), @data nvarchar(400), @hint nvarchar(400), @runs int;
    EXEC Demo.usp_ClearCache;
    EXEC Demo.usp_Exec 'q_RegionArea', @Reads = @first OUTPUT;
    INSERT Demo.Results (Scenario, Label, Reads) VALUES ('B', 'first execution', @first);

    WHILE @i < @Max AND @hint IS NULL
    BEGIN
        EXEC Demo.usp_Exec 'q_RegionArea', @Reads = @reads OUTPUT;
        SET @i += 1;
        EXEC sys.sp_executesql N'
            SELECT TOP (1) @h = h.query_hint_text
            FROM   sys.query_store_query_hints AS h
            JOIN   sys.query_store_query AS q ON q.query_id = h.query_id
            WHERE  q.object_id = OBJECT_ID(N''Demo.q_RegionArea'') AND h.source_desc = N''CE feedback'';',
            N'@h nvarchar(400) OUTPUT', @h = @hint OUTPUT;
    END
    SET @runs = @i + 1;

    EXEC sys.sp_executesql N'
        SELECT TOP (1) @s = f.state_desc, @d = f.feedback_data
        FROM   sys.query_store_plan_feedback AS f
        JOIN   sys.query_store_plan AS p ON p.plan_id = f.plan_id
        JOIN   sys.query_store_query AS q ON q.query_id = p.query_id
        WHERE  q.object_id = OBJECT_ID(N''Demo.q_RegionArea'') AND f.feature_desc = N''CE Feedback''
        ORDER BY f.last_updated_time DESC;',
        N'@s nvarchar(60) OUTPUT, @d nvarchar(400) OUTPUT', @s = @state OUTPUT, @d = @data OUTPUT;

    -- A few more runs, with whatever the feedback left in place.
    SET @i = 0;
    WHILE @i < 3
    BEGIN
        EXEC Demo.usp_Exec 'q_RegionArea', @Reads = @reads OUTPUT;
        SET @i += 1;
    END

    INSERT Demo.Results (Scenario, Label, Reads, Note) VALUES
        ('B', 'after ' + CAST(@runs AS varchar(10)) + ' executions: Query Store hint', NULL, ISNULL(@hint, 'none')),
        ('B', 'CE feedback in sys.query_store_plan_feedback', NULL, ISNULL(@state, 'none') + ISNULL(': ' + @data, '')),
        ('B', 'execution after the feedback', @reads, NULL);
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_C_Run -- memory grant feedback, kept in Query Store. q_Grant is
  compiled for customer 1 (500,000 rows to sort) and run for customer
  600042 (1 row), so its first grant is far too big. With an empty Query
  Store and plan cache, run it 5 times; clear this database's plan cache;
  run it once more. The demo calls it with
  MEMORY_GRANT_FEEDBACK_PERSISTENCE ON, then OFF (set in a batch of its
  own).
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_C_Run
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @i int = 1, @grant bigint, @label varchar(100), @onoff varchar(3);
    EXEC sys.sp_executesql N'
        SELECT @o = CASE CAST(value AS int) WHEN 1 THEN ''ON'' ELSE ''OFF'' END
        FROM   sys.database_scoped_configurations WHERE name = N''MEMORY_GRANT_FEEDBACK_PERSISTENCE'';',
        N'@o varchar(3) OUTPUT', @o = @onoff OUTPUT;

    EXEC (N'ALTER DATABASE CURRENT SET QUERY_STORE CLEAR;');
    EXEC Demo.usp_ClearCache;

    WHILE @i <= 5
    BEGIN
        EXEC Demo.usp_Exec 'q_Grant', 600042, @GrantKB = @grant OUTPUT;
        IF @i IN (1, 2, 5)
        BEGIN
            SET @label = 'persistence ' + @onoff + ': execution ' + CAST(@i AS varchar(2));
            INSERT Demo.Results (Scenario, Label, GrantKB) VALUES ('C', @label, @grant);
        END
        SET @i += 1;
    END

    EXEC Demo.usp_ClearCache;
    EXEC Demo.usp_Exec 'q_Grant', 600042, @GrantKB = @grant OUTPUT;
    SET @label = 'persistence ' + @onoff + ': first execution after the plan cache is cleared';
    INSERT Demo.Results (Scenario, Label, GrantKB) VALUES ('C', @label, @grant);
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_Reset -- start clean: an empty Query Store (with no hints left
  over from an earlier run) and an empty plan cache for this database. The
  demo sets compatibility level 160 and the default settings before it.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Reset
    @Leftovers int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC (N'ALTER DATABASE CURRENT SET QUERY_STORE CLEAR;');
    EXEC Demo.usp_ClearCache;
    EXEC sys.sp_executesql N'
        SELECT @n = (SELECT COUNT(*) FROM sys.query_store_query_hints)
                  + (SELECT COUNT(*) FROM sys.query_store_plan_feedback)
                  + (SELECT COUNT(*) FROM sys.query_store_query_variant);',
        N'@n int OUTPUT', @n = @Leftovers OUTPUT;
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the IqpDemo database.';
PRINT ' No instance setting was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
