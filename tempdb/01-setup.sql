/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a minute or two.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, TempdbDemo, and puts everything inside it.
     Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched
        - no instance-wide plan cache flush (sp_recompile only, object scoped)

     That is not an accident. Every scenario in 02-demo.sql was chosen so that
     it demonstrates its point WITHOUT changing engine settings, which is why
     03-cleanup.sql is four lines long: it drops the database.

  Creates, all inside TempdbDemo:
     Demo.DemoState          - environment facts recorded at setup time
     Demo.DemoResults        - where 02-demo.sql records evidence
     Demo.usp_Record         - the evidence collector used by 02
     Demo.Big                - 1,000,000 rows, the base table for A and C
     Demo.Skewed             - 10,000 rows with deliberate skew, for B
     Demo.usp_A_*            - scenario A: CTE re-evaluation
     Demo.usp_B_Estimates    - scenario B: #temp vs @tablevar estimates
     Demo.usp_C_*            - scenario C: parallelism
     Demo.usp_D_*            - scenario D: temp table caching breakers
     Demo.usp_E_Size         - scenario E: the 8 MB caching cliff
     Demo.usp_F_*            - scenario F: collation and the hard stops

  COST: about 100 MB of data plus transaction log, all inside TempdbDemo.
  Scenario E writes ~12 MB into tempdb repeatedly; scenario C sorts a million
  rows. Run this on a scratch instance, not production -- see the note on the
  instance-wide performance counter in scenario D.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 15 schedulers,
  MAXDOP 0, cost threshold for parallelism 5. Scenarios C and E are the two
  that are sensitive to instance configuration; both detect and report when
  they cannot run rather than printing a misleading result.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 0: environment ===';
GO

SELECT  ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS sysname),
        EngineMajor    = CAST(SERVERPROPERTY('ProductMajorVersion') AS int),
        Edition        = CAST(SERVERPROPERTY('Edition') AS sysname),
        TempdbCollation= CAST(DATABASEPROPERTYEX('tempdb','Collation') AS sysname);

SELECT  Schedulers = cpu_count FROM sys.dm_os_sys_info;

SELECT  name, value_in_use
FROM    sys.configurations
WHERE   name IN ('max degree of parallelism','cost threshold for parallelism')
ORDER BY name;
GO


PRINT '=== STEP 1: create TempdbDemo ===';
GO

