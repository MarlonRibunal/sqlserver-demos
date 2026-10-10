/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  Five versions of one optional-parameter search, each called four ways:
  by customer, by date, by both, and with no filter at all. Evidence lands
  in Demo.Calls and Demo.Verdicts; the summary is the payoff.

  Scenarios
    A  the catch-all            -> one plan for every combination, and it is
                                   bad for most of them
    B  OPTION (RECOMPILE)       -> each call planned for its own values
    C  ... with SELECT @var =   -> the same hint, and the catch-all survives
    D  dynamic SQL              -> a cached plan per combination, reused
    E  COALESCE                 -> shorter, slower, and wrong

  Expected runtime: about twenty seconds.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers.
==============================================================================*/

USE CatchAllDemo;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('Demo.usp_Call') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

TRUNCATE TABLE Demo.Calls;
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

-- Object-scoped recompiles, so the first search of each variant compiles.
EXEC sys.sp_recompile N'Demo.usp_Search_CatchAll';
EXEC sys.sp_recompile N'Demo.usp_Search_Recompile';
EXEC sys.sp_recompile N'Demo.usp_Search_RecompileAssign';
EXEC sys.sp_recompile N'Demo.usp_Search_Dynamic';
EXEC sys.sp_recompile N'Demo.usp_Search_Coalesce';
GO


/*==============================================================================
  RUN EVERY VARIANT, EVERY SEARCH

  In the order an application might: customer first (that compiles the
  catch-all's one plan), then date, both, none. Each call runs twice and the
  second is measured, so a cached plan is measured without its compile.
==============================================================================*/
PRINT '';
PRINT '--- 5 variants x 4 searches ---';
GO

DECLARE @v varchar(20), @s varchar(40);
DECLARE calls CURSOR LOCAL FAST_FORWARD FOR
    SELECT v, s
    FROM   (VALUES ('CatchAll',1),('Recompile',2),('RecompileAssign',3),('Dynamic',4),('Coalesce',5)) AS a(v, o)
    CROSS JOIN (VALUES ('customer',1),('date',2),('both',3),('none',4)) AS b(s, p)
    ORDER BY o, p;
OPEN calls; FETCH NEXT FROM calls INTO @v, @s;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC Demo.usp_Call @v, @s; FETCH NEXT FROM calls INTO @v, @s; END
CLOSE calls; DEALLOCATE calls;
GO


/*==============================================================================
  SCENARIO A -- the catch-all

  WHERE (@p IS NULL OR col = @p) compiles ONE plan that must be correct for
  every combination of NULL and non-NULL arguments. It cannot simply seek on
  CustomerID, because next time @CustomerID might be NULL. On the tested
  build it scanned the CustomerID index and looked up every row it kept --
  fine when the customer filter is there, ruinous when it is not: a date
  search reads every row through a lookup.
==============================================================================*/
DECLARE @caDate bigint = (SELECT LogicalReads FROM Demo.Calls WHERE Variant = 'CatchAll' AND Search = 'date');
DECLARE @dyDate bigint = (SELECT LogicalReads FROM Demo.Calls WHERE Variant = 'Dynamic'  AND Search = 'date');
DECLARE @caCust bigint = (SELECT LogicalReads FROM Demo.Calls WHERE Variant = 'CatchAll' AND Search = 'customer');
DECLARE @dyCust bigint = (SELECT LogicalReads FROM Demo.Calls WHERE Variant = 'Dynamic'  AND Search = 'customer');
-- SQL Server 2025 adds optional parameter plan optimization (OPPO) at
-- compatibility level 170, aimed at exactly this pattern. On the 2025 CI
-- run the catch-all came within a few percent of the dynamic version, so
-- the prediction depends on the compatibility level.
DECLARE @compat int = (SELECT compatibility_level FROM sys.databases WHERE database_id = DB_ID());
DECLARE @d nvarchar(300) = N'compatibility level ' + CAST(@compat AS nvarchar(10)) + N'; date search: '
    + CAST(@caDate AS nvarchar(20)) + N' reads vs ' + CAST(@dyDate AS nvarchar(20))
    + N' dynamic; customer search: ' + CAST(@caCust AS nvarchar(20)) + N' vs ' + CAST(@dyCust AS nvarchar(20));
