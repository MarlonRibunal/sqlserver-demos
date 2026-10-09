/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  The same sort over the same 500,000 seventeen-character names, stored as
  varchar(50), varchar(4000), nvarchar(4000) and varchar(max). Evidence
  lands in Demo.Grants and Demo.Verdicts; the summary is the payoff.

  Scenarios
    A  the first execution   -> the grant follows the DECLARED width
    B  the cap               -> the widest declarations ask for more than a
                                single query is allowed
    C  feedback              -> memory grant feedback shrinks it from the
                                second execution on
    D  feedback persists     -> on SQL Server 2022, through a recompile
    E  the fix in the query  -> CAST to an honest width before the sort

  This file clears GrantWidthDemo's own Query Store first (see 01-setup.sql).

  Expected runtime: about ten seconds.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), compatibility
  level 160.
==============================================================================*/

USE GrantWidthDemo;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('Demo.usp_Run') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- Persisted memory grant feedback from a previous run lives in Query Store
-- and would survive the recompiles below. Clear it -- this database only.
IF EXISTS (SELECT 1 FROM sys.database_query_store_options WHERE actual_state_desc <> 'OFF')
    ALTER DATABASE CURRENT SET QUERY_STORE CLEAR;
GO

TRUNCATE TABLE Demo.Grants;
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
  SCENARIOS A to C -- three executions of each query, from a fresh compile

  A memory grant is sized at compile time, from estimated rows times
  estimated row size. The optimizer cannot know how long the strings in a
  variable-length column really are, so it assumes they are half full:
  a varchar(4000) value is costed at about 2,000 bytes, whatever it holds.
  nvarchar(4000) is 8,000 bytes declared, so about 4,000. varchar(max) is
  costed at about 4,000.

  Execution 1 is that estimate. Executions 2 and 3 show memory grant
  feedback (row mode: SQL Server 2019+, compatibility level 150+): after an
  execution that used far less than it was granted, the next grant is cut.
==============================================================================*/
PRINT '';
PRINT '--- three executions of each sort ---';
GO

EXEC Demo.usp_Run 'A-C', 'Demo.usp_Sort_V50',   3;
EXEC Demo.usp_Run 'A-C', 'Demo.usp_Sort_V4000', 3;
EXEC Demo.usp_Run 'A-C', 'Demo.usp_Sort_N4000', 3;
EXEC Demo.usp_Run 'A-C', 'Demo.usp_Sort_VMax',  3;
GO


/*==============================================================================
  SCENARIO D -- feedback persists

  On SQL Server 2022 with Query Store on (the default for new databases),
  memory grant feedback is persisted in Query Store. Recompile the
  varchar(4000) query and run it once: the "first" execution keeps the
  learned grant.

  If Query Store is off, the grant goes back to the declared-width estimate,
  and the verdict says so.
==============================================================================*/
EXEC Demo.usp_Run 'D', 'Demo.usp_Sort_V4000', 1, 1;
GO


/*==============================================================================
  SCENARIO E -- the fix in the query

  Where the column cannot be changed, CAST it to an honest width before the
  sort. The estimate, and the grant, follow the CAST.
==============================================================================*/
EXEC Demo.usp_Run 'E', 'Demo.usp_Sort_V4000_Cast', 1;
GO


/*==============================================================================
  VERDICTS
==============================================================================*/
DECLARE @g50 bigint, @u50 bigint, @r50 int, @g4k bigint, @u4k bigint, @r4k int;
SELECT @g50 = GrantKB, @u50 = UsedKB, @r50 = EstRowSize FROM Demo.Grants WHERE Scenario = 'A-C' AND ProcName = 'Demo.usp_Sort_V50'   AND Execution = 1;
SELECT @g4k = GrantKB, @u4k = UsedKB, @r4k = EstRowSize FROM Demo.Grants WHERE Scenario = 'A-C' AND ProcName = 'Demo.usp_Sort_V4000' AND Execution = 1;

DECLARE @d nvarchar(300) = N'varchar(50): granted ' + CAST(@g50 / 1024 AS nvarchar(20)) + N' MB, row ' + CAST(@r50 AS nvarchar(10))
    + N' B; varchar(4000): granted ' + CAST(@g4k / 1024 AS nvarchar(20)) + N' MB, row ' + CAST(@r4k AS nvarchar(10))
    + N' B; both used about ' + CAST(@u4k / 1024 AS nvarchar(20)) + N' MB';
INSERT Demo.Verdicts VALUES ('A. First execution', 'same data, varchar(50) vs varchar(4000)', @d,
    'grant follows declared width; row size about half of 4000',
    CASE WHEN @g4k >= @g50 * 10 AND @r4k BETWEEN 1900 AND 2200 AND ABS(@u4k - @u50) <= @u50 * 0.1
         THEN 'DECLARED WIDTH WINS' ELSE 'unexpected' END);