/*------------------------------------------------------------------------------
  Scenario F needs a database whose collation DIFFERS from tempdb's, because
  the whole point is that an explicitly created #temp column silently takes
  tempdb's collation and then refuses to join.

  So the collation is chosen dynamically against tempdb's actual collation.
  Hardcoding one would be the worst kind of bug here: on an instance whose
  tempdb already used that collation, scenario F would run green and
  demonstrate nothing. If no candidate differs, setup records that and
  scenario F skips itself loudly rather than reporting a pass.
------------------------------------------------------------------------------*/
IF DB_ID('TempdbDemo') IS NOT NULL
BEGIN
    RAISERROR('TempdbDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE TempdbDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE TempdbDemo;
END
GO

DECLARE @tempdbColl sysname = CAST(DATABASEPROPERTYEX('tempdb','Collation') AS sysname);
DECLARE @demoColl   sysname;

-- First candidate that differs from tempdb's collation wins.
SELECT TOP (1) @demoColl = c
FROM   (VALUES ('Latin1_General_BIN2'),
               ('SQL_Latin1_General_CP1_CI_AS'),
               ('Latin1_General_CS_AS'),
               ('Latin1_General_CI_AI')) AS x(c)
WHERE  c <> @tempdbColl
ORDER BY CASE WHEN c = 'Latin1_General_BIN2' THEN 0 ELSE 1 END;

DECLARE @sql nvarchar(400) = N'CREATE DATABASE TempdbDemo COLLATE ' + @demoColl + N';';
RAISERROR('  tempdb collation    : %s', 0, 1, @tempdbColl) WITH NOWAIT;
RAISERROR('  TempdbDemo collation: %s', 0, 1, @demoColl) WITH NOWAIT;
EXEC sys.sp_executesql @sql;
GO

ALTER DATABASE TempdbDemo SET RECOVERY SIMPLE;
GO

USE TempdbDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: state and evidence tables ===';
GO

DROP TABLE IF EXISTS Demo.DemoState;
CREATE TABLE Demo.DemoState
(
    SettingName  sysname       NOT NULL PRIMARY KEY,
    SettingValue nvarchar(256) NULL,
    CapturedAt   datetime2(0)  NOT NULL CONSTRAINT DF_TDState_CapturedAt DEFAULT SYSDATETIME()
);
GO

INSERT Demo.DemoState (SettingName, SettingValue)
VALUES ('TempdbCollation',  CAST(DATABASEPROPERTYEX('tempdb','Collation')     AS nvarchar(256))),
       ('DemoDbCollation',  CAST(DATABASEPROPERTYEX('TempdbDemo','Collation') AS nvarchar(256))),
       ('ProductVersion',   CAST(SERVERPROPERTY('ProductVersion')             AS nvarchar(256))),
       ('Schedulers',       CAST((SELECT cpu_count FROM sys.dm_os_sys_info)   AS nvarchar(256))),
       ('MaxDop',           CAST((SELECT CAST(value_in_use AS int) FROM sys.configurations
                                  WHERE name = 'max degree of parallelism')   AS nvarchar(256))),
       ('CostThreshold',    CAST((SELECT CAST(value_in_use AS int) FROM sys.configurations
                                  WHERE name = 'cost threshold for parallelism') AS nvarchar(256)));

-- Whether scenario F can run at all is decided here, once, in the open.
INSERT Demo.DemoState (SettingName, SettingValue)
SELECT 'CollationScenarioViable',
       CASE WHEN CAST(DATABASEPROPERTYEX('tempdb','Collation') AS sysname)
               = CAST(DATABASEPROPERTYEX('TempdbDemo','Collation') AS sysname)
            THEN 'NO' ELSE 'YES' END;

SELECT SettingName, SettingValue FROM Demo.DemoState ORDER BY SettingName;
GO

DROP TABLE IF EXISTS Demo.DemoResults;
CREATE TABLE Demo.DemoResults
(
    ResultID     int            IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Scenario     varchar(60)    NOT NULL,
    StepNo       int            NOT NULL,
    Item         varchar(90)    NOT NULL,   -- what was measured
    Measure      varchar(40)    NULL,       -- the unit / metric name
    NumericValue decimal(18,3)  NULL,
    TextValue    nvarchar(200)  NULL,
    Expected     nvarchar(140)  NULL,       -- what the scenario predicts
    Verdict      varchar(24)    NULL,       -- filled in by the scenario itself
    CapturedAt   datetime2(3)   NOT NULL CONSTRAINT DF_TDResults_CapturedAt DEFAULT SYSDATETIME()
);
GO

CREATE OR ALTER PROCEDURE Demo.usp_Record
    @Scenario     varchar(60),
    @StepNo       int,
    @Item         varchar(90),
    @Measure      varchar(40)   = NULL,
    @NumericValue decimal(18,3) = NULL,
    @TextValue    nvarchar(200) = NULL,
    @Expected     nvarchar(140) = NULL,
    @Verdict      varchar(24)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT Demo.DemoResults
           (Scenario, StepNo, Item, Measure, NumericValue, TextValue, Expected, Verdict)
    VALUES (@Scenario, @StepNo, @Item, @Measure, @NumericValue, @TextValue, @Expected, @Verdict);
END
GO


PRINT '=== STEP 3: base tables ===';
GO

/*------------------------------------------------------------------------------
  Demo.Big -- one million rows, wide enough that a GROUP BY over it costs
  real reads and clears the cost threshold for parallelism on a default
  instance. Scenario A counts its logical reads; scenario C watches its DOP.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.Big;
GO

SELECT TOP (1000000)
       id  = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int),
       grp = CAST(ABS(CHECKSUM(NEWID())) % 1000 AS int),
       pad = CAST('x' AS char(50))
INTO   Demo.Big
FROM   sys.all_columns AS a
CROSS JOIN sys.all_columns AS b
CROSS JOIN sys.all_columns AS c;
GO

ALTER TABLE Demo.Big ALTER COLUMN id int NOT NULL;
GO
CREATE CLUSTERED INDEX cx_Big ON Demo.Big (id);
GO

SELECT BigRows = COUNT_BIG(*) FROM Demo.Big;
GO

/*------------------------------------------------------------------------------
  Demo.Skewed -- scenario B's subject. 10,000 rows where grp 1 holds 9,000 and
  grp 2 holds 10. Uniform data would let a table variable's fixed guess look
  almost reasonable; skew is what separates "has a histogram" from "does not".
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.Skewed;
GO

;WITH n AS
(
    SELECT TOP (10000) rn = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
SELECT id  = CAST(rn AS int),
       grp = CAST(CASE WHEN rn <= 9000 THEN 1
                       WHEN rn <= 9010 THEN 2
                       ELSE 3 + (rn % 10) END AS int)
INTO   Demo.Skewed
FROM   n;
GO

SELECT Label = 'Demo.Skewed distribution', grp, Rows = COUNT_BIG(*)
FROM   Demo.Skewed
GROUP BY grp
ORDER BY Rows DESC;
GO


PRINT '=== STEP 4: scenario A procedures (CTE re-evaluation) ===';
GO

/*------------------------------------------------------------------------------
  Three ways to express the same intent. Each lives in its own procedure so
  that 02-demo.sql can read last_logical_reads per statement out of
  sys.dm_exec_query_stats without any plan-XML parsing at all.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_A_CteOnce
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH agg AS (SELECT grp, c = COUNT_BIG(*) FROM Demo.Big GROUP BY grp)
    SELECT Answer = COUNT_BIG(*) FROM agg AS a;
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_A_CteTwice
AS
BEGIN
    SET NOCOUNT ON;
    -- The CTE is named once and referenced twice. It is NOT materialised once.
    ;WITH agg AS (SELECT grp, c = COUNT_BIG(*) FROM Demo.Big GROUP BY grp)
    SELECT Answer = COUNT_BIG(*) FROM agg AS a JOIN agg AS b ON a.grp = b.grp;
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_A_TempTwice
AS
BEGIN
    SET NOCOUNT ON;
    -- Same shape, but the intermediate result is materialised exactly once.
    SELECT grp, c = COUNT_BIG(*) INTO #agg FROM Demo.Big GROUP BY grp;
    SELECT Answer = COUNT_BIG(*) FROM #agg AS a JOIN #agg AS b ON a.grp = b.grp;
END
GO


PRINT '=== STEP 5: scenario B procedure (estimates under skew) ===';
GO

/*------------------------------------------------------------------------------
  Four statements, deliberately in ONE procedure so that all four estimates
  come from a single compile against the same data.

  The statement comments carry a marker string (B1..B4) because 02-demo.sql
  identifies each statement by its text inside the plan XML. See the extraction
  note in 02-demo.sql -- it is the one genuinely subtle piece of this demo.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_B_Estimates
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #t (id int NOT NULL, grp int NOT NULL, INDEX ix_grp NONCLUSTERED (grp));
    DECLARE @tv TABLE (id int NOT NULL, grp int NOT NULL, INDEX ix_grp NONCLUSTERED (grp));

    INSERT #t  (id, grp) SELECT id, grp FROM Demo.Skewed;
    INSERT @tv (id, grp) SELECT id, grp FROM Demo.Skewed;

    -- A #temp table gets real column statistics, so both of these land on the
    -- true row counts: 9,000 and 10.
    SELECT B1 = COUNT_BIG(*) FROM #t  WHERE grp = 1;
    SELECT B2 = COUNT_BIG(*) FROM #t  WHERE grp = 2;

    -- A table variable has no column statistics. Same data, same predicate.
    SELECT B3 = COUNT_BIG(*) FROM @tv WHERE grp = 1;
    SELECT B4 = COUNT_BIG(*) FROM @tv WHERE grp = 2;
END
GO


PRINT '=== STEP 6: scenario C procedures (parallelism) ===';
GO

/*------------------------------------------------------------------------------
  Same aggregate, three destinations. last_dop in sys.dm_exec_query_stats is
  recorded per statement, so no plan parsing is needed here either.

  usp_C_Control exists to prove the INSTANCE is willing to go parallel at all.
  Without it, an instance running MAXDOP 1 would show DOP 1 everywhere and the
  scenario would look like it had proved something about table variables.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_C_Control
AS
BEGIN
    SET NOCOUNT ON;
    SELECT grp, c = COUNT_BIG(*) FROM Demo.Big GROUP BY grp;
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_C_IntoTemp
AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #t (grp int, c bigint);
    INSERT #t (grp, c) SELECT grp, COUNT_BIG(*) FROM Demo.Big GROUP BY grp;
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_C_IntoTableVar
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tv TABLE (grp int, c bigint);
    INSERT @tv (grp, c) SELECT grp, COUNT_BIG(*) FROM Demo.Big GROUP BY grp;
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_C_ReadTableVar
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tv TABLE (grp int);
    INSERT @tv (grp) SELECT DISTINCT grp FROM Demo.Big;      -- the write: serial
    SELECT c = COUNT_BIG(*)                                   -- the read: free to parallelise
    FROM   Demo.Big AS b JOIN @tv AS v ON b.grp = v.grp;
END
GO


PRINT '=== STEP 7: scenario D procedures (temp table caching) ===';
GO

/*------------------------------------------------------------------------------
  Ten variants of "create a temp table in a procedure". Scenario D executes
  each one repeatedly and watches the instance-wide Temp Tables Creation Rate
  counter. A cached temp table is truncated and reused, so the counter does
  not move; an uncacheable one is rebuilt on every single call.

  Keep these procedures trivial. The point is the DDL shape, not the workload.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_D_a_Plain AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #t (id int, pad char(100));
    INSERT #t (id, pad) VALUES (1, 'x');
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_D_b_ExplicitDrop AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #t (id int, pad char(100));
    INSERT #t (id, pad) VALUES (1, 'x');
    DROP TABLE #t;                       -- widely believed to break caching
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_D_c_UnnamedPk AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #t (id int PRIMARY KEY, pad char(100));
    INSERT #t (id, pad) VALUES (1, 'x');
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_D_d_InlineIndex AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #t (id int INDEX ix_id NONCLUSTERED, pad char(100));
    INSERT #t (id, pad) VALUES (1, 'x');
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_D_e_SelectInto AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (1) id = object_id INTO #t FROM sys.objects;
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_D_f_NamedConstraint AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #t (id int, pad char(100), CONSTRAINT PK_named PRIMARY KEY (id));
    INSERT #t (id, pad) VALUES (1, 'x');
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_D_g_IndexAfter AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #t (id int, pad char(100));
    CREATE INDEX ix ON #t (id);          -- DDL after creation
    INSERT #t (id, pad) VALUES (1, 'x');
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_D_h_AlterAfter AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #t (id int, pad char(100));
    ALTER TABLE #t ADD extra int NULL;   -- DDL after creation
    INSERT #t (id, pad) VALUES (1, 'x');
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_D_i_DynamicSql AS
BEGIN
    SET NOCOUNT ON;
    EXEC sys.sp_executesql
         N'CREATE TABLE #t (id int, pad char(100)); INSERT #t (id, pad) VALUES (1, ''x'');';
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_D_j_Large AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #t (id int, pad char(2000));
    INSERT #t (id, pad)
    SELECT TOP (6000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 'x'
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b;
END
GO


PRINT '=== STEP 8: scenario E procedure (the 8 MB cliff) ===';
GO

/*------------------------------------------------------------------------------
  One procedure, parameterised by row count. char(2000) rows make the data
  size easy to reason about: roughly 2,008 bytes per row, so the 8 MB boundary
  sits a little above 4,000 rows.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_E_Size
    @Rows int
AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #t (id int, pad char(2000));
    INSERT #t (id, pad)
    SELECT TOP (@Rows) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 'x'
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b;
END
GO


PRINT '=== STEP 9: scenario F objects (collation and the hard stops) ===';
GO

/*------------------------------------------------------------------------------
  Scenario F's join partner. Its collation is TempdbDemo's, which 01-setup
  chose specifically to differ from tempdb's.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.Customer;
CREATE TABLE Demo.Customer (code varchar(20) NOT NULL);
INSERT Demo.Customer (code) VALUES ('ACME'), ('globex');
GO

SELECT ColumnCollation = c.collation_name
FROM   sys.columns AS c
WHERE  c.object_id = OBJECT_ID('Demo.Customer') AND c.name = 'code';
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the TempdbDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
