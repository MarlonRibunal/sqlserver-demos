/*==============================================================================
  01-setup.sql          RUN ONCE. Takes about 30 seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, JsonDemo, and puts everything inside it.
     Nothing else on the instance is modified.

  ON SQL SERVER 2022 AND EARLIER the database and the harness are created,
  but none of the tables: the json data type arrived in 2025. The demo
  reports every scenario as SKIPPED.

  Creates, all inside JsonDemo (2025 and later):
     Demo.OrdersText      - 200,000 order documents in nvarchar(max), no
                            constraint: what most databases have today
     Demo.OrdersJson      - the same documents in the json type
     Demo.OrdersJsonIndex - the same, with a JSON index on $.status
     Demo.OrdersComputed  - the same documents in nvarchar(max), with the
                            pre-2025 fix: a computed column on
                            JSON_VALUE(doc, '$.status') and an index on it
     Demo.ScratchText, Demo.ScratchJson, Demo.ScratchJsonIndex
                          - empty tables for the demo's inserts, so the
                            measured tables never change
     Demo.Results         - one row per measurement
     Demo.Verdicts        - one row per claim

  Creating the computed-column index prints a warning that its key can be
  up to 8,000 bytes. That's expected: JSON_VALUE returns nvarchar(4000).
  Every status here is a few characters long.

  TESTED end to end on SQL Server 2025 RTM-CU9-GDR (17.0.5015.4), Linux
  container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create JsonDemo ===';
GO

IF DB_ID('JsonDemo') IS NOT NULL
BEGIN
    RAISERROR('JsonDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE JsonDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE JsonDemo;
END
GO

CREATE DATABASE JsonDemo;
GO

ALTER DATABASE JsonDemo SET RECOVERY SIMPLE;
GO

USE JsonDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: the documents ===';
GO

/*------------------------------------------------------------------------------
  One order per document, about 160 characters:

    {"orderId":1,"customer":{"id":1,"name":"Customer 1","country":"PH"},
     "status":"shipped","total":1.25,"lines":[{"sku":"A1","qty":2},...]}

  One order in 1,000 is "held": 200 of them. The json tables are created
  with dynamic SQL so that 2022 and earlier can still run this file.
------------------------------------------------------------------------------*/
CREATE TABLE Demo.OrdersText
(
    OrderID int           NOT NULL CONSTRAINT PK_OrdersText PRIMARY KEY CLUSTERED,
    doc     nvarchar(max) NOT NULL
);

