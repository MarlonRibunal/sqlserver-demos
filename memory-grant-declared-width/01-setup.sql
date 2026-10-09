/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, GrantWidthDemo, and puts everything inside
     it. Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched
        - no instance-wide plan cache flush (sp_recompile only, object scoped)

     02-demo.sql clears GrantWidthDemo's OWN Query Store at its start, if
     Query Store is on. On SQL Server 2022 memory grant feedback is persisted
     there and survives sp_recompile; without the clear, a re-run would start
     from the feedback the previous run learned. That is the only thing it
     clears, and only in this database.

  Creates, all inside GrantWidthDemo:
     Demo.Names_*       - the same 500,000 names in four column declarations
     Demo.usp_Sort_*    - one sort query per table, plus one with a CAST
     Demo.Grants        - one row per measured execution
     Demo.usp_Run       - runs a query procedure and records its grant

  COST: about 300 MB of data plus transaction log, all inside GrantWidthDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), compatibility
  level 160.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;   -- Demo.usp_Run uses XML methods
GO

PRINT '=== STEP 1: create GrantWidthDemo ===';
GO

IF DB_ID('GrantWidthDemo') IS NOT NULL
BEGIN
    RAISERROR('GrantWidthDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE GrantWidthDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE GrantWidthDemo;
END
GO

CREATE DATABASE GrantWidthDemo;
GO

ALTER DATABASE GrantWidthDemo SET RECOVERY SIMPLE;
GO

USE GrantWidthDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: the same names, four declarations ===';
GO

/*------------------------------------------------------------------------------
  500,000 names of 17 characters ("Customer 00000001"), stored four times.
  The data is identical; only the declared type differs:

     Demo.Names_V50     varchar(50)
     Demo.Names_V4000   varchar(4000)
     Demo.Names_N4000   nvarchar(4000)
     Demo.Names_VMax    varchar(max)

  "Make it varchar(4000), storage is the same anyway" is true for storage.
  This topic is about what it does to memory.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.Names_V50, Demo.Names_V4000, Demo.Names_N4000, Demo.Names_VMax;
GO

CREATE TABLE Demo.Names_V50   (ID int NOT NULL PRIMARY KEY, Name varchar(50)    NOT NULL);
CREATE TABLE Demo.Names_V4000 (ID int NOT NULL PRIMARY KEY, Name varchar(4000)  NOT NULL);
CREATE TABLE Demo.Names_N4000 (ID int NOT NULL PRIMARY KEY, Name nvarchar(4000) NOT NULL);
CREATE TABLE Demo.Names_VMax  (ID int NOT NULL PRIMARY KEY, Name varchar(max)   NOT NULL);
GO

;WITH n AS
(
    SELECT TOP (500000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.Names_V50 WITH (TABLOCK) (ID, Name)
SELECT rn, 'Customer ' + RIGHT('00000000' + CAST((CAST(rn AS bigint) * 7919) % 500000 AS varchar(10)), 8)   -- not in ID order
FROM   n;

INSERT Demo.Names_V4000 WITH (TABLOCK) (ID, Name) SELECT ID, Name FROM Demo.Names_V50;
INSERT Demo.Names_N4000 WITH (TABLOCK) (ID, Name) SELECT ID, Name FROM Demo.Names_V50;
INSERT Demo.Names_VMax  WITH (TABLOCK) (ID, Name) SELECT ID, Name FROM Demo.Names_V50;
GO

SELECT  TableName = OBJECT_NAME(object_id), DataMB = SUM(used_page_count) * 8 / 1024.0
FROM    sys.dm_db_partition_stats
WHERE   object_id IN (OBJECT_ID('Demo.Names_V50'), OBJECT_ID('Demo.Names_V4000'),
                      OBJECT_ID('Demo.Names_N4000'), OBJECT_ID('Demo.Names_VMax'))
GROUP BY object_id;
GO


PRINT '=== STEP 3: the queries, and the harness ===';
GO

/*------------------------------------------------------------------------------
  The query sorts every row by Name -- the top half of an ordered list, so
  the whole table has to pass through the Sort -- and keeps only an
  aggregate, so nothing is returned. MAXDOP 1 keeps every grant serial and
  comparable.

  usp_Sort_V4000_Cast is the same query on the varchar(4000) table with
  Name CAST to varchar(50) before the sort.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Sort_V50 AS
BEGIN
    SET NOCOUNT ON; DECLARE @m int;
    SELECT @m = MAX(ID) FROM (SELECT TOP (250000) ID, Name FROM Demo.Names_V50 ORDER BY Name) AS s OPTION (MAXDOP 1);
END
GO
CREATE OR ALTER PROCEDURE Demo.usp_Sort_V4000 AS
BEGIN
    SET NOCOUNT ON; DECLARE @m int;
    SELECT @m = MAX(ID) FROM (SELECT TOP (250000) ID, Name FROM Demo.Names_V4000 ORDER BY Name) AS s OPTION (MAXDOP 1);
END
GO
CREATE OR ALTER PROCEDURE Demo.usp_Sort_N4000 AS
BEGIN
    SET NOCOUNT ON; DECLARE @m int;
    SELECT @m = MAX(ID) FROM (SELECT TOP (250000) ID, Name FROM Demo.Names_N4000 ORDER BY Name) AS s OPTION (MAXDOP 1);
END
GO
CREATE OR ALTER PROCEDURE Demo.usp_Sort_VMax AS
BEGIN
    SET NOCOUNT ON; DECLARE @m int;
    SELECT @m = MAX(ID) FROM (SELECT TOP (250000) ID, Name FROM Demo.Names_VMax ORDER BY Name) AS s OPTION (MAXDOP 1);
END
GO
CREATE OR ALTER PROCEDURE Demo.usp_Sort_V4000_Cast AS
BEGIN
    SET NOCOUNT ON; DECLARE @m int;
    SELECT @m = MAX(ID)
    FROM  (SELECT TOP (250000) ID, Name = CAST(Name AS varchar(50)) FROM Demo.Names_V4000 ORDER BY CAST(Name AS varchar(50))) AS s
    OPTION (MAXDOP 1);
END
GO

DROP TABLE IF EXISTS Demo.Grants;
CREATE TABLE Demo.Grants
(
    RunID         int            IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Scenario      varchar(60)    NOT NULL,
    ProcName      sysname        NOT NULL,
    Execution     int            NOT NULL,   -- 1 = first after recompile
    GrantKB       bigint         NULL,       -- granted
    UsedKB        bigint         NULL,       -- actually used
    IdealKB       bigint         NULL,       -- what the optimizer wanted
    EstRowSize    int            NULL,       -- the Sort's estimated row size, bytes
    CapturedAt    datetime2(3)   NOT NULL CONSTRAINT DF_GWGrants_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  Demo.usp_Run -- execute one query procedure @Times times in a row and
  record each execution's memory grant from sys.dm_exec_query_stats:
  last_grant_kb (granted), last_used_grant_kb (used), last_ideal_grant_kb
  (what the optimizer asked for before any cap).

  From the cached plan: the Sort's estimated row size, which is where the
  declared width shows up.

  With @Recompile = 1 the procedure is recompiled first (object scoped), so
  execution 1 is a fresh compile.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Run
    @Scenario  varchar(60),
    @Proc      sysname,
    @Times     int = 1,
    @Recompile bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @Recompile = 1 EXEC sys.sp_recompile @Proc;

    DECLARE @i int = 1, @sql nvarchar(300) = N'EXEC ' + @Proc + N';';
    WHILE @i <= @Times
    BEGIN
        EXEC sys.sp_executesql @sql;

        DECLARE @plan xml, @g bigint, @u bigint, @ideal bigint;
        SELECT TOP (1) @plan = qp.query_plan, @g = qs.last_grant_kb, @u = qs.last_used_grant_kb, @ideal = qs.last_ideal_grant_kb
        FROM   sys.dm_exec_query_stats AS qs
        CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
        CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
        WHERE  st.objectid = OBJECT_ID(@Proc) AND st.dbid = DB_ID()
        ORDER BY qs.last_execution_time DESC;

        ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
        INSERT Demo.Grants (Scenario, ProcName, Execution, GrantKB, UsedKB, IdealKB, EstRowSize)
        SELECT @Scenario, @Proc, @i, @g, @u, @ideal,
               @plan.value('(//RelOp[@PhysicalOp="Sort"]/@AvgRowSize)[1]', 'int');

        SET @i += 1;
    END
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the GrantWidthDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