IF @compat >= 170
    INSERT Demo.Verdicts VALUES ('A. The catch-all', 'one plan for every combination', @d,
        'level 170+ (OPPO): close to the dynamic version',
        CASE WHEN @caDate <= @dyDate * 1.5 AND @caCust <= @dyCust * 2 THEN 'OPPO HANDLES IT' ELSE 'unexpected' END);
ELSE
    INSERT Demo.Verdicts VALUES ('A. The catch-all', 'one plan for every combination', @d,
        'far worse than the dynamic version',
        CASE WHEN @caDate >= @dyDate * 50 AND @caCust >= @dyCust * 5 THEN 'ONE PLAN FITS NONE' ELSE 'unexpected' END);
GO


/*==============================================================================
  SCENARIO B -- OPTION (RECOMPILE)

  With RECOMPILE the optimizer compiles every call with the actual argument
  values embedded (the "parameter embedding optimization"), so
  "@CustomerID IS NULL" is known to be true or false and the dead branches
  disappear. Each call gets the plan the dynamic version would have.

  The price is a compile on every call -- here a few dozen reads and a
  couple of milliseconds, invisible on a report, real on a query that runs
  thousands of times a second.
==============================================================================*/
DECLARE @worst decimal(10,2) =
    (SELECT MAX(r.LogicalReads * 1.0 / NULLIF(d.LogicalReads, 0))
     FROM   Demo.Calls AS r JOIN Demo.Calls AS d ON d.Search = r.Search AND d.Variant = 'Dynamic'
     WHERE  r.Variant = 'Recompile');
DECLARE @d nvarchar(300) = N'worst ratio to the dynamic version across the four searches: '
    + CAST(@worst AS nvarchar(20)) + N'x';
INSERT Demo.Verdicts VALUES ('B. RECOMPILE', 'each call planned for its own values', @d, 'close to dynamic SQL on every search',
    CASE WHEN @worst <= 1.5 THEN 'NEAR DYNAMIC' ELSE 'unexpected' END);
GO


/*==============================================================================
  SCENARIO C -- RECOMPILE with SELECT @var = ...

  usp_Search_RecompileAssign is usp_Search_Recompile with one change: the
  result is assigned to variables instead of returned. On the tested build
  that was enough to stop the parameter values being embedded -- the plan
  was compiled fresh every time and was STILL the catch-all scan.

  Many real search procedures assign to variables or OUTPUT parameters. If
  yours does, RECOMPILE may not be doing what you think: check the plan.
==============================================================================*/
DECLARE @ra bigint = (SELECT LogicalReads FROM Demo.Calls WHERE Variant = 'RecompileAssign' AND Search = 'customer');
DECLARE @rr bigint = (SELECT LogicalReads FROM Demo.Calls WHERE Variant = 'Recompile'       AND Search = 'customer');
DECLARE @d nvarchar(300) = N'customer search: ' + CAST(@ra AS nvarchar(20)) + N' reads assigning to variables, '
    + CAST(@rr AS nvarchar(20)) + N' returning the result';
INSERT Demo.Verdicts VALUES ('C. RECOMPILE + SELECT @var', 'the same hint, assigning the result', @d,
    'no embedding: catch-all plan every time',
    CASE WHEN @ra >= @rr * 5 THEN 'NO EMBEDDING' ELSE 'unexpected' END);
GO


/*==============================================================================
  SCENARIO D -- dynamic SQL

  Build only the predicates that were supplied, and execute with
  sp_executesql and parameters. Each combination is a different statement
  text, so each gets its own cached plan -- compiled once, reused by every
  later call with the same combination, with no compile per call.

  Parameters, never concatenated values: concatenating would cache a plan
  per VALUE and open the door to SQL injection.
==============================================================================*/
DECLARE @plans int =
    (SELECT COUNT(*)
     FROM   sys.dm_exec_query_stats AS qs
     CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
     WHERE  st.text LIKE N'%SELECT Rows = COUNT_BIG(*), Total = SUM(Amount) FROM Demo.Orders WHERE 1 = 1%'
       AND  st.text NOT LIKE N'%sys.dm_exec_query_stats%');
