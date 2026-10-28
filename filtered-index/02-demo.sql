/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Filtered indexes: when the optimizer can use one, when it can't, and the
  writes that fail because of one.

     A  a literal value: the filtered index is used
     B  the filtered value as a parameter: local variable, sp_executesql,
        forced parameterization
     C  what works: a parameter on another column, OPTION (RECOMPILE)
     D  SET options: QUOTED_IDENTIFIER and ANSI_NULLS
     E  the filtered index's statistics, after its rows grew 20-fold

  WHAT THIS CHANGES: only FilteredDemo. It switches the database to forced
  parameterization and back, creates and drops one procedure, adds and
  deletes 10,000 orders, updates the filtered index's statistics, and clears
  this database's plan cache (ALTER DATABASE SCOPED CONFIGURATION CLEAR
  PROCEDURE_CACHE: this database's plans only).

  TESTED end to end on SQL Server 2025 RTM-CU10 (17.0.5035.5) and 2022
  RTM-CU25 (16.0.4255.1), Linux containers.
==============================================================================*/

USE FilteredDemo;
GO
SET NOCOUNT ON;
GO

TRUNCATE TABLE Demo.Results;
TRUNCATE TABLE Demo.Verdicts;
GO

-- Start from the state setup left, whatever a previous run did.
ALTER DATABASE CURRENT SET PARAMETERIZATION SIMPLE;
GO
DELETE Demo.Orders WHERE OrderID > 500000;
UPDATE STATISTICS Demo.Orders IX_Open WITH FULLSCAN;
ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;   -- this database's plans only
IF OBJECT_ID('Demo.p_AddOrder') IS NOT NULL DROP PROCEDURE Demo.p_AddOrder;
GO


/*==============================================================================
  A. One customer's open orders, with the values written in.
==============================================================================*/
PRINT '=== A. a literal value ===';
GO
DECLARE @r bigint, @u bit, @w bit,
        @pages bigint = (SELECT SUM(used_page_count) FROM sys.dm_db_partition_stats
                         WHERE object_id = OBJECT_ID('Demo.Orders') AND index_id = 1);
EXEC Demo.usp_Measure N'literal_',
     N'SELECT SUM(Amount) AS literal_ FROM Demo.Orders WHERE Status = 1 AND CustomerID = 42;',
     @r OUTPUT, @u OUTPUT, @w OUTPUT;

INSERT Demo.Results (Scenario, Item, Value) VALUES
('A', 'pages in the table (clustered index)',            CAST(@pages AS varchar(20))),
('A', 'WHERE Status = 1 AND CustomerID = 42: uses IX_Open', CASE @u WHEN 1 THEN 'yes' ELSE 'no' END),
('A', 'WHERE Status = 1 AND CustomerID = 42: logical reads', CAST(@r AS varchar(20)));

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('A', 'with the value written in, the plan seeks the filtered index',
 'IX_Open ' + CASE @u WHEN 1 THEN 'used' ELSE 'not used' END + ', ' + CAST(@r AS varchar(20)) + ' reads',
 CASE WHEN @u = 1 AND @r < 50 THEN 'CONFIRMED' ELSE 'unexpected' END);
GO


/*==============================================================================
  B. The same query, with the filtered column's value as a parameter. The
  plan has to be right for any value, and the index only holds Status = 1.
==============================================================================*/
PRINT '=== B. the filtered value as a parameter ===';
GO
DECLARE @r1 bigint, @u1 bit, @w1 bit, @r2 bigint, @u2 bit, @w2 bit;
EXEC Demo.usp_Measure N'localvar_',
     N'DECLARE @s tinyint = 1;
       SELECT SUM(Amount) AS localvar_ FROM Demo.Orders WHERE Status = @s AND CustomerID = 42;',
     @r1 OUTPUT, @u1 OUTPUT, @w1 OUTPUT;
EXEC Demo.usp_Measure N'param_',
     N'EXEC sys.sp_executesql
           N''SELECT SUM(Amount) AS param_ FROM Demo.Orders WHERE Status = @s AND CustomerID = 42;'',
           N''@s tinyint'', @s = 1;',
     @r2 OUTPUT, @u2 OUTPUT, @w2 OUTPUT;

INSERT Demo.Results (Scenario, Item, Value) VALUES
('B', 'local variable: uses IX_Open / UnmatchedIndexes warning / reads',
      CASE @u1 WHEN 1 THEN 'yes' ELSE 'no' END + ' / ' + CASE @w1 WHEN 1 THEN 'yes' ELSE 'no' END + ' / ' + CAST(@r1 AS varchar(20))),
