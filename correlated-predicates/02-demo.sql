/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  The same eight estimates are captured under three statistics states:

     single-column   one full-scan statistic per column (setup's state)
     multi-column    plus CREATE STATISTICS on (City, Country, Continent)
     filtered        plus CREATE STATISTICS on (City) WHERE Country = 'France'

  Each extra statistic is created, used, and dropped again, so the file can
  be re-run. Evidence lands in Demo.Estimates and Demo.Verdicts.

  Scenarios
    A  two correlated predicates    -> legacy multiplies; new CE backs off;
                                       both well short of the truth
    B  a contradiction              -> Paris, Japan: the truth is zero
    C  three predicates             -> the gap widens
    D  the fixes                    -> multi-column statistics, filtered
                                       statistics, and a query hint -- and
                                       what each does to the contradiction

  Expected runtime: a few seconds.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), compatibility
  level 160.
==============================================================================*/

USE CorrelationDemo;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('Demo.usp_Capture') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

TRUNCATE TABLE Demo.Estimates;
-- DROP STATISTICS has no IF EXISTS; a run interrupted mid-way could leave these.
IF EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('Demo.Addresses') AND name = 'st_City_Country_Continent')
    DROP STATISTICS Demo.Addresses.st_City_Country_Continent;
IF EXISTS (SELECT 1 FROM sys.stats WHERE object_id = OBJECT_ID('Demo.Addresses') AND name = 'st_City_France')
    DROP STATISTICS Demo.Addresses.st_City_France;
DROP TABLE IF EXISTS Demo.Verdicts;
CREATE TABLE Demo.Verdicts
(
    Scenario  varchar(60)   NOT NULL,
    Item      varchar(90)   NOT NULL,
    Detail    nvarchar(300) NULL,
    Expected  nvarchar(140) NULL,
    Verdict   varchar(24)   NULL
);
GO


/*==============================================================================
  CAPTURE THE THREE STATES
==============================================================================*/
PRINT '';
PRINT '--- capturing: single-column statistics ---';
GO
EXEC Demo.usp_Capture 'single-column';
GO

PRINT '--- capturing: multi-column statistics ---';
GO
CREATE STATISTICS st_City_Country_Continent ON Demo.Addresses (City, Country, Continent) WITH FULLSCAN;
GO
EXEC Demo.usp_Capture 'multi-column';
GO
DROP STATISTICS Demo.Addresses.st_City_Country_Continent;
GO

PRINT '--- capturing: filtered statistics ---';
GO
CREATE STATISTICS st_City_France ON Demo.Addresses (City) WHERE Country = 'France' WITH FULLSCAN;
GO
EXEC Demo.usp_Capture 'filtered';
GO
DROP STATISTICS Demo.Addresses.st_City_France;
GO