DECLARE @best bit =
    CASE WHEN NOT EXISTS (SELECT 1 FROM Demo.Calls AS d JOIN Demo.Calls AS o ON o.Search = d.Search
                          WHERE d.Variant = 'Dynamic' AND o.Variant <> 'Dynamic' AND o.LogicalReads < d.LogicalReads * 0.95)
         THEN 1 ELSE 0 END;
DECLARE @d nvarchar(300) = CAST(@plans AS nvarchar(10)) + N' cached plans for the dynamic statement, one per combination; '
    + CASE @best WHEN 1 THEN N'fewest reads on every search' ELSE N'NOT the fewest reads everywhere' END;
INSERT Demo.Verdicts VALUES ('D. Dynamic SQL', 'a plan per combination', @d, 'four plans; best or equal reads',
    CASE WHEN @plans = 4 AND @best = 1 THEN 'PLAN PER SHAPE' ELSE 'unexpected' END);
GO


/*==============================================================================
  SCENARIO E -- COALESCE

  WHERE SalesRepID = COALESCE(@SalesRepID, SalesRepID) reads as "any rep"
  when @SalesRepID is NULL. It is not: for a row whose SalesRepID is NULL it
  becomes NULL = NULL, which is not true, and the row is silently dropped.
  10% of orders have no rep. Every search through this variant loses them.

  On the tested build it was also slower than the catch-all on two of the
  four searches.
==============================================================================*/
DECLARE @co bigint = (SELECT RowsFound FROM Demo.Calls WHERE Variant = 'Coalesce' AND Search = 'none');
DECLARE @ca bigint = (SELECT RowsFound FROM Demo.Calls WHERE Variant = 'CatchAll' AND Search = 'none');
DECLARE @d nvarchar(300) = N'no filter at all: COALESCE found ' + CAST(@co AS nvarchar(20)) + N' rows, the others '
    + CAST(@ca AS nvarchar(20));
INSERT Demo.Verdicts VALUES ('E. COALESCE', 'every argument NULL', @d, 'misses the rows where SalesRepID is NULL',
    CASE WHEN @co < @ca THEN 'WRONG ANSWER' ELSE 'unexpected' END);

-- And the four correct variants must agree on every search.
DECLARE @disagree int =
    (SELECT COUNT(*) FROM (SELECT Search FROM Demo.Calls WHERE Variant <> 'Coalesce'
                           GROUP BY Search HAVING MIN(RowsFound) <> MAX(RowsFound)) AS x);
SET @d = CAST(@disagree AS nvarchar(10)) + N' searches where CatchAll, Recompile, RecompileAssign and Dynamic disagree';
INSERT Demo.Verdicts VALUES ('E. COALESCE', 'the other four variants', @d, 'all agree',
    CASE WHEN @disagree = 0 THEN 'SAME ANSWERS' ELSE 'unexpected' END);
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. LOGICAL READS: variant x search ===';
GO
SELECT  Variant,
        Customer = MAX(CASE WHEN Search = 'customer' THEN LogicalReads END),
        [Date]   = MAX(CASE WHEN Search = 'date'     THEN LogicalReads END),
        Both     = MAX(CASE WHEN Search = 'both'     THEN LogicalReads END),
        [None]   = MAX(CASE WHEN Search = 'none'     THEN LogicalReads END)
FROM    Demo.Calls GROUP BY Variant
ORDER BY CASE Variant WHEN 'CatchAll' THEN 1 WHEN 'Recompile' THEN 2 WHEN 'RecompileAssign' THEN 3 WHEN 'Dynamic' THEN 4 ELSE 5 END;
GO

PRINT '';
PRINT '=== 2. EVERY CALL ===';
GO
SELECT Variant, Search, RowsFound, LogicalReads, CpuMs FROM Demo.Calls ORDER BY CallID;
GO

PRINT '';
PRINT '=== 3. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario;
GO

PRINT '';
PRINT '=== 4. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Detail, Verdict FROM Demo.Verdicts WHERE Verdict = 'unexpected';
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 4 should be EMPTY. Anything in it is a';
PRINT ' genuine difference on your build, worth reading before';
PRINT ' you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
