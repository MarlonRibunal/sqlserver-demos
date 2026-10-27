/*==============================================================================
  01-setup.sql          RUN ONCE. Takes about a minute.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, OrderedCsDemo, and puts everything inside
     it. Nothing else on the instance is modified.

  ON SQL SERVER 2019 AND EARLIER the database is created, and the demo
  reports every scenario as SKIPPED: ordered columnstore indexes arrived in
  2022. On 2022 the demo runs, and scenario D shows what 2025 added.

  Creates, all inside OrderedCsDemo:
     Demo.Source         - 4,000,000 sales rows, OrderDate spread over four
                           years in no particular order (a heap)
     Demo.Extra          - 1,048,576 more rows, the same spread: one
                           rowgroup's worth of new data
     Demo.q_CS, q_RS     - the query measured: one month's total, from
                           Demo.CS (the columnstore table the demo rebuilds)
                           and Demo.RS (a rowstore table)
     Demo.usp_Segments   - run a query procedure, return the columnstore
                           segments it read and skipped
     Demo.usp_BuildCS    - recreate Demo.CS from Demo.Source and build one
                           columnstore index on it
     Demo.usp_Try        - run one statement, return the error it raised
     Demo.Results        - one row per measurement
     Demo.Verdicts       - one row per claim

  COST: about 250 MB, all inside OrderedCsDemo.

  TESTED end to end on SQL Server 2025 RTM-CU10 (17.0.5035.5) and SQL
  Server 2022 RTM-CU25 (16.0.4255.1), Linux containers.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create OrderedCsDemo ===';
GO

IF DB_ID('OrderedCsDemo') IS NOT NULL
BEGIN
    RAISERROR('OrderedCsDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE OrderedCsDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE OrderedCsDemo;
END
GO

CREATE DATABASE OrderedCsDemo;
GO

ALTER DATABASE OrderedCsDemo SET RECOVERY SIMPLE;
GO

USE OrderedCsDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: the data ===';
GO

-- OrderDate comes from a hash of the row number, so neighbouring rows have
-- unrelated dates: the order rows arrive in says nothing about their dates.
CREATE TABLE Demo.Source
(
    ID         bigint  NOT NULL,
    OrderDate  date    NOT NULL,
    Amount     int     NOT NULL
);

INSERT Demo.Source WITH (TABLOCK) (ID, OrderDate, Amount)
SELECT TOP (4000000) n,
       DATEADD(day, ABS(CHECKSUM(CAST(n AS varchar(20)))) % 1460, CAST('2022-01-01' AS date)),
       n % 1000
FROM  (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
       FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b
       CROSS JOIN (VALUES (1), (2), (3)) AS c (x)) AS x;
GO

CREATE TABLE Demo.Extra
(
    ID         bigint  NOT NULL,
    OrderDate  date    NOT NULL,
    Amount     int     NOT NULL
);

INSERT Demo.Extra WITH (TABLOCK) (ID, OrderDate, Amount)
SELECT TOP (1048576) ID + 10000000, OrderDate, Amount FROM Demo.Source ORDER BY ID;
GO


PRINT '=== STEP 3: the query, and the harness ===';
GO

-- One month out of four years. Demo.CS and Demo.RS are created by the demo.
CREATE OR ALTER PROCEDURE Demo.q_CS
AS
    SELECT SUM(CAST(Amount AS bigint)) AS Total
    FROM   Demo.CS
    WHERE  OrderDate BETWEEN '2023-03-01' AND '2023-03-31';
GO

CREATE OR ALTER PROCEDURE Demo.q_RS
AS
    SELECT SUM(CAST(Amount AS bigint)) AS Total
    FROM   Demo.RS
    WHERE  OrderDate BETWEEN '2023-03-01' AND '2023-03-31';
GO

/*------------------------------------------------------------------------------
  Demo.usp_Segments -- run one of the query procedures, then read how many
  columnstore segments its last execution read and skipped, from
  sys.dm_exec_query_stats. That is the same count SET STATISTICS IO prints
  as "Segment reads N, segment skipped M", in a form a script can keep.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Segments
    @Proc   sysname,
    @Reads  bigint OUTPUT,
    @Skips  bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r TABLE (Total bigint);
    INSERT @r EXEC @Proc;
    SELECT TOP (1) @Reads = qs.last_columnstore_segment_reads,
                   @Skips = qs.last_columnstore_segment_skips
    FROM   sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
    WHERE  t.objectid = OBJECT_ID(@Proc) AND t.dbid = DB_ID()
    ORDER BY qs.last_execution_time DESC;
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_BuildCS -- recreate Demo.CS as a heap copy of Demo.Source, then
  run @IndexSql on it (a CREATE ... COLUMNSTORE INDEX statement). Returns
  the error the index build raised, or 0, and the compressed rowgroups it
  made. Dynamic SQL throughout: the table is dropped and recreated each time,
  and the ORDER clause doesn't parse before 2022.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_BuildCS
    @IndexSql   nvarchar(max),
    @Error      int OUTPUT,
    @RowGroups  int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC (N'DROP TABLE IF EXISTS Demo.CS;');
    EXEC (N'SELECT ID, OrderDate, Amount INTO Demo.CS FROM Demo.Source;');
    EXEC Demo.usp_Try @IndexSql, @Error OUTPUT;
    SELECT @RowGroups = COUNT(*) FROM sys.column_store_row_groups
    WHERE  object_id = OBJECT_ID(N'Demo.CS') AND state_description = N'COMPRESSED';
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_Try -- run one statement and return the error number it raised,
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


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the OrderedCsDemo database.';
PRINT ' No instance setting was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