;WITH n AS
(
    SELECT TOP (200000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.OrdersText WITH (TABLOCK) (OrderID, doc)
SELECT rn,
       CONCAT(N'{"orderId":', rn,
              N',"customer":{"id":', rn % 20000, N',"name":"Customer ', rn % 20000,
              N'","country":"', CHOOSE(rn % 5 + 1, N'US', N'PH', N'DE', N'FR', N'JP'),
              N'"},"status":"', CASE WHEN rn % 1000 = 0 THEN N'held' ELSE N'shipped' END,
              N'","total":', rn % 997 + 0.25,
              N',"lines":[{"sku":"A', rn % 300, N'","qty":', rn % 7 + 1,
              N'},{"sku":"B', rn % 50, N'","qty":1}]}')
FROM   n;
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    EXEC (N'
    CREATE TABLE Demo.OrdersJson
    (
        OrderID int  NOT NULL CONSTRAINT PK_OrdersJson PRIMARY KEY CLUSTERED,
        doc     json NOT NULL
    );
    INSERT Demo.OrdersJson WITH (TABLOCK) (OrderID, doc)
    SELECT OrderID, doc FROM Demo.OrdersText;

    CREATE TABLE Demo.OrdersJsonIndex
    (
        OrderID int  NOT NULL CONSTRAINT PK_OrdersJsonIndex PRIMARY KEY CLUSTERED,
        doc     json NOT NULL
    );
    INSERT Demo.OrdersJsonIndex WITH (TABLOCK) (OrderID, doc)
    SELECT OrderID, doc FROM Demo.OrdersText;');

    EXEC (N'CREATE JSON INDEX JX_OrdersJsonIndex_status ON Demo.OrdersJsonIndex (doc) FOR (''$.status'');');

    EXEC (N'
    CREATE TABLE Demo.ScratchJson
    (
        OrderID int  NOT NULL CONSTRAINT PK_ScratchJson PRIMARY KEY CLUSTERED,
        doc     json NOT NULL
    );
    CREATE TABLE Demo.ScratchJsonIndex
    (
        OrderID int  NOT NULL CONSTRAINT PK_ScratchJsonIndex PRIMARY KEY CLUSTERED,
        doc     json NOT NULL
    );');
    EXEC (N'CREATE JSON INDEX JX_ScratchJsonIndex_status ON Demo.ScratchJsonIndex (doc) FOR (''$.status'');');
END
GO

CREATE TABLE Demo.ScratchText
(
    OrderID int           NOT NULL CONSTRAINT PK_ScratchText PRIMARY KEY CLUSTERED,
    doc     nvarchar(max) NOT NULL
);
GO

-- The pre-2025 way: index a computed column. Works on 2016 and later, so
-- it's created on every version.
CREATE TABLE Demo.OrdersComputed
(
    OrderID int           NOT NULL CONSTRAINT PK_OrdersComputed PRIMARY KEY CLUSTERED,
    doc     nvarchar(max) NOT NULL,
    status  AS JSON_VALUE(doc, '$.status')
);
INSERT Demo.OrdersComputed WITH (TABLOCK) (OrderID, doc)
SELECT OrderID, doc FROM Demo.OrdersText;

CREATE INDEX IX_OrdersComputed_status ON Demo.OrdersComputed (status);
GO


PRINT '=== STEP 3: the harness ===';
GO

CREATE TABLE Demo.Results
(
    Scenario  char(1)        NOT NULL,
    Item      varchar(120)   NOT NULL,
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
  Demo.usp_Measure -- run one statement and return its logical reads and
  CPU milliseconds, read from this session's own request before and after.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Measure
    @sql    nvarchar(max),
    @Reads  bigint OUTPUT,
    @CpuMs  bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r0 bigint, @c0 bigint, @r1 bigint, @c1 bigint;
    SELECT @r0 = logical_reads, @c0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    EXEC sys.sp_executesql @sql;
    SELECT @r1 = logical_reads, @c1 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    SELECT @Reads = @r1 - @r0, @CpuMs = @c1 - @c0;
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_Try -- run one statement, and return the error number it raised,
  or 0. The error is caught, so the demo's output carries no error message.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Try
    @sql    nvarchar(max),
    @Error  int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Error = 0;
    BEGIN TRY
        BEGIN TRAN;
        EXEC sys.sp_executesql @sql;
        ROLLBACK;
    END TRY
    BEGIN CATCH
        SET @Error = ERROR_NUMBER();
        IF @@TRANCOUNT > 0 ROLLBACK;
    END CATCH
END
GO

-- Pages used by a table, or by one of its indexes. A JSON index is stored in
-- an internal table named json_index_<object_id>_<index_id>.
CREATE OR ALTER FUNCTION Demo.fn_Pages (@Table sysname, @Index sysname)
RETURNS bigint
AS
BEGIN
    DECLARE @obj int = OBJECT_ID(@Table), @idx int, @type tinyint;
    IF @Index IS NULL
        RETURN (SELECT SUM(used_page_count) FROM sys.dm_db_partition_stats
                WHERE object_id = @obj AND index_id IN (0, 1));
    SELECT @idx = index_id, @type = type FROM sys.indexes WHERE object_id = @obj AND name = @Index;
    IF @idx < 1000
        RETURN (SELECT SUM(used_page_count) FROM sys.dm_db_partition_stats
                WHERE object_id = @obj AND index_id = @idx);
    RETURN (SELECT SUM(ps.used_page_count)
            FROM   sys.dm_db_partition_stats AS ps
            JOIN   sys.internal_tables AS it ON it.object_id = ps.object_id
            WHERE  it.name = CONCAT(N'json_index_', @obj, N'_', @idx));
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the JsonDemo database.';
PRINT ' No instance setting was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
