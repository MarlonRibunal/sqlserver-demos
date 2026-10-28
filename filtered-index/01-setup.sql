/*==============================================================================
  01-setup.sql          RUN ONCE. Takes about 10 seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, FilteredDemo, and nothing else:

       Demo.Orders  - 500,000 orders, about 14,600 pages. 500 of them are
                      open (Status = 1); the rest are closed (Status = 4).
       IX_Open      - a filtered index on the open orders only:
                      (CustomerID) INCLUDE (Amount) WHERE Status = 1

  RUN THIS FILE WITH QUOTED_IDENTIFIER ON, as SSMS and Azure Data Studio do by
  default (sqlcmd needs -I). A filtered index can't be created otherwise;
  scenario D shows why that matters.

  TESTED end to end on SQL Server 2025 RTM-CU10 (17.0.5035.5) and 2022
  RTM-CU25 (16.0.4255.1), Linux containers.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create FilteredDemo ===';
GO

IF DB_ID('FilteredDemo') IS NOT NULL
BEGIN
    RAISERROR('FilteredDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE FilteredDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE FilteredDemo;
END
GO

CREATE DATABASE FilteredDemo;
GO

ALTER DATABASE FilteredDemo SET RECOVERY SIMPLE;
GO

USE FilteredDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: the table and the filtered index ===';
GO

CREATE TABLE Demo.Orders
(
    OrderID     int        NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    Status      tinyint    NOT NULL,
    CustomerID  int        NOT NULL,
    Amount      int        NOT NULL,
    Filler      char(200)  NOT NULL CONSTRAINT DF_Orders_Filler DEFAULT ('x')
);
GO

;WITH n AS
(
    SELECT TOP (500000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.Orders WITH (TABLOCK) (OrderID, Status, CustomerID, Amount)
SELECT rn, CASE WHEN rn % 1000 = 0 THEN 1 ELSE 4 END, rn % 5000, rn % 100
FROM   n;
GO

CREATE INDEX IX_Open ON Demo.Orders (CustomerID) INCLUDE (Amount) WHERE Status = 1;
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
  Demo.usp_Measure -- run one batch twice and report the second run: its
  logical reads, and from its cached plan, whether it used IX_Open and
  whether the plan carries an UnmatchedIndexes warning (a filtered index the
  optimizer couldn't use because of a parameter).

  @Marker is the column alias in the query (for example AS literal_), which
  finds its plan in the cache. A query with OPTION (RECOMPILE) isn't cached:
  @UsesIndex and @Warning come back NULL, and the reads still count.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Measure
    @Marker     sysname,
    @sql        nvarchar(max),
    @Reads      bigint  OUTPUT,
    @UsesIndex  bit     OUTPUT,
    @Warning    bit     OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r0 bigint;
    CREATE TABLE #sink (v bigint);

    INSERT #sink EXEC sys.sp_executesql @sql;      -- compiles

    SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    INSERT #sink EXEC sys.sp_executesql @sql;      -- measured
    SELECT @Reads = logical_reads - @r0 FROM sys.dm_exec_requests WHERE session_id = @@SPID;

    DECLARE @plan xml;
    SELECT TOP (1) @plan = qp.query_plan
    FROM   sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
    WHERE  SUBSTRING(st.text, qs.statement_start_offset / 2 + 1, 4000) LIKE N'%AS ' + @Marker + N' %'
      AND  SUBSTRING(st.text, qs.statement_start_offset / 2 + 1, 4000) NOT LIKE N'%sp_executesql%'
      AND  st.text NOT LIKE N'%dm_exec_query_stats%'
    ORDER BY qs.last_execution_time DESC;

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT @UsesIndex = @plan.exist('//RelOp//Object[@Index="[IX_Open]"]'),
           @Warning   = @plan.exist('//UnmatchedIndexes');
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_Try -- run one batch and return the error number it raised, or 0.
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
PRINT ' Everything lives in the FilteredDemo database.';
PRINT ' No instance setting was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
