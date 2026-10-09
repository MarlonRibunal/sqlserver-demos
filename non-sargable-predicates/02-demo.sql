/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  Every query this demo runs is a row in Demo.Cases. Most come in pairs: a
  predicate with the column wrapped in a function (suffix x) and its rewrite
  with the column left bare (suffix o). Demo.usp_RunCase records the operator,
  the index, the estimate, the logical reads, and the answer each returned.

  Scenarios
    A  dates          -> YEAR(), CONVERT(), DATEADD(), DATEDIFF() on the column
                         scan. CAST(col AS date) seeks -- but loses the estimate.
    B  NULL handling  -> ISNULL(col, 0) = 0 scans; the OR IS NULL rewrite seeks
    C  strings        -> LEFT(), LTRIM(RTRIM()), UPPER() scan. A leading
                         wildcard SEEKS in the plan and reads the whole index.
    D  arithmetic     -> move the arithmetic to the other side
    E  no rewrite     -> an indexed computed column lets YEAR() seek unchanged

  Every pair is also checked for returning the SAME COUNT. A rewrite that
  changes the answer is a bug, not an optimization.

  Expected runtime: a few seconds. Nothing here flushes the plan cache.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers,
  MAXDOP 0, cost threshold for parallelism 5.
==============================================================================*/

USE SargabilityDemo;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;   -- XML methods in the harness; sqlcmd defaults it OFF
GO

IF OBJECT_ID('Demo.usp_RunCase') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

TRUNCATE TABLE Demo.CaseResults;
GO


/*==============================================================================
  RUN EVERY CASE

  The scenarios are told in the summary; the cases themselves are all the
  same shape, so they run in one loop. Each one is a COUNT, covered by the
  index on the column it filters, so the only question each answers is: did
  the predicate let the optimizer seek, or did it have to read every entry?
==============================================================================*/
PRINT '';
PRINT '--- running every case ---';
GO

DECLARE @id varchar(4);
DECLARE cases CURSOR LOCAL FAST_FORWARD FOR SELECT CaseID FROM Demo.Cases ORDER BY CaseID;
OPEN cases;
FETCH NEXT FROM cases INTO @id;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC Demo.usp_RunCase @id;
    FETCH NEXT FROM cases INTO @id;
END
CLOSE cases;
DEALLOCATE cases;
GO


/*==============================================================================
  THE CHECKS THAT GO BEYOND THE OPERATOR

  1. Same answer. Every x case must return the same count as its rewrite.
     ISNULL(Discount, 0) = 0 and (Discount = 0 OR Discount IS NULL) are only
     interchangeable if they really match the same 710,000 rows.

  2. C2x, the leading wildcard. With a parameter, LIKE '%' + @p compiles to
     an Index Seek whose range is worked out at run time -- and a pattern that
     starts with % has no range, so the "seek" covers the whole index. The
     check compares its reads with C1x, a plain scan of the same index.

  3. A3x, CAST(EventTime AS date). It seeks, which is the famous exception.
     The check records what the folklore leaves out: its estimate.
==============================================================================*/
-- 1. Same answer.
UPDATE r
SET    Verdict = 'unexpected'
FROM   Demo.CaseResults AS r
JOIN   Demo.Cases       AS c ON c.CaseID = r.CaseID
JOIN   Demo.CaseResults AS p ON p.CaseID = c.PairWith
WHERE  r.CountReturned <> p.CountReturned;

-- 2. The seek that reads everything.
DECLARE @c2Reads bigint = (SELECT LogicalReads FROM Demo.CaseResults WHERE CaseID = 'C2x');
DECLARE @c2Op    varchar(40) = (SELECT AccessOp FROM Demo.CaseResults WHERE CaseID = 'C2x');
DECLARE @scanReads bigint = (SELECT LogicalReads FROM Demo.CaseResults WHERE CaseID = 'C1x');

UPDATE Demo.CaseResults
SET    Verdict = CASE WHEN @c2Op = 'Index Seek' AND @c2Reads >= @scanReads * 0.9
                      THEN 'SEEK THAT SCANS' ELSE 'unexpected' END
WHERE  CaseID = 'C2x';

-- 3. The seek that lost its estimate.
UPDATE r
SET    Verdict = CASE WHEN r.AccessOp = 'Index Seek' AND r.EstimateRows < r.CountReturned * 0.5
                      THEN 'SEEKS, ESTIMATE LOST'
                      WHEN r.AccessOp = 'Index Seek' THEN 'SEEKS, ESTIMATE KEPT'
                      ELSE 'unexpected' END
FROM   Demo.CaseResults AS r
WHERE  r.CaseID = 'A3x';
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. EACH WRAPPED PREDICATE AGAINST ITS REWRITE ===';
GO
SELECT  c.Scenario,
        c.CaseID,
        Predicate     = c.Label,
        r.AccessOp,
        r.LogicalReads,
        RewriteReads  = p.LogicalReads,
        TimesRewrite  = CAST(r.LogicalReads * 1.0 / NULLIF(p.LogicalReads, 0) AS decimal(10,1)),
        Estimate      = r.EstimateRows,
        Answer        = r.CountReturned,
        SameAnswer    = CASE WHEN p.CaseID IS NULL THEN '-'
                             WHEN r.CountReturned = p.CountReturned THEN 'yes' ELSE 'NO' END,
        r.Verdict
FROM    Demo.Cases       AS c
JOIN    Demo.CaseResults AS r ON r.CaseID = c.CaseID
LEFT JOIN Demo.CaseResults AS p ON p.CaseID = c.PairWith
WHERE   c.CaseID LIKE '%x'
ORDER BY c.CaseID;
GO

PRINT '';
PRINT '=== 2. THE REWRITES ===';
GO
SELECT  c.Scenario, c.CaseID, Predicate = c.Label, r.AccessOp, r.IndexName,
        r.LogicalReads, Estimate = r.EstimateRows, Answer = r.CountReturned, r.Verdict
FROM    Demo.Cases       AS c
JOIN    Demo.CaseResults AS r ON r.CaseID = c.CaseID
WHERE   c.CaseID LIKE '%o'
ORDER BY c.CaseID;
GO

PRINT '';
PRINT '=== 3. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT r.CaseID, c.Label, r.AccessOp, r.LogicalReads, r.CountReturned, r.Verdict
FROM   Demo.CaseResults AS r
JOIN   Demo.Cases       AS c ON c.CaseID = r.CaseID
WHERE  r.Verdict IN ('unexpected', 'NO PLAN FOUND');
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 3 should be EMPTY. Anything in it is either';
PRINT ' a genuine difference on your build, or a rewrite that';
PRINT ' did not return the same answer -- both are worth';
PRINT ' reading before you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
