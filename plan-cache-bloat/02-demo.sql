/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Plan cache bloat: one query, sent 1,000 times with a different value
  written into its text each time, and what each fix leaves in the cache.

     A  ad hoc SQL: a full plan for every value
     B  a simpler query: simple parameterization, and the shells it leaves
     C  'optimize for ad hoc workloads': stubs instead of plans
     D  forced parameterization
     E  sp_executesql with a parameter

  >>> THIS CHANGES AN INSTANCE SETTING WHILE IT RUNS <<<
  'optimize for ad hoc workloads' is turned OFF for A and B, ON for C, and
  then put back to the value 01-setup.sql recorded, as is 'show advanced
  options'. The last verdict checks that. If this script is stopped
  halfway, run 03-cleanup.sql: it restores them too.

  ALSO: it switches PlanCacheDemo to forced parameterization and back, and
  removes its own plans from the cache at the start and the end, one plan
  handle at a time. It never clears the whole plan cache.

  TESTED end to end on SQL Server 2025 RTM-CU10 (17.0.5035.5) and 2022
  RTM-CU25 (16.0.4255.1), Linux containers.
==============================================================================*/

USE PlanCacheDemo;
GO
SET NOCOUNT ON;
GO

TRUNCATE TABLE Demo.Results;
TRUNCATE TABLE Demo.Verdicts;
GO

-- Start clean: none of this demo's plans in the cache, simple
-- parameterization, and the ad hoc setting off.
ALTER DATABASE CURRENT SET PARAMETERIZATION SIMPLE;
GO
EXEC Demo.usp_Evict N'adhoc_a';
EXEC Demo.usp_Evict N'simple_b';
EXEC Demo.usp_Evict N'stub_c';
EXEC Demo.usp_Evict N'forced_d';
EXEC Demo.usp_Evict N'param_e';
EXEC Demo.usp_SetAdHoc @On = 0;
GO


/*==============================================================================
  A. A join, for 1,000 customers, each with the value in the text.
==============================================================================*/
PRINT '=== A. ad hoc SQL ===';
GO
EXEC Demo.usp_Send @Marker = N'adhoc_a', @Shape = 'join', @Param = 0;

DECLARE @adhoc int, @stubs int, @prep int, @kb bigint, @uses bigint, @hashes int;
EXEC Demo.usp_Cache N'adhoc_a', @adhoc OUTPUT, @stubs OUTPUT, @prep OUTPUT, @kb OUTPUT, @uses OUTPUT, @hashes OUTPUT;

INSERT Demo.Results (Scenario, Item, Value) VALUES
('A', 'full ad hoc plans in the cache',             CAST(@adhoc AS varchar(20))),
('A', 'prepared (parameterized) plans',             CAST(@prep AS varchar(20))),
('A', 'cache used, KB',                             CAST(@kb AS varchar(20))),
('A', 'distinct query_hash values among them',      CAST(@hashes AS varchar(20)));

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('A', 'every value compiles and caches its own full plan, each used once',
 CAST(@adhoc AS varchar(20)) + ' plans, ' + CAST(@kb AS varchar(20)) + ' KB',
 CASE WHEN @adhoc = 1000 AND @prep = 0 THEN 'CONFIRMED' ELSE 'unexpected' END),
('A', 'they are one query: all 1,000 share one query_hash, which is how to find them',
 CAST(@hashes AS varchar(20)) + ' query_hash value(s)',
 CASE WHEN @hashes = 1 THEN 'CONFIRMED' ELSE 'unexpected' END);
GO


/*==============================================================================
  B. A single-table query simple enough for simple parameterization.
==============================================================================*/
PRINT '=== B. simple parameterization ===';
GO
EXEC Demo.usp_Send @Marker = N'simple_b', @Shape = 'simple', @Param = 0;

DECLARE @adhoc int, @stubs int, @prep int, @kb bigint, @uses bigint, @hashes int;
EXEC Demo.usp_Cache N'simple_b', @adhoc OUTPUT, @stubs OUTPUT, @prep OUTPUT, @kb OUTPUT, @uses OUTPUT, @hashes OUTPUT;

-- The parameter list of each prepared plan SQL Server made, and how often
-- each was used.
DECLARE @lists varchar(400) =
    (SELECT STRING_AGG(CAST(LEFT(st.text, CHARINDEX(N')', st.text)) AS varchar(100))
                       + ' used ' + CAST(cp.usecounts AS varchar(10)) + 'x', '; ')
            WITHIN GROUP (ORDER BY cp.usecounts DESC)
     FROM   sys.dm_exec_cached_plans AS cp
     CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS st
     WHERE  cp.objtype = 'Prepared' AND st.text LIKE N'%[[]simple_b] FROM%');

