/*==============================================================================
  01-setup.sql          RUN ONCE. Takes about 20 seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, OppoDemo, and puts everything inside it.
     Nothing else on the instance is modified. Inside OppoDemo it sets
     QUERY_STORE = ON (capture mode ALL): the plan variants are recorded
     there. The demo moves the compatibility level between 160 and 170 and
     turns the OPTIONAL_PARAMETER_OPTIMIZATION setting off and on, and says
     so at the top of 02-demo.sql.

  ON SQL SERVER 2022 AND EARLIER the database is created, and the demo
  reports every scenario as SKIPPED: optional parameter plan optimization
  arrived in 2025.

  Creates, all inside OppoDemo:
     Demo.Orders       - 1,000,000 orders, 50,000 customers (20 orders
                         each), 2,000 order dates (500 each); an index on
                         each of CustomerID and OrderDate
     Demo.s_*          - the searches: the same optional-parameter search
                         written six ways
     Demo.usp_Run      - run one search, record its logical reads
     Demo.Results      - one row per call
     Demo.Verdicts     - one row per claim

  TESTED end to end on SQL Server 2025 RTM-CU8 (17.0.4075.5), Linux
  container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create OppoDemo ===';
GO

IF DB_ID('OppoDemo') IS NOT NULL
BEGIN
    RAISERROR('OppoDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE OppoDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE OppoDemo;
END
GO

CREATE DATABASE OppoDemo;
GO

ALTER DATABASE OppoDemo SET RECOVERY SIMPLE;
ALTER DATABASE OppoDemo SET QUERY_STORE = ON;
ALTER DATABASE OppoDemo SET QUERY_STORE (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL);
GO

USE OppoDemo;
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
    OrderDate  date           NOT NULL,
    Amount     decimal(12,2)  NOT NULL,
    pad        char(100)      NOT NULL CONSTRAINT DF_Orders_pad DEFAULT ('x')
);
;WITH n AS
(
    SELECT TOP (1000000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b CROSS JOIN sys.all_columns AS c
)
INSERT Demo.Orders WITH (TABLOCK) (OrderID, CustomerID, OrderDate, Amount)
SELECT rn, rn % 50000 + 1, DATEADD(day, rn % 2000, '20200101'), rn % 1000 + 0.50
FROM   n;

CREATE INDEX IX_Orders_Customer ON Demo.Orders (CustomerID);
CREATE INDEX IX_Orders_Date     ON Demo.Orders (OrderDate);
GO


PRINT '=== STEP 3: the searches ===';
GO

-- A. The catch-all, one optional parameter.
CREATE OR ALTER PROCEDURE Demo.s_Or @CustomerID int AS
    SELECT COUNT(*) AS n, SUM(Amount) AS s, MAX(pad) AS p
    FROM   Demo.Orders
    WHERE  (@CustomerID IS NULL OR CustomerID = @CustomerID);
GO

-- B. Two optional parameters.
CREATE OR ALTER PROCEDURE Demo.s_Or2 @CustomerID int, @OrderDate date AS
    SELECT COUNT(*) AS n, SUM(Amount) AS s, MAX(pad) AS p
    FROM   Demo.Orders
    WHERE  (@CustomerID IS NULL OR CustomerID = @CustomerID)
      AND  (@OrderDate  IS NULL OR OrderDate  = @OrderDate);
GO

-- C. The same search as A, written with COALESCE and with ISNULL.
CREATE OR ALTER PROCEDURE Demo.s_Coalesce @CustomerID int AS
    SELECT COUNT(*) AS n, SUM(Amount) AS s, MAX(pad) AS p
    FROM   Demo.Orders
    WHERE  CustomerID = COALESCE(@CustomerID, CustomerID);
GO
CREATE OR ALTER PROCEDURE Demo.s_IsNull @CustomerID int AS
    SELECT COUNT(*) AS n, SUM(Amount) AS s, MAX(pad) AS p
    FROM   Demo.Orders
    WHERE  CustomerID = ISNULL(@CustomerID, CustomerID);
GO

-- D. A, with the parameter tidied first ("0 means all customers"). Does
-- OPPO still recognise the pattern when the parameter has been changed?
CREATE OR ALTER PROCEDURE Demo.s_OrModified @CustomerID int AS
    SET @CustomerID = NULLIF(@CustomerID, 0);
    SELECT COUNT(*) AS n, SUM(Amount) AS s, MAX(pad) AS p
    FROM   Demo.Orders
    WHERE  (@CustomerID IS NULL OR CustomerID = @CustomerID);
GO

-- D. A, with the parameter copied into a local variable (an old habit
-- against parameter sniffing).
CREATE OR ALTER PROCEDURE Demo.s_OrLocal @CustomerID int AS
    DECLARE @c int = @CustomerID;
    SELECT COUNT(*) AS n, SUM(Amount) AS s, MAX(pad) AS p
    FROM   Demo.Orders
    WHERE  (@c IS NULL OR CustomerID = @c);
GO


PRINT '=== STEP 4: the harness ===';
GO

CREATE TABLE Demo.Results
(
    Scenario  char(1)        NOT NULL,
    Config    varchar(40)    NOT NULL,
    Search    sysname        NOT NULL,
    Args      varchar(400)   NOT NULL,
    Reads     bigint         NULL,
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
  Demo.usp_Run -- run Demo.@Search once with @CustomerID (and @OrderDate, for
  s_Or2), discard its row, and record its logical reads. The configuration
  label says what the compatibility level and settings were.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Run
    @Scenario   char(1),
    @Search     sysname,
    @CustomerID int  = NULL,
    @OrderDate  date = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r0 bigint, @r1 bigint, @full nvarchar(300) = N'Demo.' + @Search,
            @config varchar(40) =
                'compat ' + (SELECT CAST(compatibility_level AS varchar(3)) FROM sys.databases WHERE database_id = DB_ID())
              + CASE WHEN EXISTS (SELECT 1 FROM sys.database_scoped_configurations
                                  WHERE name = N'OPTIONAL_PARAMETER_OPTIMIZATION' AND CAST(value AS nvarchar(20)) = N'0')
                     THEN ', OPPO setting OFF' ELSE '' END;
    CREATE TABLE #sink (n int, s decimal(18,2), p char(100));

    SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    IF @Search = N's_Or2' INSERT #sink EXEC Demo.s_Or2 @CustomerID, @OrderDate;
    ELSE                  INSERT #sink EXEC @full @CustomerID;
    SELECT @r1 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;

    INSERT Demo.Results (Scenario, Config, Search, Args, Reads)
    VALUES (@Scenario, @config, @Search,
            'customer ' + ISNULL(CAST(@CustomerID AS varchar(10)), 'NULL')
            + CASE WHEN @Search = N's_Or2' THEN ', date ' + ISNULL(CONVERT(varchar(10), @OrderDate, 23), 'NULL') ELSE '' END,
            @r1 - @r0);
END
GO

-- Run the scenarios' calls, in order, with an empty plan cache for this
-- database first. The demo calls it once per configuration.
CREATE OR ALTER PROCEDURE Demo.usp_RunAll
AS
BEGIN
    SET NOCOUNT ON;
    ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;

    -- A: one customer first (that compiles the plan), then all customers.
    EXEC Demo.usp_Run 'A', 's_Or', 123;
    EXEC Demo.usp_Run 'A', 's_Or', NULL;

    -- B: customer only, date only, then neither.
    EXEC Demo.usp_Run 'B', 's_Or2', 123, NULL;
    EXEC Demo.usp_Run 'B', 's_Or2', NULL, '20230101';
    EXEC Demo.usp_Run 'B', 's_Or2', NULL, NULL;

    -- C
    EXEC Demo.usp_Run 'C', 's_Coalesce', 123;
    EXEC Demo.usp_Run 'C', 's_Coalesce', NULL;
    EXEC Demo.usp_Run 'C', 's_IsNull', 123;
    EXEC Demo.usp_Run 'C', 's_IsNull', NULL;

    -- D
    EXEC Demo.usp_Run 'D', 's_OrModified', 123;
    EXEC Demo.usp_Run 'D', 's_OrModified', NULL;
    EXEC Demo.usp_Run 'D', 's_OrLocal', 123;
    EXEC Demo.usp_Run 'D', 's_OrLocal', NULL;
END
GO

-- The plan variants Query Store recorded, per search. Dynamic: the view
-- exists from 2022.
CREATE OR ALTER PROCEDURE Demo.usp_Variants
    @Result varchar(400) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sys.sp_executesql N'
        SELECT @r = STRING_AGG(CAST(s.name + '': '' + CAST(ISNULL(v.n, 0) AS varchar(10)) AS varchar(400)), '', '')
                    WITHIN GROUP (ORDER BY s.name)
        FROM   sys.procedures AS s
        LEFT JOIN (SELECT q.object_id, n = COUNT(*)
                   FROM   sys.query_store_query_variant AS qv
                   JOIN   sys.query_store_query AS q ON q.query_id = qv.parent_query_id
                   GROUP BY q.object_id) AS v ON v.object_id = s.object_id
        WHERE  s.schema_id = SCHEMA_ID(N''Demo'') AND s.name LIKE N''s[_]%'';',
        N'@r varchar(400) OUTPUT', @r = @Result OUTPUT;
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the OppoDemo database.';
PRINT ' No instance setting was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