('B', 'sp_executesql parameter: uses IX_Open / UnmatchedIndexes warning / reads',
      CASE @u2 WHEN 1 THEN 'yes' ELSE 'no' END + ' / ' + CASE @w2 WHEN 1 THEN 'yes' ELSE 'no' END + ' / ' + CAST(@r2 AS varchar(20)));

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('B', 'a local variable for Status: the filtered index is not used, and the plan says so (UnmatchedIndexes)',
 'IX_Open ' + CASE @u1 WHEN 1 THEN 'used' ELSE 'not used' END + ', warning ' + CASE @w1 WHEN 1 THEN 'yes' ELSE 'no' END + ', ' + CAST(@r1 AS varchar(20)) + ' reads',
 CASE WHEN @u1 = 0 AND @w1 = 1 AND @r1 > 10000 THEN 'CONFIRMED' ELSE 'unexpected' END),
('B', 'an sp_executesql parameter for Status: the same',
 'IX_Open ' + CASE @u2 WHEN 1 THEN 'used' ELSE 'not used' END + ', warning ' + CASE @w2 WHEN 1 THEN 'yes' ELSE 'no' END + ', ' + CAST(@r2 AS varchar(20)) + ' reads',
 CASE WHEN @u2 = 0 AND @w2 = 1 AND @r2 > 10000 THEN 'CONFIRMED' ELSE 'unexpected' END);
GO

-- Forced parameterization turns the literals of A into parameters.
-- Changing it clears this database's plan cache.
ALTER DATABASE CURRENT SET PARAMETERIZATION FORCED;
GO
DECLARE @r bigint, @u bit, @w bit;
EXEC Demo.usp_Measure N'forced_',
     N'SELECT SUM(Amount) AS forced_ FROM Demo.Orders WHERE Status = 1 AND CustomerID = 42;',
     @r OUTPUT, @u OUTPUT, @w OUTPUT;

INSERT Demo.Results (Scenario, Item, Value) VALUES
('B', 'query A under forced parameterization: uses IX_Open / UnmatchedIndexes warning / reads',
      CASE @u WHEN 1 THEN 'yes' ELSE 'no' END + ' / ' + CASE @w WHEN 1 THEN 'yes' ELSE 'no' END + ' / ' + CAST(@r AS varchar(20)));

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('B', 'forced parameterization makes query A''s literal a parameter: the filtered index is no longer used',
 'IX_Open ' + CASE @u WHEN 1 THEN 'used' ELSE 'not used' END + ', ' + CAST(@r AS varchar(20)) + ' reads',
 CASE WHEN @u = 0 AND @r > 10000 THEN 'CONFIRMED' ELSE 'unexpected' END);
GO
ALTER DATABASE CURRENT SET PARAMETERIZATION SIMPLE;
GO


/*==============================================================================
  C. What works: keep the filtered column's value in the text, and pass the
  other values as parameters; or compile for the actual value each time.
==============================================================================*/
PRINT '=== C. what works ===';
GO
DECLARE @r1 bigint, @u1 bit, @w1 bit, @r2 bigint, @u2 bit, @w2 bit;
EXEC Demo.usp_Measure N'other_',
     N'EXEC sys.sp_executesql
           N''SELECT SUM(Amount) AS other_ FROM Demo.Orders WHERE Status = 1 AND CustomerID = @c;'',
           N''@c int'', @c = 42;',
     @r1 OUTPUT, @u1 OUTPUT, @w1 OUTPUT;
EXEC Demo.usp_Measure N'recompile_',
     N'DECLARE @s tinyint = 1;
       SELECT SUM(Amount) AS recompile_ FROM Demo.Orders WHERE Status = @s AND CustomerID = 42 OPTION (RECOMPILE);',
     @r2 OUTPUT, @u2 OUTPUT, @w2 OUTPUT;

INSERT Demo.Results (Scenario, Item, Value) VALUES
('C', 'Status = 1 in the text, CustomerID as a parameter: uses IX_Open / reads',
      CASE @u1 WHEN 1 THEN 'yes' ELSE 'no' END + ' / ' + CAST(@r1 AS varchar(20))),