INSERT Demo.Results (Scenario, Item, Value) VALUES
('B', 'prepared (parameterized) plans / times used', CAST(@prep AS varchar(20)) + ' / ' + CAST(@uses AS varchar(20))),
('B', 'their parameter lists',                        @lists),
('B', 'ad hoc entries still cached (shells)',         CAST(@adhoc AS varchar(20))),
('B', 'cache used, KB',                               CAST(@kb AS varchar(20)));

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('B', 'SQL Server parameterizes the simple query itself, used 1,000 times between its prepared plans',
 CAST(@prep AS varchar(20)) + ' prepared plan(s), used ' + CAST(@uses AS varchar(20)) + ' times',
 CASE WHEN @prep BETWEEN 1 AND 2 AND @uses = 1000 THEN 'CONFIRMED' ELSE 'unexpected' END),
('B', 'but not one plan: the parameter type comes from the literal (tinyint up to 255, smallint above), and each type is a plan of its own',
 @lists,
 CASE WHEN @prep = 2 AND @lists LIKE '%tinyint%' AND @lists LIKE '%smallint%' THEN 'CONFIRMED' ELSE 'unexpected' END),
('B', 'but each original text still gets an ad hoc cache entry (a shell pointing to it)',
 CAST(@adhoc AS varchar(20)) + ' ad hoc entries, ' + CAST(@kb AS varchar(20)) + ' KB in all',
 CASE WHEN @adhoc = 1000 THEN 'CONFIRMED' ELSE 'unexpected' END);
GO


/*==============================================================================
  C. 'optimize for ad hoc workloads' ON: the join of A again. Then customer
  1's query a second time.
==============================================================================*/
PRINT '=== C. optimize for ad hoc workloads ===';
GO
EXEC Demo.usp_SetAdHoc @On = 1;
EXEC Demo.usp_Send @Marker = N'stub_c', @Shape = 'join', @Param = 0;

DECLARE @adhoc int, @stubs int, @prep int, @kb bigint, @uses bigint, @hashes int;
EXEC Demo.usp_Cache N'stub_c', @adhoc OUTPUT, @stubs OUTPUT, @prep OUTPUT, @kb OUTPUT, @uses OUTPUT, @hashes OUTPUT;

EXEC Demo.usp_Send @Marker = N'stub_c', @Shape = 'join', @Param = 0, @Count = 1;
DECLARE @adhoc2 int, @stubs2 int, @kb2 bigint;
EXEC Demo.usp_Cache N'stub_c', @adhoc2 OUTPUT, @stubs2 OUTPUT, @prep OUTPUT, @kb2 OUTPUT, @uses OUTPUT, @hashes OUTPUT;
EXEC Demo.usp_SetAdHoc @On = 0;

DECLARE @kbA bigint = (SELECT CAST(Value AS bigint) FROM Demo.Results WHERE Scenario = 'A' AND Item = 'cache used, KB');

INSERT Demo.Results (Scenario, Item, Value) VALUES
('C', 'after 1,000 values: full plans / stubs',          CAST(@adhoc AS varchar(20)) + ' / ' + CAST(@stubs AS varchar(20))),
('C', 'cache used, KB',                                  CAST(@kb AS varchar(20))),
('C', 'after customer 1 ran again: full plans / stubs',  CAST(@adhoc2 AS varchar(20)) + ' / ' + CAST(@stubs2 AS varchar(20)));

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('C', 'a query''s first run caches only a small stub: a fraction of A''s cache use',
 CAST(@stubs AS varchar(20)) + ' stubs, ' + CAST(@kb AS varchar(20)) + ' KB (A: ' + CAST(@kbA AS varchar(20)) + ' KB)',
 CASE WHEN @stubs = 1000 AND @adhoc = 0 AND @kb * 10 < @kbA THEN 'CONFIRMED' ELSE 'unexpected' END),
('C', 'the second run of the same text caches the full plan',
 CAST(@adhoc2 AS varchar(20)) + ' full plan(s), ' + CAST(@stubs2 AS varchar(20)) + ' stubs',
 CASE WHEN @adhoc2 = 1 AND @stubs2 = 999 THEN 'CONFIRMED' ELSE 'unexpected' END);
GO


/*==============================================================================
  D. Forced parameterization for the database: the join of A again.
  Changing it clears this database's plans, so A's go too.
==============================================================================*/
PRINT '=== D. forced parameterization ===';
GO
ALTER DATABASE CURRENT SET PARAMETERIZATION FORCED;
GO
EXEC Demo.usp_Send @Marker = N'forced_d', @Shape = 'join', @Param = 0;