DECLARE @nIdeal bigint, @nGrant bigint, @mIdeal bigint, @mGrant bigint;
SELECT @nIdeal = IdealKB, @nGrant = GrantKB FROM Demo.Grants WHERE Scenario = 'A-C' AND ProcName = 'Demo.usp_Sort_N4000' AND Execution = 1;
SELECT @mIdeal = IdealKB, @mGrant = GrantKB FROM Demo.Grants WHERE Scenario = 'A-C' AND ProcName = 'Demo.usp_Sort_VMax'  AND Execution = 1;
SET @d = N'nvarchar(4000): wanted ' + CAST(@nIdeal / 1024 AS nvarchar(20)) + N' MB, granted ' + CAST(@nGrant / 1024 AS nvarchar(20))
       + N' MB; varchar(max): wanted ' + CAST(@mIdeal / 1024 AS nvarchar(20)) + N' MB, granted ' + CAST(@mGrant / 1024 AS nvarchar(20)) + N' MB';
INSERT Demo.Verdicts VALUES ('B. The cap', 'the widest declarations', @d, 'ideal grant above what one query may have',
    CASE WHEN @nIdeal > @nGrant AND @mIdeal > @mGrant THEN 'CAPPED' ELSE 'unexpected' END);

DECLARE @g2 bigint, @u2 bigint;
SELECT @g2 = GrantKB, @u2 = UsedKB FROM Demo.Grants WHERE Scenario = 'A-C' AND ProcName = 'Demo.usp_Sort_V4000' AND Execution = 2;
SET @d = N'varchar(4000): execution 1 granted ' + CAST(@g4k / 1024 AS nvarchar(20)) + N' MB, execution 2 '
       + CAST(@g2 / 1024 AS nvarchar(20)) + N' MB, used ' + CAST(@u2 / 1024 AS nvarchar(20)) + N' MB';
INSERT Demo.Verdicts VALUES ('C. Feedback', 'second execution', @d, 'grant cut to near what is used',
    CASE WHEN @g2 <= @u2 * 3 AND @g2 * 10 < @g4k THEN 'FEEDBACK APPLIED' ELSE 'unexpected' END);

DECLARE @qs bit = CASE WHEN EXISTS (SELECT 1 FROM sys.database_query_store_options WHERE actual_state_desc <> 'OFF') THEN 1 ELSE 0 END;
DECLARE @gD bigint = (SELECT GrantKB FROM Demo.Grants WHERE Scenario = 'D');
SET @d = N'after sp_recompile, execution 1 granted ' + CAST(@gD / 1024 AS nvarchar(20)) + N' MB; Query Store '
       + CASE @qs WHEN 1 THEN N'on' ELSE N'off' END;
INSERT Demo.Verdicts VALUES ('D. Feedback persists', 'varchar(4000), recompiled', @d,
    'learned grant kept through the recompile (needs Query Store, 2022)',
    CASE WHEN @qs = 0 THEN 'INCONCLUSIVE'
         WHEN @gD * 10 < @g4k THEN 'PERSISTED' ELSE 'unexpected' END);

DECLARE @gC bigint, @rC int;
SELECT @gC = GrantKB, @rC = EstRowSize FROM Demo.Grants WHERE Scenario = 'E';
SET @d = N'CAST(Name AS varchar(50)): granted ' + CAST(@gC / 1024 AS nvarchar(20)) + N' MB, row ' + CAST(@rC AS nvarchar(10))
       + N' B; varchar(50) column: ' + CAST(@g50 / 1024 AS nvarchar(20)) + N' MB';
INSERT Demo.Verdicts VALUES ('E. The fix', 'CAST before the sort', @d, 'same grant as the honestly declared column',
    CASE WHEN ABS(@gC - @g50) <= @g50 * 0.1 THEN 'HONEST GRANT' ELSE 'unexpected' END);
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. EVERY EXECUTION ===';
GO
SELECT Scenario, ProcName, Execution, GrantMB = CAST(GrantKB / 1024.0 AS decimal(10,1)),
       UsedMB = CAST(UsedKB / 1024.0 AS decimal(10,1)), IdealMB = CAST(IdealKB / 1024.0 AS decimal(10,1)), EstRowSize
FROM   Demo.Grants ORDER BY RunID;
GO

PRINT '';
PRINT '=== 2. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario;
GO

PRINT '';
PRINT '=== 3. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Detail, Verdict FROM Demo.Verdicts WHERE Verdict IN ('unexpected', 'INCONCLUSIVE');
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 3 should be EMPTY. Anything in it is either';
PRINT ' a genuine difference on your build, or Query Store';
PRINT ' being off (scenario D) -- read it before the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