('C', 'local variable with OPTION (RECOMPILE): reads (not cached, so no plan to read)',
      CAST(@r2 AS varchar(20)));

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('C', 'a parameter on another column is fine: the filtered index is used',
 'IX_Open ' + CASE @u1 WHEN 1 THEN 'used' ELSE 'not used' END + ', ' + CAST(@r1 AS varchar(20)) + ' reads',
 CASE WHEN @u1 = 1 AND @r1 < 50 THEN 'CONFIRMED' ELSE 'unexpected' END),
('C', 'OPTION (RECOMPILE) compiles for the variable''s value: the reads drop from a scan''s to a few dozen',
 CAST(@r2 AS varchar(20)) + ' reads, compilation included',
 CASE WHEN @r2 < 1000 THEN 'CONFIRMED' ELSE 'unexpected' END);
GO


/*==============================================================================
  D. SET options. A filtered index needs QUOTED_IDENTIFIER and ANSI_NULLS
  ON (among others) for any change to its table, even rows outside the
  filter. Each test runs in dynamic SQL, so the setting reverts after it.
==============================================================================*/
PRINT '=== D. SET options ===';
GO
DECLARE @eQi int, @eAn int, @eProc int, @procQi int, @r bigint, @u bit, @w bit, @r0 bigint;

-- An insert of a closed order (outside the filter) with QUOTED_IDENTIFIER OFF.
EXEC Demo.usp_Try N'SET QUOTED_IDENTIFIER OFF;
     EXEC (N''INSERT Demo.Orders (OrderID, Status, CustomerID, Amount) VALUES (600001, 4, 1, 1);'');', @eQi OUTPUT;

-- An update with ANSI_NULLS OFF.
EXEC Demo.usp_Try N'SET ANSI_NULLS OFF;
     EXEC (N''UPDATE Demo.Orders SET Amount = Amount WHERE OrderID = 5;'');', @eAn OUTPUT;

