/*==============================================================================
  01-setup.sql          RUN ONCE. Takes about 15 seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, RegexDemo, and puts everything inside it.
     Nothing else on the instance is modified. The database is created with
     a case-insensitive collation, SQL_Latin1_General_CP1_CI_AS, whatever
     the server's default is: scenario A depends on it.

  ON SQL SERVER 2022 AND EARLIER the database is created, and the demo
  reports every scenario as SKIPPED: the REGEXP_ functions arrived in 2025.

  Creates, all inside RegexDemo:
     Demo.Codes        - 500,000 rows: a product code like 'QZ-12345'
                         (676 two-letter prefixes, about 740 rows each),
                         indexed; and an email address, one in 100 of them
                         malformed ('user100@@bad')
     Demo.usp_Measure  - run one statement, return its reads and CPU
     Demo.usp_Estimate - the optimizer's row estimate for a statement
     Demo.usp_Try      - run one statement, return the error it raised
     Demo.Results      - one row per measurement
     Demo.Verdicts     - one row per claim

  TESTED end to end on SQL Server 2025 RTM-CU9-GDR (17.0.5015.4), Linux
  container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create RegexDemo ===';
GO

IF DB_ID('RegexDemo') IS NOT NULL
BEGIN
    RAISERROR('RegexDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE RegexDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE RegexDemo;
END
GO

CREATE DATABASE RegexDemo COLLATE SQL_Latin1_General_CP1_CI_AS;
GO

ALTER DATABASE RegexDemo SET RECOVERY SIMPLE;
GO

USE RegexDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: Demo.Codes ===';
GO

CREATE TABLE Demo.Codes
(
    ID     int           NOT NULL CONSTRAINT PK_Codes PRIMARY KEY CLUSTERED,
    Code   varchar(20)   NOT NULL,
    Email  varchar(100)  NOT NULL
);

;WITH n AS
(
    SELECT TOP (500000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.Codes WITH (TABLOCK) (ID, Code, Email)
SELECT rn,
       CONCAT(CHAR(65 + rn % 26), CHAR(65 + rn / 26 % 26), '-', rn),
       CONCAT('user', rn, CASE WHEN rn % 100 = 0 THEN '@@bad' ELSE '@example.com' END)
FROM   n;

CREATE INDEX IX_Codes_Code ON Demo.Codes (Code);
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
  Demo.usp_Measure -- run one statement; return its logical reads and CPU
  milliseconds, from this session's own request before and after.
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
  Demo.usp_Estimate -- run one statement, then read the row estimate on its
  index seek or scan from the cached plan. @sql must contain a comment that
  makes its text unique, such as /*est:A1*/.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Estimate
    @sql       nvarchar(max),
    @Marker    nvarchar(40),
    @Estimate  float OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sys.sp_executesql @sql;
    WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT TOP (1) @Estimate = qp.query_plan.value(
               '(//RelOp[@PhysicalOp = "Index Seek" or @PhysicalOp = "Index Scan" or @PhysicalOp = "Clustered Index Scan"]/@EstimateRows)[1]', 'float')
    FROM   sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
    WHERE  st.text LIKE N'%' + @Marker + N'%'
      AND  st.text NOT LIKE N'%dm_exec_query_stats%'
    ORDER BY qs.last_execution_time DESC;
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
        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        SET @Error = ERROR_NUMBER();
    END CATCH
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the RegexDemo database.';
PRINT ' No instance setting was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
