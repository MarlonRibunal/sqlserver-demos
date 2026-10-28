/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, PlanCacheDemo. Setup itself changes
     nothing else, but it RECORDS two instance settings, because the DEMO
     CHANGES THEM:

        'show advanced options'            (needed to change the next one)
        'optimize for ad hoc workloads'

     02-demo.sql turns 'optimize for ad hoc workloads' OFF for scenarios A
     and B and ON for scenario C. It affects how every database on the
     instance caches ad hoc plans while the demo runs. The demo puts the
     recorded values back at the end, and so does 03-cleanup.sql. Run this
     on a scratch instance.

     The demo also fills the plan cache with about 5,000 plans of its own
     (roughly 100 MB), and removes exactly those plans at the end, one plan
     handle at a time. It never clears the whole plan cache.

  Creates, all inside PlanCacheDemo:
     Demo.Customers        - 10,000 rows
     Demo.Orders           - 100,000 rows
     Demo.OriginalConfig   - the two settings, as found at setup
     Demo.usp_SetAdHoc     - turn 'optimize for ad hoc workloads' on or off
     Demo.usp_RestoreConfig- put the recorded values back
     Demo.usp_Send         - send one query 1,000 times, a different value
                             each time, as ad hoc text or as a parameter
     Demo.usp_Cache        - what the plan cache holds for one query
     Demo.usp_Evict        - remove one query's plans from the cache
     Demo.Results          - one row per measurement
     Demo.Verdicts         - one row per claim

  TESTED end to end on SQL Server 2025 RTM-CU10 (17.0.5035.5) and 2022
  RTM-CU25 (16.0.4255.1), Linux containers.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create PlanCacheDemo ===';
GO

