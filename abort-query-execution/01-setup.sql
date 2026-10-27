/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, AbortDemo, and puts everything inside it.
     Nothing else on the instance is modified. Inside AbortDemo it turns
     on Query Store (capture mode ALL): the hint is stored there.

  ON SQL SERVER 2022 AND EARLIER the database is created, and the demo
  reports every scenario as SKIPPED: the ABORT_QUERY_EXECUTION hint arrived
  in 2025.

  Creates, all inside AbortDemo:
     Demo.Items          - 2,000 rows
     Demo.p_Runaway      - the query to block: a cross join that counts
                           4,000,000 combinations. Cheap enough here; in
                           real life, the report that takes the server
                           down at 9 a.m.
     Demo.p_Other        - an unrelated query in another procedure
     Demo.usp_Try        - run one statement, return the error it raised
     Demo.usp_QueryID    - the Query Store query_id of the runaway query
     Demo.Results        - one row per attempt
     Demo.Verdicts       - one row per claim

  TESTED end to end on SQL Server 2025 RTM-CU9-GDR (17.0.5015.4), Linux
  container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create AbortDemo ===';
GO

IF DB_ID('AbortDemo') IS NOT NULL
BEGIN
    RAISERROR('AbortDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE AbortDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE AbortDemo;
END
GO

CREATE DATABASE AbortDemo;
GO

ALTER DATABASE AbortDemo SET RECOVERY SIMPLE;
ALTER DATABASE AbortDemo SET QUERY_STORE = ON;
ALTER DATABASE AbortDemo SET QUERY_STORE (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL);
GO

USE AbortDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: the table and the queries ===';
GO

CREATE TABLE Demo.Items
(
    ItemID  int  NOT NULL CONSTRAINT PK_Items PRIMARY KEY CLUSTERED,
    Qty     int  NOT NULL
);

INSERT Demo.Items (ItemID, Qty)
SELECT TOP (2000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 1
FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b;
GO

CREATE OR ALTER PROCEDURE Demo.p_Runaway
AS
    SELECT COUNT_BIG(*) AS Combinations
    FROM   Demo.Items AS a CROSS JOIN Demo.Items AS b;
GO

CREATE OR ALTER PROCEDURE Demo.p_Other
AS
    SELECT SUM(Qty) AS Total FROM Demo.Items;
GO


PRINT '=== STEP 3: the harness ===';
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

/*------------------------------------------------------------------------------
  Demo.usp_Try -- run one statement, discard its result, and return the
  error number it raised, or 0. The error is caught, so the demo's output
  carries no error message.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Try
    @sql    nvarchar(max),
    @Error  int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Error = 0;
    CREATE TABLE #sink (n bigint);
    BEGIN TRY
        INSERT #sink EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        SET @Error = ERROR_NUMBER();
    END CATCH
END
GO

-- The query_id Query Store gave the runaway query inside Demo.p_Runaway.
CREATE OR ALTER PROCEDURE Demo.usp_QueryID
    @QueryID bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (1) @QueryID = q.query_id
    FROM   sys.query_store_query AS q
    WHERE  q.object_id = OBJECT_ID(N'Demo.p_Runaway')
    ORDER BY q.query_id;
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the AbortDemo database.';
PRINT ' No instance setting was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