-- A procedure created with QUOTED_IDENTIFIER OFF, as an old sqlcmd (without -I)
-- deploys it, then called from this session, where it's ON.
EXEC (N'SET QUOTED_IDENTIFIER OFF;
      EXEC (N''CREATE PROCEDURE Demo.p_AddOrder @id int AS
                  INSERT Demo.Orders (OrderID, Status, CustomerID, Amount) VALUES (@id, 4, 1, 1);'');');
SET @procQi = OBJECTPROPERTY(OBJECT_ID('Demo.p_AddOrder'), 'ExecIsQuotedIdentOn');
EXEC Demo.usp_Try N'EXEC Demo.p_AddOrder @id = 600002;', @eProc OUTPUT;

-- Query A with QUOTED_IDENTIFIER OFF: measured by reads only, because the
-- statement runs nested inside EXEC.
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
EXEC (N'SET QUOTED_IDENTIFIER OFF;
      EXEC (N''DECLARE @t bigint; SELECT @t = SUM(Amount) FROM Demo.Orders WHERE Status = 1 AND CustomerID = 42;'');');
SELECT @r = logical_reads - @r0 FROM sys.dm_exec_requests WHERE session_id = @@SPID;

INSERT Demo.Results (Scenario, Item, Value) VALUES
('D', 'INSERT a closed order, QUOTED_IDENTIFIER OFF',     CASE @eQi WHEN 0 THEN 'succeeded' ELSE 'error ' + CAST(@eQi AS varchar(10)) END),
('D', 'UPDATE an order, ANSI_NULLS OFF',                  CASE @eAn WHEN 0 THEN 'succeeded' ELSE 'error ' + CAST(@eAn AS varchar(10)) END),
('D', 'Demo.p_AddOrder: created with QUOTED_IDENTIFIER',  CASE @procQi WHEN 1 THEN 'ON' ELSE 'OFF' END),
('D', 'EXEC Demo.p_AddOrder from a session with it ON',   CASE @eProc WHEN 0 THEN 'succeeded' ELSE 'error ' + CAST(@eProc AS varchar(10)) END),
('D', 'query A with QUOTED_IDENTIFIER OFF: logical reads', CAST(@r AS varchar(20)));

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('D', 'with QUOTED_IDENTIFIER or ANSI_NULLS OFF, writes to the table fail with error 1934, even rows outside the filter',
 'insert: ' + CASE @eQi WHEN 0 THEN 'succeeded' ELSE 'error ' + CAST(@eQi AS varchar(10)) END
 + '; update: ' + CASE @eAn WHEN 0 THEN 'succeeded' ELSE 'error ' + CAST(@eAn AS varchar(10)) END,
 CASE WHEN @eQi = 1934 AND @eAn = 1934 THEN 'CONFIRMED' ELSE 'unexpected' END),
('D', 'a procedure keeps the QUOTED_IDENTIFIER it was created with: it fails even when the caller has it ON',
 'created ' + CASE @procQi WHEN 1 THEN 'ON' ELSE 'OFF' END + ', call: '
 + CASE @eProc WHEN 0 THEN 'succeeded' ELSE 'error ' + CAST(@eProc AS varchar(10)) END,
 CASE WHEN @procQi = 0 AND @eProc = 1934 THEN 'CONFIRMED' ELSE 'unexpected' END),
('D', 'reads with QUOTED_IDENTIFIER OFF can''t use the filtered index: query A scans',
 CAST(@r AS varchar(20)) + ' reads',
 CASE WHEN @r > 10000 THEN 'CONFIRMED' ELSE 'unexpected' END);

DROP PROCEDURE Demo.p_AddOrder;
GO


/*==============================================================================
  E. 10,000 new open orders for customer 42: the filtered index goes from
  500 rows to 10,500. Are its statistics updated?
==============================================================================*/
PRINT '=== E. statistics on a filtered index ===';
GO
;WITH n AS
(
    SELECT TOP (10000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.Orders (OrderID, Status, CustomerID, Amount)
SELECT 600000 + rn, 1, 42, 1 FROM n;
GO
DECLARE @r bigint, @u bit, @w bit, @est float, @actual int, @statRows bigint, @mods bigint, @after float;

EXEC Demo.usp_Measure N'stale_',
     N'SELECT SUM(Amount) AS stale_ FROM Demo.Orders WHERE Status = 1 AND CustomerID = 42;',
     @r OUTPUT, @u OUTPUT, @w OUTPUT;

SELECT @actual = COUNT(*) FROM Demo.Orders WHERE Status = 1 AND CustomerID = 42;
SELECT @statRows = sp.rows, @mods = sp.modification_counter
FROM   sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE  s.object_id = OBJECT_ID('Demo.Orders') AND s.name = 'IX_Open';

;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT TOP (1) @est = qp.query_plan.value('(//RelOp[IndexScan/Object/@Index="[IX_Open]"]/@EstimateRows)[1]', 'float')
FROM   sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE  st.text LIKE N'%AS stale_ %' AND st.text NOT LIKE N'%sp_executesql%' AND st.text NOT LIKE N'%dm_exec_query_stats%';

UPDATE STATISTICS Demo.Orders IX_Open;

EXEC Demo.usp_Measure N'fresh_',
     N'SELECT SUM(Amount) AS fresh_ FROM Demo.Orders WHERE Status = 1 AND CustomerID = 42;',
     @r OUTPUT, @u OUTPUT, @w OUTPUT;
;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT TOP (1) @after = qp.query_plan.value('(//RelOp[IndexScan/Object/@Index="[IX_Open]"]/@EstimateRows)[1]', 'float')
FROM   sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE  st.text LIKE N'%AS fresh_ %' AND st.text NOT LIKE N'%sp_executesql%' AND st.text NOT LIKE N'%dm_exec_query_stats%';

INSERT Demo.Results (Scenario, Item, Value) VALUES
('E', 'IX_Open statistics: rows / modifications since the update', CAST(@statRows AS varchar(20)) + ' / ' + CAST(@mods AS varchar(20))),
('E', 'open orders for customer 42, actual',                      CAST(@actual AS varchar(20))),
('E', 'estimated rows from IX_Open, before UPDATE STATISTICS',    CAST(@est AS varchar(20))),
('E', 'estimated rows from IX_Open, after UPDATE STATISTICS',     CAST(@after AS varchar(20)));

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('E', 'the filtered index''s rows grew 20-fold, and its statistics were not updated automatically',
 CAST(@statRows AS varchar(20)) + ' rows in the statistics, ' + CAST(@mods AS varchar(20)) + ' modifications',
 CASE WHEN @statRows = 500 AND @mods >= 10000 THEN 'CONFIRMED' ELSE 'unexpected' END),
('E', 'the estimate for customer 42 (10,000 rows): it depends on which other statistics the optimizer combines, so it is reported, not judged',
 'before UPDATE STATISTICS ' + ISNULL(CAST(@est AS varchar(20)), 'n/a') + ', after ' + ISNULL(CAST(@after AS varchar(20)), 'n/a'),
 'INFO');
GO

-- Back to setup's state.
DELETE Demo.Orders WHERE OrderID > 500000;
UPDATE STATISTICS Demo.Orders IX_Open WITH FULLSCAN;
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
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
