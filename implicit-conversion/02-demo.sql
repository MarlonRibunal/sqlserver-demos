/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  Every query this demo runs is a row in Demo.Cases. Each scenario runs its
  cases through Demo.usp_RunCase, which records the operator that read
  Demo.Customers, its estimate, the logical reads, and which conversion
  warnings the plan carried. The summary at the bottom is the payoff.

  Scenarios
    A  varchar column, nvarchar value     -> SQL collation: index SCAN.
                                             Windows collation: SEEK.
    B  nvarchar column, varchar value     -> seek. The value is converted,
                                             not the column.
    C  other type pairs                   -> int/bigint, int/decimal,
                                             int/varchar, date/datetime all
                                             seek; varchar column vs int
                                             value fails at run time
    D  warnings                           -> a warning that costs nothing,
                                             and a costly conversion that
                                             raises none
    E  joins                              -> the same mismatch between two
                                             columns
    F  finding them in your own cache     -> a query you can run on your
                                             own instance

  Expected runtime: a few seconds.

  Nothing here flushes the plan cache. Cases are identified by a marker
  comment in their text, so earlier runs of the same case do not interfere.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers,
  MAXDOP 0, cost threshold for parallelism 5.
==============================================================================*/

USE ImplicitConversionDemo;
GO
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;   -- XML methods below; sqlcmd defaults it OFF
GO

IF OBJECT_ID('Demo.usp_RunCase') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

TRUNCATE TABLE Demo.CaseResults;
TRUNCATE TABLE Demo.DemoResults;
GO


