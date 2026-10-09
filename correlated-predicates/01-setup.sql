/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, CorrelationDemo, and puts everything inside
     it. Nothing else on the instance is modified:

        - no compatibility level is changed (the legacy estimator is reached
          with a query hint)
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched
        - no instance-wide plan cache flush (sp_recompile only, object scoped)

  Creates, all inside CorrelationDemo:
     Demo.Addresses        - 1,000,000 rows; City determines Country, and
                             Country determines Continent
     Demo.usp_Estimates    - eight estimates, compiled together
     Demo.Estimates        - one row per estimate per statistics state
     Demo.usp_Capture      - recompiles, runs and records usp_Estimates

  COST: about 200 MB of data plus transaction log, all inside CorrelationDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), compatibility
  level 160.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;   -- Demo.usp_Capture uses XML methods
GO

PRINT '=== STEP 1: create CorrelationDemo ===';
GO

IF DB_ID('CorrelationDemo') IS NOT NULL
BEGIN
    RAISERROR('CorrelationDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE CorrelationDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE CorrelationDemo;
END
GO

CREATE DATABASE CorrelationDemo;
GO

ALTER DATABASE CorrelationDemo SET RECOVERY SIMPLE;
GO

USE CorrelationDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: Demo.Addresses ===';
GO

/*------------------------------------------------------------------------------
  1,000,000 addresses spread evenly over 200 cities. The hierarchy is strict:

     200 cities, 10 per country    -> City determines Country
      20 countries, 4 per continent -> Country determines Continent
       5 continents

  City 1 is named Paris, country 1 France, continent 1 Europe. Country 11 is
  Japan, on another continent -- so "Paris, Japan" matches nothing.

  Every city has exactly 5,000 rows, every country 50,000, every continent
  200,000. Uniform on purpose: the ONLY thing the estimator can get wrong
  here is the relationship between the columns.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.Addresses;
GO

CREATE TABLE Demo.Addresses
(
    AddressID int          NOT NULL,
    City      varchar(20)  NOT NULL,
    Country   varchar(20)  NOT NULL,
    Continent varchar(20)  NOT NULL,
    pad       char(80)     NOT NULL CONSTRAINT DF_Addresses_pad DEFAULT ('x'),
    CONSTRAINT PK_Addresses PRIMARY KEY CLUSTERED (AddressID)
);
GO

;WITH n AS
(
    SELECT TOP (1000000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b CROSS JOIN sys.all_columns AS c
),
k AS
(
    SELECT rn, city = (rn - 1) % 200 + 1 FROM n
),
h AS
(
    SELECT rn, city, country = (city - 1) / 10 + 1, continent = ((city - 1) / 10) / 4 + 1 FROM k
)
INSERT Demo.Addresses WITH (TABLOCK) (AddressID, City, Country, Continent)
SELECT rn,
       CASE city      WHEN 1  THEN 'Paris'  ELSE 'City'      + CAST(city AS varchar(10)) END,
       CASE country   WHEN 1  THEN 'France' WHEN 11 THEN 'Japan' ELSE 'Country' + CAST(country AS varchar(10)) END,
       CASE continent WHEN 1  THEN 'Europe' ELSE 'Continent' + CAST(continent AS varchar(10)) END
FROM   h;
GO

-- Single-column statistics on each column, built with a full scan, so the
-- starting point is the best per-column information SQL Server can have.
CREATE STATISTICS st_City      ON Demo.Addresses (City)      WITH FULLSCAN;
CREATE STATISTICS st_Country   ON Demo.Addresses (Country)   WITH FULLSCAN;
CREATE STATISTICS st_Continent ON Demo.Addresses (Continent) WITH FULLSCAN;
GO

SELECT  Paris          = SUM(CASE WHEN City = 'Paris' THEN 1 ELSE 0 END),
        France         = SUM(CASE WHEN Country = 'France' THEN 1 ELSE 0 END),
        Europe         = SUM(CASE WHEN Continent = 'Europe' THEN 1 ELSE 0 END),
        ParisFrance    = SUM(CASE WHEN City = 'Paris' AND Country = 'France' THEN 1 ELSE 0 END),
        ParisJapan     = SUM(CASE WHEN City = 'Paris' AND Country = 'Japan' THEN 1 ELSE 0 END)
FROM    Demo.Addresses;
GO


PRINT '=== STEP 3: the estimates, and the harness ===';
GO

/*------------------------------------------------------------------------------
  Eight statements in ONE procedure, so all eight estimates come from a
  single compile against the same statistics. Each carries a marker (E1..E8)
  that Demo.usp_Capture finds in the plan XML.

     E1/E2  City = Paris AND Country = France            new CE / legacy CE
     E3/E4  City = Paris AND Country = Japan             new CE / legacy CE
     E5/E6  City, Country AND Continent = Europe         new CE / legacy CE
     E7     E1 with ASSUME_MIN_SELECTIVITY_FOR_FILTER_ESTIMATES
     E8     E5 with ASSUME_MIN_SELECTIVITY_FOR_FILTER_ESTIMATES
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Estimates
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @c bigint;

    SELECT @c = COUNT_BIG(*) /* E1 */ FROM Demo.Addresses WHERE City = 'Paris' AND Country = 'France';
    SELECT @c = COUNT_BIG(*) /* E2 */ FROM Demo.Addresses WHERE City = 'Paris' AND Country = 'France'
    OPTION (USE HINT ('FORCE_LEGACY_CARDINALITY_ESTIMATION'));

    SELECT @c = COUNT_BIG(*) /* E3 */ FROM Demo.Addresses WHERE City = 'Paris' AND Country = 'Japan';
    SELECT @c = COUNT_BIG(*) /* E4 */ FROM Demo.Addresses WHERE City = 'Paris' AND Country = 'Japan'
    OPTION (USE HINT ('FORCE_LEGACY_CARDINALITY_ESTIMATION'));

    SELECT @c = COUNT_BIG(*) /* E5 */ FROM Demo.Addresses WHERE City = 'Paris' AND Country = 'France' AND Continent = 'Europe';
    SELECT @c = COUNT_BIG(*) /* E6 */ FROM Demo.Addresses WHERE City = 'Paris' AND Country = 'France' AND Continent = 'Europe'
    OPTION (USE HINT ('FORCE_LEGACY_CARDINALITY_ESTIMATION'));

    SELECT @c = COUNT_BIG(*) /* E7 */ FROM Demo.Addresses WHERE City = 'Paris' AND Country = 'France'
    OPTION (USE HINT ('ASSUME_MIN_SELECTIVITY_FOR_FILTER_ESTIMATES'));
    SELECT @c = COUNT_BIG(*) /* E8 */ FROM Demo.Addresses WHERE City = 'Paris' AND Country = 'France' AND Continent = 'Europe'
    OPTION (USE HINT ('ASSUME_MIN_SELECTIVITY_FOR_FILTER_ESTIMATES'));
END
GO

DROP TABLE IF EXISTS Demo.Estimates;
CREATE TABLE Demo.Estimates
(
    StatsState   varchar(40)    NOT NULL,
    Marker       varchar(4)     NOT NULL,
    CeVersion    int            NULL,
    EstimateRows decimal(18,1)  NULL,
    CapturedAt   datetime2(3)   NOT NULL CONSTRAINT DF_CDEst_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  Demo.usp_Capture -- recompile Demo.usp_Estimates (object scoped), run it,
  and record each statement's estimate: the EstimateRows of the scan that
  applies the predicate, which is the estimate for the WHERE clause as a
  whole.

  Each statement's estimate is read from inside its own StmtSimple node --
  never a '//RelOp' over the whole procedure plan, which would return the
  first statement's number eight times. (See the tempdb topic.)
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Capture
    @StatsState varchar(40)
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sys.sp_recompile N'Demo.usp_Estimates';
    EXEC Demo.usp_Estimates;

    DECLARE @plan xml;
    SELECT TOP (1) @plan = qp.query_plan
    FROM   sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
    WHERE  st.objectid = OBJECT_ID('Demo.usp_Estimates') AND st.dbid = DB_ID()
      AND  qp.query_plan IS NOT NULL;

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
     s AS
     (
        SELECT  Txt = n.value('@StatementText', 'nvarchar(400)'),
                Ce  = n.value('@CardinalityEstimationModelVersion', 'int'),
                Est = n.value('(.//RelOp[IndexScan or TableScan]/@EstimateRows)[1]', 'float')
        FROM    @plan.nodes('//StmtSimple') AS x(n)
     )
    INSERT Demo.Estimates (StatsState, Marker, CeVersion, EstimateRows)
    SELECT @StatsState, SUBSTRING(Txt, CHARINDEX('/* E', Txt) + 3, 2), Ce, Est
    FROM   s
    WHERE  Txt LIKE '%/* E%';
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the CorrelationDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
