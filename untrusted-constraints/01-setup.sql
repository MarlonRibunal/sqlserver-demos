/*==============================================================================
  01-setup.sql          RUN ONCE. Takes about 10 seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, UntrustedDemo, and nothing else:

       Demo.Customers  - 100,000 rows, about 2,600 pages
       Demo.Orders     - 500,000 rows, with a foreign key to Demo.Customers
                         and a CHECK constraint on Status (0 to 3)

  TESTED end to end on SQL Server 2025 RTM-CU10 (17.0.5035.5) and 2022
  RTM-CU25 (16.0.4255.1), Linux containers.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create UntrustedDemo ===';
GO

IF DB_ID('UntrustedDemo') IS NOT NULL
BEGIN
    RAISERROR('UntrustedDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE UntrustedDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE UntrustedDemo;
END
GO

CREATE DATABASE UntrustedDemo;
GO

ALTER DATABASE UntrustedDemo SET RECOVERY SIMPLE;
GO

USE UntrustedDemo;
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
    CustomerID  int        NOT NULL CONSTRAINT PK_Customers PRIMARY KEY CLUSTERED,
    Name        char(200)  NOT NULL
);

CREATE TABLE Demo.Orders
(
    OrderID     int      NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    CustomerID  int      NOT NULL,
    Status      tinyint  NOT NULL,
    Amount      int      NOT NULL
);
GO

;WITH n AS
(
    SELECT TOP (500000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.Customers WITH (TABLOCK) (CustomerID, Name)
SELECT rn, CONCAT('Customer ', rn) FROM n WHERE rn <= 100000;

;WITH n AS
(
    SELECT TOP (500000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.Orders WITH (TABLOCK) (OrderID, CustomerID, Status, Amount)
SELECT rn, (rn % 100000) + 1, rn % 4, rn % 100 FROM n;
GO

-- The demo drops and re-adds these; this is the starting point.
ALTER TABLE Demo.Orders ADD CONSTRAINT FK_Orders_Customers
    FOREIGN KEY (CustomerID) REFERENCES Demo.Customers (CustomerID);
ALTER TABLE Demo.Orders ADD CONSTRAINT CK_Orders_Status CHECK (Status BETWEEN 0 AND 3);
GO


PRINT '=== STEP 3: the queries ===';
GO

-- Total order value. It joins to Demo.Customers, but uses no column from it:
-- the join only removes orders without a customer.
CREATE OR ALTER PROCEDURE Demo.q_Join
AS
    SELECT SUM(CAST(o.Amount AS bigint)) AS Total
    FROM   Demo.Orders AS o
    JOIN   Demo.Customers AS c ON c.CustomerID = o.CustomerID;
GO

-- Orders with a status the CHECK constraint doesn't allow.
CREATE OR ALTER PROCEDURE Demo.q_Check
AS
    SELECT COUNT_BIG(*) AS BadStatus
    FROM   Demo.Orders
    WHERE  Status = 7;
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

/*------------------------------------------------------------------------------
  Demo.usp_Run -- recompile one of the query procedures, run it once, and
  report from its cached plan which tables it reads, and its logical reads.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Run
    @Proc       sysname,
    @Customers  bit     OUTPUT,
    @Orders     bit     OUTPUT,
    @Reads      bigint  OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sys.sp_recompile @Proc;
    CREATE TABLE #sink (v bigint);
    INSERT #sink EXEC @Proc;

    DECLARE @plan xml;
    SELECT TOP (1) @plan = qp.query_plan, @Reads = qs.last_logical_reads
    FROM   sys.dm_exec_procedure_stats AS ps
    CROSS APPLY sys.dm_exec_query_plan(ps.plan_handle) AS qp
    JOIN   sys.dm_exec_query_stats AS qs ON qs.plan_handle = ps.plan_handle
    WHERE  ps.object_id = OBJECT_ID(@Proc) AND ps.database_id = DB_ID()
    ORDER BY qs.last_execution_time DESC;

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT @Customers = @plan.exist('//RelOp//Object[@Table="[Customers]"]'),
           @Orders    = @plan.exist('//RelOp//Object[@Table="[Orders]"]');
END
GO

-- Trust and enabled state of every constraint on Demo.Orders, as one string.
CREATE OR ALTER FUNCTION Demo.fn_State (@Name sysname)
RETURNS varchar(60)
AS
BEGIN
    RETURN (SELECT CASE is_disabled WHEN 1 THEN 'disabled' ELSE 'enabled' END
                 + CASE is_not_trusted WHEN 1 THEN ', NOT trusted' ELSE ', trusted' END
            FROM  (SELECT name, is_disabled, is_not_trusted FROM sys.foreign_keys
                   UNION ALL
                   SELECT name, is_disabled, is_not_trusted FROM sys.check_constraints) AS k
            WHERE k.name = @Name);
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the UntrustedDemo database.';
PRINT ' No instance setting was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
