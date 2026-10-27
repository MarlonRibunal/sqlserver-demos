/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  The ABORT_QUERY_EXECUTION Query Store hint, SQL Server 2025: block one
  query from running, without changing the code that sends it.

     A  block the runaway query: it fails, everything else runs
     B  what counts as "the same query"
     C  a blocked query inside a transaction
     D  removing the block, and setting it again
     E  Query Store READ_ONLY, and OFF

  On SQL Server 2022 and earlier every scenario reports SKIPPED.

  WHAT THIS CHANGES: only AbortDemo. It sets and clears a Query Store hint,
  switches Query Store to READ_ONLY, OFF and back to READ_WRITE, and clears
  AbortDemo's plan cache (this database's plans only). It leaves Query Store
  on, in READ_WRITE, with no hints.

  TESTED end to end on SQL Server 2025 RTM-CU9-GDR (17.0.5015.4), Linux
  container.
==============================================================================*/

USE AbortDemo;
GO
SET NOCOUNT ON;
GO

TRUNCATE TABLE Demo.Results;
TRUNCATE TABLE Demo.Verdicts;
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) < 17
    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'ABORT_QUERY_EXECUTION: block one query',  'needs SQL Server 2025 or later', 'SKIPPED'),
    ('B', 'ABORT_QUERY_EXECUTION: the same query',   'needs SQL Server 2025 or later', 'SKIPPED'),
    ('C', 'ABORT_QUERY_EXECUTION: transactions',     'needs SQL Server 2025 or later', 'SKIPPED'),
    ('D', 'ABORT_QUERY_EXECUTION: removing it',      'needs SQL Server 2025 or later', 'SKIPPED'),
    ('E', 'ABORT_QUERY_EXECUTION: Query Store state','needs SQL Server 2025 or later', 'SKIPPED');
GO

-- Start clean: Query Store on and read-write, no hints left by a previous
-- run, an empty plan cache for this database, and the runaway query run
-- once so Query Store has it.
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    EXEC (N'ALTER DATABASE CURRENT SET QUERY_STORE = ON;');
    EXEC (N'ALTER DATABASE CURRENT SET QUERY_STORE (OPERATION_MODE = READ_WRITE);');
    DECLARE @q bigint;
    DECLARE h CURSOR LOCAL FAST_FORWARD FOR SELECT query_id FROM sys.query_store_query_hints;
    OPEN h;
    FETCH NEXT FROM h INTO @q;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC sys.sp_query_store_clear_hints @query_id = @q;
        FETCH NEXT FROM h INTO @q;
    END
    CLOSE h; DEALLOCATE h;
    ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
    DECLARE @e int;
    EXEC Demo.usp_Try N'EXEC Demo.p_Runaway;', @e OUTPUT;
    EXEC Demo.usp_Try N'EXEC Demo.p_Other;',   @e OUTPUT;
END
GO


/*==============================================================================
  A. Block the runaway query.
==============================================================================*/
PRINT '=== A. block one query ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @q bigint, @eRun int, @eOther int;
    EXEC Demo.usp_QueryID @q OUTPUT;
    EXEC sys.sp_query_store_set_hints @query_id = @q,
         @query_hints = N'OPTION (USE HINT (''ABORT_QUERY_EXECUTION''))';

    EXEC Demo.usp_Try N'EXEC Demo.p_Runaway;', @eRun OUTPUT;
    EXEC Demo.usp_Try N'EXEC Demo.p_Other;',   @eOther OUTPUT;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('A', 'query_id of the runaway query',           CAST(@q AS varchar(20))),
    ('A', 'EXEC Demo.p_Runaway, hint set',           CASE @eRun WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eRun AS varchar(10)) END),
    ('A', 'EXEC Demo.p_Other',                       CASE @eOther WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eOther AS varchar(10)) END);

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'the blocked query fails with error 8778; other queries run',
     'p_Runaway ' + CASE @eRun WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eRun AS varchar(10)) END
     + ', p_Other ' + CASE @eOther WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@eOther AS varchar(10)) END,
     CASE WHEN @eRun = 8778 AND @eOther = 0 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  B. The same SELECT, character for character, sent as an ad hoc batch
  instead of from the procedure.
==============================================================================*/
PRINT '=== B. what counts as the same query ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @e int;
    EXEC Demo.usp_Try N'SELECT COUNT_BIG(*) AS Combinations
    FROM   Demo.Items AS a CROSS JOIN Demo.Items AS b;', @e OUTPUT;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('B', 'the same SELECT, ad hoc', CASE @e WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e AS varchar(10)) END);

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('B', 'the block is on one query_id: the same text outside the procedure still runs',
     CASE @e WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e AS varchar(10)) END,
     CASE WHEN @e = 0 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  C. The blocked query inside a transaction, after an update, with
  XACT_ABORT OFF and ON. What state is the transaction in afterwards?