DECLARE @adhoc int, @stubs int, @prep int, @kb bigint, @uses bigint, @hashes int;
EXEC Demo.usp_Cache N'forced_d', @adhoc OUTPUT, @stubs OUTPUT, @prep OUTPUT, @kb OUTPUT, @uses OUTPUT, @hashes OUTPUT;

INSERT Demo.Results (Scenario, Item, Value) VALUES
('D', 'prepared (parameterized) plans / times used', CAST(@prep AS varchar(20)) + ' / ' + CAST(@uses AS varchar(20))),
('D', 'ad hoc entries still cached (shells)',         CAST(@adhoc AS varchar(20))),
('D', 'cache used, KB',                               CAST(@kb AS varchar(20)));

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('D', 'forced parameterization makes the join one prepared plan, used 1,000 times, plus a shell per text',
 CAST(@prep AS varchar(20)) + ' prepared, used ' + CAST(@uses AS varchar(20)) + ' times; ' + CAST(@adhoc AS varchar(20)) + ' shells',
 CASE WHEN @prep = 1 AND @uses = 1000 AND @adhoc = 1000 THEN 'CONFIRMED' ELSE 'unexpected' END);
GO
ALTER DATABASE CURRENT SET PARAMETERIZATION SIMPLE;
GO


/*==============================================================================
  E. The fix in the application: the value as a parameter.
==============================================================================*/
PRINT '=== E. sp_executesql ===';
GO
EXEC Demo.usp_Send @Marker = N'param_e', @Shape = 'join', @Param = 1;

DECLARE @adhoc int, @stubs int, @prep int, @kb bigint, @uses bigint, @hashes int;
EXEC Demo.usp_Cache N'param_e', @adhoc OUTPUT, @stubs OUTPUT, @prep OUTPUT, @kb OUTPUT, @uses OUTPUT, @hashes OUTPUT;

INSERT Demo.Results (Scenario, Item, Value) VALUES
('E', 'prepared plans / times used', CAST(@prep AS varchar(20)) + ' / ' + CAST(@uses AS varchar(20))),
('E', 'ad hoc entries',              CAST(@adhoc AS varchar(20))),
('E', 'cache used, KB',              CAST(@kb AS varchar(20)));

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('E', 'with the value as a parameter: one plan, used 1,000 times, and nothing else cached',
 CAST(@prep AS varchar(20)) + ' prepared, used ' + CAST(@uses AS varchar(20)) + ' times; ' + CAST(@adhoc AS varchar(20)) + ' ad hoc; ' + CAST(@kb AS varchar(20)) + ' KB',
 CASE WHEN @prep = 1 AND @uses = 1000 AND @adhoc = 0 THEN 'CONFIRMED' ELSE 'unexpected' END);
GO


/*==============================================================================
  Put the instance settings back, check them, and remove this demo's plans.
==============================================================================*/
PRINT '=== restoring the instance settings ===';
GO
EXEC Demo.usp_RestoreConfig;
GO
DECLARE @bad int = (SELECT COUNT(*)
                    FROM   Demo.OriginalConfig AS o
                    JOIN   sys.configurations AS c ON c.name = o.Name
                    WHERE  CAST(c.value_in_use AS int) <> o.ValueInUse);
DECLARE @now varchar(200) = (SELECT STRING_AGG(CAST(c.name AS varchar(60)) + ' = ' + CAST(c.value_in_use AS varchar(5)), ', ')
                             FROM sys.configurations AS c
                             WHERE c.name IN (N'show advanced options', N'optimize for ad hoc workloads'));
INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('Z', 'the instance settings are back to the values recorded at setup',
 @now, CASE WHEN @bad = 0 THEN 'CONFIRMED' ELSE 'unexpected' END);

EXEC Demo.usp_Evict N'adhoc_a';
EXEC Demo.usp_Evict N'simple_b';
EXEC Demo.usp_Evict N'stub_c';
EXEC Demo.usp_Evict N'forced_d';
EXEC Demo.usp_Evict N'param_e';
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. EVERY ATTEMPT ===';
GO
SELECT Scenario, Item, Value FROM Demo.Results ORDER BY Seq;
GO

PRINT '';
PRINT '=== 2. VERDICTS ===';
GO
SELECT Scenario, Claim, Evidence, Verdict FROM Demo.Verdicts ORDER BY Scenario, Seq;
GO

PRINT '';
PRINT '=== 3. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Claim, Evidence, Verdict FROM Demo.Verdicts
WHERE  Verdict IN ('unexpected', 'INCONCLUSIVE', 'SKIPPED') ORDER BY Scenario, Seq;
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 3 should be EMPTY. Anything in it is a';
PRINT ' genuine difference on your build, worth reading before';
PRINT ' you trust the rest.';
PRINT '';
PRINT ' The instance settings are back to what setup recorded';
PRINT ' (the last verdict checks it). Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