/*==============================================================================
  SCENARIO A -- varchar column, nvarchar value

  The classic. CodeSql is varchar; the application sends nvarchar, as most
  drivers do for a string unless told otherwise. nvarchar has the higher data
  type precedence, so it is the COLUMN that gets converted -- and whether that
  costs a scan depends on the column's collation.

     A0  varchar = varchar            the control
     A1  SQL collation, nvarchar      CONVERT_IMPLICIT on the column: SCAN
     A2  same, written as N'...'      same scan; no parameter needed
     A3  Windows collation, nvarchar  SEEK, via GetRangeThroughConvert
     A4  same, a 50,000-row value     still a seek, estimate still exact

  Why the collations differ: under a Windows collation, varchar and nvarchar
  sort by the same rules, so the optimizer can turn the nvarchar value into a
  range of varchar values and seek on it. A SQL collation sorts varchar and
  nvarchar data by DIFFERENT rules, so no such range exists, and every row's
  value has to be converted and compared.

  What to look for:
    - A1 and A2 read the whole index (thousands of pages) to find one row
    - A3 reads what A0 reads, and raises no warning at all
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO A: varchar column, nvarchar value ---';
GO

EXEC Demo.usp_RunCase 'A0';
EXEC Demo.usp_RunCase 'A1';
EXEC Demo.usp_RunCase 'A2';
EXEC Demo.usp_RunCase 'A3';
EXEC Demo.usp_RunCase 'A4';
GO


/*==============================================================================
  SCENARIO B -- nvarchar column, varchar value

  The same two types, the other way round. nvarchar still wins on precedence,
  but now the nvarchar side is the column -- so it is the VALUE that gets
  converted, once, before the seek. The column is untouched and the index
  works normally, whatever the collation.

  This is why "make the parameter match the column" is the fix, and "make
  everything nvarchar" is a fix too: converting the value is free.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO B: nvarchar column, varchar value ---';
GO

EXEC Demo.usp_RunCase 'B1';
EXEC Demo.usp_RunCase 'B2';
GO


/*==============================================================================
  SCENARIO C -- other type pairs

  The folklore says any mismatch costs a scan. For the common numeric and
  date pairs, the optimizer converts the value or seeks through a dynamic
  range, and the index is used normally:

     C1  int column,  bigint value        seek
     C2  int column,  decimal(10,0) value seek
     C3  int column,  varchar value       seek -- the VALUE becomes int
     C4  date column, datetime value      seek

  And one that is worse than a scan:

     C5  varchar column, int value        int outranks varchar, so every
                                          code in the column is converted to
                                          int -- and the first one that is
                                          not a number stops the query with
                                          Msg 245. On a column where every
                                          value happens to be numeric, the
                                          same query runs, scans, and returns
                                          the right answer, until the day
                                          someone inserts 'N/A'.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO C: other type pairs ---';
GO

EXEC Demo.usp_RunCase 'C1';
EXEC Demo.usp_RunCase 'C2';
EXEC Demo.usp_RunCase 'C3';
EXEC Demo.usp_RunCase 'C4';
EXEC Demo.usp_RunCase 'C5';
GO


/*==============================================================================
  SCENARIO D -- the warning is not the cost

  Execution plans flag conversions with a PlanAffectingConvert warning, and
  it comes in two kinds:

     ConvertIssue="Seek Plan"             the conversion prevented a seek.
                                          This is the expensive one.
     ConvertIssue="Cardinality Estimate"  the conversion MIGHT affect an
                                          estimate. Raised for a CONVERT in
                                          the SELECT list, which cannot
                                          affect anything.

  D1 is a ten-row clustered index seek with a CONVERT in its SELECT list. It
  carries a warning and reads a couple of dozen pages.

  The verdict rows below line the two up against scenario A: the cheap query
  that carries a warning, and the expensive conversion that does not appear
  at all because, under a Windows collation, it was never expensive.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO D: warnings ---';
GO

EXEC Demo.usp_RunCase 'D1';
GO

DECLARE @d1Warn bit, @d1Reads bigint, @a3Warn bit, @a3Through bit, @a1Warn bit;
SELECT @d1Warn = CardEstWarning, @d1Reads = LogicalReads FROM Demo.CaseResults WHERE Marker = 'D1';
SELECT @a3Warn = CASE WHEN SeekPlanWarning = 1 OR CardEstWarning = 1 THEN 1 ELSE 0 END,
       @a3Through = ThroughConvert
FROM   Demo.CaseResults WHERE Marker = 'A3';
SELECT @a1Warn = SeekPlanWarning FROM Demo.CaseResults WHERE Marker = 'A1';

DECLARE @v1 varchar(24) = CASE WHEN @d1Warn = 1 AND @d1Reads < 100 THEN 'WARNING, NO COST' ELSE 'unexpected' END;
DECLARE @v2 varchar(24) = CASE WHEN @a3Warn = 0 AND @a3Through = 1 THEN 'CONVERTED, NO WARNING' ELSE 'unexpected' END;
DECLARE @v3 varchar(24) = CASE WHEN @a1Warn = 1 THEN 'SEEK PLAN WARNING' ELSE 'unexpected' END;

EXEC Demo.usp_Record 'D. Warnings', 1, 'D1: CONVERT in SELECT list', 'logical reads', @d1Reads,
     N'ConvertIssue="Cardinality Estimate"', 'warning raised; query costs nothing', @v1;
EXEC Demo.usp_Record 'D. Warnings', 2, 'A3: Windows collation, nvarchar value', NULL, NULL,
     N'GetRangeThroughConvert, no PlanAffectingConvert', 'converted, seeks, and is not flagged', @v2;
EXEC Demo.usp_Record 'D. Warnings', 3, 'A1: SQL collation, nvarchar value', NULL, NULL,
     N'ConvertIssue="Seek Plan"', 'the warning worth acting on', @v3;
GO


/*==============================================================================
  SCENARIO E -- joins: the mismatch between two columns

  The same problem, with no application parameter involved at all. Orders
  stores the customer code as nvarchar; Customers.CodeSql is varchar under a
  SQL collation. The join converts the varchar side, so it cannot seek into
  IX_Customers_CodeSql for each order -- it scans the whole index and
  hash-joins instead.

     E0  nvarchar = nvarchar     the control: nested loops, one seek per order
     E1  nvarchar = varchar      scan of every customer code, for 20 orders

  This is the one to look for in schemas that grew over time: two tables
  holding the same key with different types, joined in every report.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO E: joins ---';
GO

EXEC Demo.usp_RunCase 'E0';
EXEC Demo.usp_RunCase 'E1';
GO


/*==============================================================================
  SCENARIO F -- finding them in your own plan cache

  The query below is the useful thing to take away. It searches every cached
  plan for a PlanAffectingConvert warning of the expensive kind,
  ConvertIssue="Seek Plan", and returns the statement and the offending
  expression.

  Here it is scoped to this database by the dbid attribute of each PLAN,
  from sys.dm_exec_plan_attributes. Not by sys.dm_exec_sql_text.dbid, the
  obvious choice: that column is NULL for ad hoc statements and for anything
  sent through sp_executesql -- which is to say, for nearly every query an
  application sends. Filter on it and this search returns nothing, cleanly,
  with no error. On your own instance, drop the dbid line to search
  everything -- but be aware that
  shredding the XML of every cached plan is expensive on a large plan cache. Run
  it off-peak, or add a TOP and an ORDER BY on total_worker_time to look at
  the costliest plans first.

  The scenario checks that it finds exactly the three scanning cases (A1, A2,
  E1) and none of the others.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO F: finding them in the plan cache ---';
GO

DECLARE @found TABLE (Marker varchar(4), Expression nvarchar(400), ExecCount bigint, AvgReads bigint);

;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
INSERT @found (Marker, Expression, ExecCount, AvgReads)
SELECT  Marker     = SUBSTRING(st.text, CHARINDEX('/*', st.text) + 2, 2),
        Expression = w.n.value('@Expression', 'nvarchar(400)'),
        qs.execution_count,
        qs.total_logical_reads / NULLIF(qs.execution_count, 0)
FROM    sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
CROSS APPLY qp.query_plan.nodes('//PlanAffectingConvert[@ConvertIssue="Seek Plan"]') AS w(n)
CROSS APPLY (SELECT dbid = CAST(pa.value AS int)
             FROM   sys.dm_exec_plan_attributes(qs.plan_handle) AS pa
             WHERE  pa.attribute = 'dbid') AS pdb
WHERE   pdb.dbid = DB_ID()                  -- drop this line to search the whole instance
  AND   st.text NOT LIKE N'%sp_executesql%'
  AND   st.text NOT LIKE N'%Demo.Cases%';

-- What the search returned, verbatim.
SELECT Marker, Expression, ExecCount, AvgReads FROM @found ORDER BY Marker;

DECLARE @list nvarchar(200) = N'';
SELECT @list = @list + CASE WHEN @list = N'' THEN N'' ELSE N', ' END + Marker
FROM   (SELECT DISTINCT Marker FROM @found) AS d
ORDER BY Marker;

DECLARE @verdict varchar(24) = CASE WHEN @list = N'A1, A2, E1' THEN 'FOUND ALL, NO NOISE' ELSE 'unexpected' END;

EXEC Demo.usp_Record 'F. Plan cache search', 1, 'cases with a Seek Plan conversion warning', NULL, NULL,
     @list, 'A1, A2, E1', @verdict;
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. EVERY CASE: what the conversion did ===';
GO
SELECT  c.Marker,
        c.Label,
        r.AccessOp,
        Estimate      = r.EstimateRows,
        TrueRows      = r.ActualRows,
        r.LogicalReads,
        SeekPlanWarn  = r.SeekPlanWarning,
        CardEstWarn   = r.CardEstWarning,
        ThroughConvert = r.ThroughConvert,
        Expected      = c.ExpectedOp,
        r.Verdict
FROM    Demo.Cases       AS c
JOIN    Demo.CaseResults AS r ON r.Marker = c.Marker
ORDER BY c.Marker;
GO

PRINT '';
PRINT '=== 2. THE COST: reads against each control ===';
GO
SELECT  r.Marker,
        c.Label,
        r.LogicalReads,
        ControlReads = k.LogicalReads,
        TimesControl = CAST(r.LogicalReads * 1.0 / NULLIF(k.LogicalReads, 0) AS decimal(10,1))
FROM    Demo.CaseResults AS r
JOIN    Demo.Cases       AS c ON c.Marker = r.Marker
JOIN    Demo.CaseResults AS k ON k.Marker = CASE WHEN r.Marker LIKE 'E%' THEN 'E0' ELSE 'A0' END
WHERE   r.Marker IN ('A1', 'A2', 'A3', 'B1', 'C1', 'C2', 'C3', 'E1')
ORDER BY r.Marker;
GO

PRINT '';
PRINT '=== 3. SCENARIO C5: the conversion that fails ===';
GO
SELECT Marker, ErrorText, Verdict FROM Demo.CaseResults WHERE Marker = 'C5';
GO

PRINT '';
PRINT '=== 4. SCENARIOS D and F: warnings, and finding them ===';
GO
SELECT Scenario, StepNo, Item, Detail = TextValue, Expected, Verdict
FROM   Demo.DemoResults ORDER BY ResultID;
GO

PRINT '';
PRINT '=== 5. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Source = 'case', Marker, Detail = COALESCE(ErrorText, AccessOp), Verdict
FROM   Demo.CaseResults
WHERE  Verdict IN ('unexpected', 'NO PLAN FOUND')
UNION ALL
SELECT 'verdict', CAST(StepNo AS varchar(4)), TextValue, Verdict
FROM   Demo.DemoResults
WHERE  Verdict = 'unexpected';
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 5 should be EMPTY. Anything in it is either';
PRINT ' a genuine difference on your build, or a collation the';
PRINT ' scenario did not expect -- both are worth reading';
PRINT ' before you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