==============================================================================*/
PRINT '=== C. inside a transaction ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    -- A plain EXEC, not INSERT ... EXEC: an error inside INSERT ... EXEC
    -- dooms the transaction by itself, whatever the hint does.
    DECLARE @stateOff int, @stateOn int;

    SET XACT_ABORT OFF;
    BEGIN TRAN;
        UPDATE Demo.Items SET Qty = 2 WHERE ItemID = 1;
        BEGIN TRY
            EXEC Demo.p_Runaway;
        END TRY
        BEGIN CATCH
            SET @stateOff = XACT_STATE();
        END CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;

    SET XACT_ABORT ON;
    BEGIN TRAN;
        UPDATE Demo.Items SET Qty = 2 WHERE ItemID = 1;
        BEGIN TRY
            EXEC Demo.p_Runaway;
        END TRY
        BEGIN CATCH
            SET @stateOn = XACT_STATE();
        END CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SET XACT_ABORT OFF;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('C', 'XACT_STATE() after the abort, XACT_ABORT OFF', CAST(@stateOff AS varchar(5))),
    ('C', 'XACT_STATE() after the abort, XACT_ABORT ON',  CAST(@stateOn AS varchar(5)));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('C', 'the abort dooms the transaction, even with XACT_ABORT OFF: the work before it can only be rolled back',
     'XACT_STATE() ' + CAST(@stateOff AS varchar(5)) + ' with XACT_ABORT OFF, ' + CAST(@stateOn AS varchar(5)) + ' with it ON',
     CASE WHEN @stateOff = -1 AND @stateOn = -1 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  D. Remove the block, and put it back for E.
==============================================================================*/
PRINT '=== D. removing the block ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @q bigint, @e int, @back int;
    EXEC Demo.usp_QueryID @q OUTPUT;
    EXEC sys.sp_query_store_clear_hints @query_id = @q;
    EXEC Demo.usp_Try N'EXEC Demo.p_Runaway;', @e OUTPUT;
    EXEC sys.sp_query_store_set_hints @query_id = @q,
         @query_hints = N'OPTION (USE HINT (''ABORT_QUERY_EXECUTION''))';
    EXEC Demo.usp_Try N'EXEC Demo.p_Runaway;', @back OUTPUT;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('D', 'EXEC Demo.p_Runaway, after sp_query_store_clear_hints', CASE @e WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e AS varchar(10)) END),
    ('D', 'EXEC Demo.p_Runaway, hint set again',  CASE @back WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@back AS varchar(10)) END);

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('D', 'sp_query_store_clear_hints lifts the block at once, and setting it again restores it, with no cache clear',
     'cleared: ' + CASE @e WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e AS varchar(10)) END
     + '; set again: ' + CASE @back WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@back AS varchar(10)) END,
     CASE WHEN @e = 0 AND @back = 8778 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  E. Query Store READ_ONLY, then OFF. Each change is a batch of its own.
  Last, because turning Query Store back on is the start of the next run.
==============================================================================*/
PRINT '=== E. Query Store READ_ONLY and OFF ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
    EXEC (N'ALTER DATABASE CURRENT SET QUERY_STORE (OPERATION_MODE = READ_ONLY);');
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @e int;
    ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
    EXEC Demo.usp_Try N'EXEC Demo.p_Runaway;', @e OUTPUT;
    INSERT Demo.Results (Scenario, Item, Value)
    VALUES ('E', 'EXEC Demo.p_Runaway, Query Store READ_ONLY', CASE @e WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e AS varchar(10)) END);
    EXEC (N'ALTER DATABASE CURRENT SET QUERY_STORE = OFF;');
END
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @e int;
    ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;
    EXEC Demo.usp_Try N'EXEC Demo.p_Runaway;', @e OUTPUT;
    INSERT Demo.Results (Scenario, Item, Value)
    VALUES ('E', 'EXEC Demo.p_Runaway, Query Store OFF', CASE @e WHEN 0 THEN 'ran' ELSE 'error ' + CAST(@e AS varchar(10)) END);

    DECLARE @ro varchar(40) = (SELECT Value FROM Demo.Results WHERE Item = 'EXEC Demo.p_Runaway, Query Store READ_ONLY'),
            @off varchar(40) = (SELECT Value FROM Demo.Results WHERE Item = 'EXEC Demo.p_Runaway, Query Store OFF');
    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('E', 'Query Store READ_ONLY still enforces the block',
     @ro, CASE WHEN @ro = 'error 8778' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('E', 'Query Store OFF lifts it: the query runs',
     @off, CASE WHEN @off = 'ran' THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    EXEC (N'ALTER DATABASE CURRENT SET QUERY_STORE = ON;');
    EXEC (N'ALTER DATABASE CURRENT SET QUERY_STORE (OPERATION_MODE = READ_WRITE);');
END
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
PRINT ' Result set 3 should be EMPTY on SQL Server 2025 and';
PRINT ' later. On 2022 and earlier it lists every scenario as';
PRINT ' SKIPPED. Anything else in it is a genuine difference';
PRINT ' on your build, worth reading before you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