IF DB_ID('PlanCacheDemo') IS NOT NULL
BEGIN
    RAISERROR('PlanCacheDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE PlanCacheDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE PlanCacheDemo;
END
GO

CREATE DATABASE PlanCacheDemo;
GO

ALTER DATABASE PlanCacheDemo SET RECOVERY SIMPLE;
GO

USE PlanCacheDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: the tables ===';
GO

CREATE TABLE Demo.Customers
(
    CustomerID  int      NOT NULL CONSTRAINT PK_Customers PRIMARY KEY CLUSTERED,
    Region      tinyint  NOT NULL
);

CREATE TABLE Demo.Orders
(
    OrderID     int  NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    CustomerID  int  NOT NULL,
    Amount      int  NOT NULL
);
GO

;WITH n AS
(
    SELECT TOP (100000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.Customers (CustomerID, Region)
SELECT rn, rn % 10 FROM n WHERE rn <= 10000;

;WITH n AS
(
    SELECT TOP (100000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.Orders (OrderID, CustomerID, Amount)
SELECT rn, (rn % 10000) + 1, rn % 100 FROM n;

CREATE INDEX IX_Orders_CustomerID ON Demo.Orders (CustomerID) INCLUDE (Amount);
GO


PRINT '=== STEP 3: record the instance settings the demo changes ===';
GO

CREATE TABLE Demo.OriginalConfig
(
    Name         nvarchar(70)  NOT NULL PRIMARY KEY,
    ValueInUse   int           NOT NULL,
    RecordedAt   datetime2(0)  NOT NULL DEFAULT (SYSDATETIME())
);

INSERT Demo.OriginalConfig (Name, ValueInUse)
SELECT name, CAST(value_in_use AS int)
FROM   sys.configurations
WHERE  name IN (N'show advanced options', N'optimize for ad hoc workloads');

SELECT Name, ValueInUse AS RecordedValue FROM Demo.OriginalConfig;
GO


PRINT '=== STEP 4: the harness ===';
GO

CREATE TABLE Demo.Results
(
    Scenario  char(1)        NOT NULL,
    Item      varchar(160)   NOT NULL,
    Value     varchar(400)   NULL,
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

-- Turn 'optimize for ad hoc workloads' on (1) or off (0), instance-wide.
CREATE OR ALTER PROCEDURE Demo.usp_SetAdHoc
    @On bit
AS
BEGIN
    SET NOCOUNT ON;
    EXEC master.sys.sp_executesql N'
        EXEC sys.sp_configure N''show advanced options'', 1;
        RECONFIGURE;
        EXEC sys.sp_configure N''optimize for ad hoc workloads'', @On;
        RECONFIGURE;', N'@On bit', @On = @On;
END
GO

-- Put back the values recorded at setup: the ad hoc setting first, while
-- advanced options are still shown, then 'show advanced options' itself.
CREATE OR ALTER PROCEDURE Demo.usp_RestoreConfig
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @adhoc int = (SELECT ValueInUse FROM Demo.OriginalConfig WHERE Name = N'optimize for ad hoc workloads'),
            @adv   int = (SELECT ValueInUse FROM Demo.OriginalConfig WHERE Name = N'show advanced options');
    IF @adhoc IS NULL OR @adv IS NULL
    BEGIN
        RAISERROR('Demo.OriginalConfig is incomplete; nothing restored.', 16, 1);
        RETURN;
    END
    EXEC master.sys.sp_executesql N'
        EXEC sys.sp_configure N''show advanced options'', 1;
        RECONFIGURE;
        EXEC sys.sp_configure N''optimize for ad hoc workloads'', @adhoc;
        RECONFIGURE;
        EXEC sys.sp_configure N''show advanced options'', @adv;
        RECONFIGURE;', N'@adhoc int, @adv int', @adhoc = @adhoc, @adv = @adv;
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_Send -- send one query @Count times, for customers 1 to @Count.

    @Shape  'join'    SELECT SUM(o.Amount) AS <marker> FROM Demo.Orders AS o
                      JOIN Demo.Customers AS c ... WHERE o.CustomerID = <n>
            'simple'  SELECT SUM(Amount) AS <marker> FROM Demo.Orders
                      WHERE CustomerID = <n>
    @Param  0: the value written into the text, run with EXEC (): ad hoc SQL,
               the way an application that concatenates strings sends it
            1: the value as an sp_executesql parameter

  @Marker is the column alias; Demo.usp_Cache finds the query's plans by it.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Send
    @Marker  sysname,
    @Shape   varchar(10),
    @Param   bit,
    @Count   int = 1000
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @i int = 1, @t nvarchar(400), @sql nvarchar(400), @v bigint;
    SET @t = CASE @Shape
                 WHEN 'join'   THEN N'SELECT SUM(o.Amount) AS ' + @Marker + N' FROM Demo.Orders AS o JOIN Demo.Customers AS c ON c.CustomerID = o.CustomerID WHERE o.CustomerID = '
                 WHEN 'simple' THEN N'SELECT SUM(Amount) AS ' + @Marker + N' FROM Demo.Orders WHERE CustomerID = '
             END;
    CREATE TABLE #sink (v bigint);
    WHILE @i <= @Count
    BEGIN
        IF @Param = 0
        BEGIN
            SET @sql = @t + CAST(@i AS nvarchar(10)) + N';';
            INSERT #sink EXEC (@sql);
        END
        ELSE
        BEGIN
            SET @sql = @t + N'@c;';
            INSERT #sink EXEC sys.sp_executesql @sql, N'@c int', @c = @i;
        END
        SET @i += 1;
    END
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_Cache -- what the plan cache holds for one query (by its marker):
  full ad hoc plans, ad hoc stubs, prepared (parameterized) plans, their
  total size, how often the prepared plan was used, and how many distinct
  query_hash values the full ad hoc plans have.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Cache
    @Marker     sysname,
    @Adhoc      int     OUTPUT,
    @Stubs      int     OUTPUT,
    @Prepared   int     OUTPUT,
    @KB         bigint  OUTPUT,
    @PrepUses   bigint  OUTPUT,
    @Hashes     int     OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    -- The text as sent has 'AS <marker> FROM'; a plan SQL Server parameterized
    -- itself has '[<marker>] FROM'.
    DECLARE @pattern  nvarchar(200) = N'%AS ' + @Marker + N' FROM%',
            @pattern2 nvarchar(200) = N'%[[]' + @Marker + N'] FROM%';

    SELECT @Adhoc    = COUNT(CASE WHEN cp.objtype = 'Adhoc' AND cp.cacheobjtype = 'Compiled Plan' THEN 1 END),
           @Stubs    = COUNT(CASE WHEN cp.objtype = 'Adhoc' AND cp.cacheobjtype = 'Compiled Plan Stub' THEN 1 END),
           @Prepared = COUNT(CASE WHEN cp.objtype = 'Prepared' THEN 1 END),
           @KB       = ISNULL(SUM(CAST(cp.size_in_bytes AS bigint)), 0) / 1024,
           @PrepUses = ISNULL(SUM(CASE WHEN cp.objtype = 'Prepared' THEN cp.usecounts END), 0)
    FROM   sys.dm_exec_cached_plans AS cp
    CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS st
    WHERE  cp.objtype IN ('Adhoc', 'Prepared')
      AND  (st.text LIKE @pattern OR st.text LIKE @pattern2);

    SELECT @Hashes = COUNT(DISTINCT qs.query_hash)
    FROM   sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
    WHERE  st.text LIKE @pattern OR st.text LIKE @pattern2;
END
GO

-- Remove one query's plans from the cache, plan handle by plan handle.
CREATE OR ALTER PROCEDURE Demo.usp_Evict
    @Marker sysname
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @pattern  nvarchar(200) = N'%AS ' + @Marker + N' FROM%',
            @pattern2 nvarchar(200) = N'%[[]' + @Marker + N'] FROM%',
            @h varbinary(64);
    DECLARE p CURSOR LOCAL FAST_FORWARD FOR
        SELECT cp.plan_handle
        FROM   sys.dm_exec_cached_plans AS cp
        CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS st
        WHERE  cp.objtype IN ('Adhoc', 'Prepared')
          AND  (st.text LIKE @pattern OR st.text LIKE @pattern2);
    OPEN p;
    FETCH NEXT FROM p INTO @h;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DBCC FREEPROCCACHE (@h) WITH NO_INFOMSGS;
        FETCH NEXT FROM p INTO @h;
    END
    CLOSE p; DEALLOCATE p;
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Created PlanCacheDemo, and recorded the two instance';
PRINT ' settings 02-demo.sql will change. Nothing was changed yet.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