/*==============================================================================
  THE PREDICTIONS

  Selectivities from the single-column statistics: City = Paris 1/200,
  Country = France (or Japan) 1/20, Continent = Europe 1/5.

  Legacy CE assumes independence and MULTIPLIES:
     2 predicates: 1,000,000 x 1/200 x 1/20          =   250
     3 predicates: x 1/5                              =    50

  The new CE (2014+) assumes some correlation and uses EXPONENTIAL BACKOFF:
  the most selective predicate in full, the next square-rooted, the third
  fourth-rooted:
     2 predicates: 1,000,000 x 1/200 x (1/20)^(1/2)   = 1,118
     3 predicates: x (1/5)^(1/4)                      =   748

  ASSUME_MIN_SELECTIVITY_FOR_FILTER_ESTIMATES tells it to assume full
  correlation -- the most selective predicate alone:
                   1,000,000 x 1/200                  = 5,000

  The truth: Paris AND France = 5,000. Paris AND Japan = 0.

  Multi-column statistics carry a density for (City, Country) and for
  (City, Country, Continent): 1/200 each, so 5,000 -- for France, AND for
  Japan, because a density is an average and knows nothing about which
  combinations actually exist.

  Filtered statistics on City for France rows only know Paris has 5,000 rows
  in France. They say nothing about Japan. And with a third predicate they
  fix only the two columns they cover: Continent is still treated as
  independent, 5,000 x 1/5 = 1,000.
==============================================================================*/
DECLARE @p TABLE (StatsState varchar(40), Marker varchar(4), Item varchar(90), Predicted decimal(18,1), Actual bigint);
INSERT @p VALUES
 ('single-column', 'E1', 'Paris AND France, new CE',                    1118.0, 5000),
 ('single-column', 'E2', 'Paris AND France, legacy CE',                  250.0, 5000),
 ('single-column', 'E3', 'Paris AND Japan, new CE',                     1118.0,    0),
 ('single-column', 'E4', 'Paris AND Japan, legacy CE',                   250.0,    0),
 ('single-column', 'E5', 'Paris, France, Europe, new CE',                748.0, 5000),
 ('single-column', 'E6', 'Paris, France, Europe, legacy CE',              50.0, 5000),
 ('single-column', 'E7', 'Paris AND France, ASSUME_MIN_SELECTIVITY',    5000.0, 5000),
 ('single-column', 'E8', 'Paris, France, Europe, ASSUME_MIN_SELECTIVITY', 5000.0, 5000),
 ('multi-column',  'E1', 'Paris AND France, new CE',                    5000.0, 5000),
 ('multi-column',  'E2', 'Paris AND France, legacy CE',                 5000.0, 5000),
 ('multi-column',  'E3', 'Paris AND Japan, new CE',                     5000.0,    0),
 ('multi-column',  'E5', 'Paris, France, Europe, new CE',               5000.0, 5000),
 ('filtered',      'E1', 'Paris AND France, new CE',                    5000.0, 5000),
 ('filtered',      'E3', 'Paris AND Japan, new CE',                     1118.0,    0),
 ('filtered',      'E5', 'Paris, France, Europe, new CE',               1000.0, 5000);

INSERT Demo.Verdicts (Scenario, Item, Detail, Expected, Verdict)
SELECT  p.StatsState,
        p.Marker + ': ' + p.Item,
        N'estimated ' + CAST(e.EstimateRows AS nvarchar(20)) + N', actual ' + CAST(p.Actual AS nvarchar(20))
            + N' (CE ' + CAST(e.CeVersion AS nvarchar(10)) + N')',
        N'estimate ' + CAST(p.Predicted AS nvarchar(20)),
        CASE WHEN e.EstimateRows IS NULL                                  THEN 'unexpected'
             WHEN ABS(e.EstimateRows - p.Predicted) <= p.Predicted * 0.02 + 1 THEN 'AS PREDICTED'
             ELSE 'unexpected' END
FROM    @p AS p
LEFT JOIN Demo.Estimates AS e ON e.StatsState = p.StatsState AND e.Marker = p.Marker;
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. ESTIMATES BY STATISTICS STATE (actual: France 5,000; Japan 0) ===';
GO
SELECT  Marker,
        Query = CASE Marker
                    WHEN 'E1' THEN 'Paris AND France, new CE'
                    WHEN 'E2' THEN 'Paris AND France, legacy CE'
                    WHEN 'E3' THEN 'Paris AND Japan, new CE'
                    WHEN 'E4' THEN 'Paris AND Japan, legacy CE'
                    WHEN 'E5' THEN 'Paris, France, Europe, new CE'
                    WHEN 'E6' THEN 'Paris, France, Europe, legacy CE'
                    WHEN 'E7' THEN 'Paris AND France, ASSUME_MIN_SELECTIVITY'
                    WHEN 'E8' THEN 'Paris, France, Europe, ASSUME_MIN_SELECTIVITY' END,
        Actual        = CASE WHEN Marker IN ('E3', 'E4') THEN 0 ELSE 5000 END,
        SingleColumn  = MAX(CASE WHEN StatsState = 'single-column' THEN EstimateRows END),
        MultiColumn   = MAX(CASE WHEN StatsState = 'multi-column'  THEN EstimateRows END),
        Filtered      = MAX(CASE WHEN StatsState = 'filtered'      THEN EstimateRows END)
FROM    Demo.Estimates
GROUP BY Marker
ORDER BY Marker;
GO

PRINT '';
PRINT '=== 2. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario, Item;
GO

PRINT '';
PRINT '=== 3. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts WHERE Verdict = 'unexpected';
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 3 should be EMPTY. Anything in it is a';
PRINT ' genuine difference on your build, worth reading before';
PRINT ' you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
