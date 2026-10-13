/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Three SQL Server 2022 features that change a plan on their own, and how to
  see that they did:

     A  parameter-sensitive plan (PSP) optimization: one statement, more
        than one cached plan, chosen by the parameter's value
     B  cardinality estimation (CE) feedback: after enough executions, the
        engine attaches a Query Store hint to the query by itself
     C  memory grant feedback, kept in Query Store: a corrected grant
        survives the plan leaving the cache (and doesn't, with persistence
        turned off)

  On SQL Server 2019 and earlier every scenario reports SKIPPED.

  WHAT THIS CHANGES: only IqpDemo. It restarts IqpDemo (OFFLINE, then
  ONLINE: anyone else connected to it is disconnected), clears its Query
  Store and its plan cache (ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE:
  this database's plans only), moves its compatibility level between 150
  and 160, and turns MEMORY_GRANT_FEEDBACK_PERSISTENCE off and back on.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE IqpDemo;
GO
SET NOCOUNT ON;
GO

TRUNCATE TABLE Demo.Results;
TRUNCATE TABLE Demo.Verdicts;
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) < 16
    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'parameter-sensitive plan optimization', 'needs SQL Server 2022 or later', 'SKIPPED'),
    ('B', 'CE feedback',                           'needs SQL Server 2022 or later', 'SKIPPED'),
    ('C', 'memory grant feedback persistence',     'needs SQL Server 2022 or later', 'SKIPPED');
GO

/*------------------------------------------------------------------------------
  Every setting change below is a batch of its own (GO), and dynamic, so
  2019 doesn't reject it. Changed inside a procedure, the compatibility
  level did not apply to the compilations later in the same procedure.
------------------------------------------------------------------------------*/

-- Start clean: compatibility level 160, the default settings, an empty
-- Query Store and plan cache. And a restart of IqpDemo (OFFLINE, ONLINE):
-- clearing Query Store didn't clear what the engine remembered in memory,
-- and a second run's memory grant feedback was then never saved again.
USE master;
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16
BEGIN
    ALTER DATABASE IqpDemo SET OFFLINE WITH ROLLBACK IMMEDIATE;
    ALTER DATABASE IqpDemo SET ONLINE;
END
GO
USE IqpDemo;
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16
BEGIN
    EXEC (N'ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 160;');
    EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET MEMORY_GRANT_FEEDBACK_PERSISTENCE = ON;');
END
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16
BEGIN
    DECLARE @left int;
    EXEC Demo.usp_Reset @Leftovers = @left OUTPUT;
    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict)
    VALUES ('-', 'Query Store starts empty: no hints, feedback or variants from an earlier run',
            CAST(@left AS varchar(10)) + ' left over',
            CASE WHEN @left = 0 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  A. Parameter-sensitive plans: compatibility level 150, then 160.
==============================================================================*/
PRINT '=== A: parameter-sensitive plans ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16 EXEC (N'ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 150;');
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16 EXEC Demo.usp_A_Run;
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16 EXEC (N'ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 160;');
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16
BEGIN
    EXEC Demo.usp_A_Run;
    EXEC Demo.usp_A_Variants;
END
GO


/*==============================================================================
  B. CE feedback.
==============================================================================*/
PRINT '=== B: CE feedback ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16 EXEC Demo.usp_B;
GO


/*==============================================================================
  C. Memory grant feedback, persisted: ON, then OFF.
==============================================================================*/
PRINT '=== C: memory grant feedback, persisted ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16 EXEC Demo.usp_C_Run;
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16 EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET MEMORY_GRANT_FEEDBACK_PERSISTENCE = OFF;');
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16 EXEC Demo.usp_C_Run;
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16
BEGIN
    EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET MEMORY_GRANT_FEEDBACK_PERSISTENCE = ON;');
    EXEC Demo.usp_Reset;
END
GO


/*==============================================================================
  Verdicts (2022 and later).
==============================================================================*/
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16
BEGIN
    DECLARE @a150s bigint, @a150b bigint, @a160s bigint, @a160b bigint, @variants varchar(300),
            @bfirst bigint, @bafter bigint, @bhint varchar(300), @bfb varchar(300),
            @on1g bigint, @on2g bigint, @on5g bigint, @onCg bigint, @off1g bigint, @off5g bigint, @offCg bigint, @onSaved varchar(100);

    SELECT @a150s = Reads FROM Demo.Results WHERE Label LIKE 'compat 150: customer 600042%';
    SELECT @a150b = Reads FROM Demo.Results WHERE Label LIKE 'compat 150: customer 1 %';
    SELECT @a160s = Reads FROM Demo.Results WHERE Label LIKE 'compat 160: customer 600042%';
    SELECT @a160b = Reads FROM Demo.Results WHERE Label LIKE 'compat 160: customer 1 %';
    SELECT @variants = Note FROM Demo.Results WHERE Label = 'Query Store: variants of the statement';

    SELECT @bfirst = Reads FROM Demo.Results WHERE Label = 'first execution';
    SELECT @bafter = Reads FROM Demo.Results WHERE Label = 'execution after the feedback';
    SELECT @bhint = Note FROM Demo.Results WHERE Scenario = 'B' AND Label LIKE '%Query Store hint';
    SELECT @bfb = Note FROM Demo.Results WHERE Label = 'CE feedback in sys.query_store_plan_feedback';

    SELECT @on1g  = GrantKB FROM Demo.Results WHERE Label = 'persistence ON: execution 1';
    SELECT @on2g  = GrantKB FROM Demo.Results WHERE Label = 'persistence ON: execution 2';
    SELECT @on5g  = GrantKB FROM Demo.Results WHERE Label = 'persistence ON: execution 5';
    SELECT @onCg  = GrantKB FROM Demo.Results WHERE Label LIKE 'persistence ON: first execution after%';
    SELECT @onSaved = Note FROM Demo.Results WHERE Label = 'persistence ON: feedback saved in Query Store';
    SELECT @off1g = GrantKB FROM Demo.Results WHERE Label = 'persistence OFF: execution 1';
    SELECT @off5g = GrantKB FROM Demo.Results WHERE Label = 'persistence OFF: execution 5';
    SELECT @offCg = GrantKB FROM Demo.Results WHERE Label LIKE 'persistence OFF: first execution after%';

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'compat 150: the big customer reuses the plan compiled for the small one',
     'customer 1 read ' + CAST(@a150b AS varchar(20)) + ' pages with the 1-order plan',
     CASE WHEN @a150b >= 10 * @a160b THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('A', 'compat 160: PSP gives the big customer its own plan',
     'customer 1 read ' + CAST(@a160b AS varchar(20)) + '; customer 600042 still ' + CAST(@a160s AS varchar(20)),
     CASE WHEN @a160b * 10 <= @a150b AND @a160s <= 500 THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('A', 'Query Store shows the variants under a dispatcher plan',
     @variants,
     CASE WHEN @variants LIKE '[2-9] variant%' THEN 'CONFIRMED' ELSE 'unexpected' END),

    ('B', 'after repeated executions, CE feedback analyses the query by itself, with no setting changed',
     'sys.query_store_plan_feedback: ' + ISNULL(@bfb, 'nothing'),
     CASE WHEN @bfb LIKE '%[A-Z]%' AND @bfb <> 'none' THEN 'CONFIRMED' ELSE 'INCONCLUSIVE' END),
    ('B', '... and the hint it tried is still attached only if it verified better',
     'Query Store hint from CE feedback now: ' + ISNULL(@bhint, 'none'),
     'info'),
    ('B', 'reads before and after',
     CAST(@bfirst AS varchar(20)) + ' first, ' + CAST(@bafter AS varchar(20)) + ' after the feedback',
     'info'),

    ('C', 'the first execution is granted memory for 500,000 rows, to sort 1',
     'grant ' + CAST(@on1g AS varchar(20)) + ' KB',
     CASE WHEN @on1g >= 10000 THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('C', 'memory grant feedback shrinks it from the next execution',
     'execution 2: ' + CAST(@on2g AS varchar(20)) + ' KB; execution 5: ' + CAST(@on5g AS varchar(20)) + ' KB',
     CASE WHEN @on2g * 4 <= @on1g AND @on5g * 4 <= @on1g THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('C', 'with persistence ON, the smaller grant survives the plan cache being cleared',
     'feedback saved: ' + ISNULL(@onSaved, '?') + '; first execution after: ' + CAST(@onCg AS varchar(20)) + ' KB',
     CASE WHEN @onCg * 4 <= @on1g THEN 'CONFIRMED'
          WHEN @onSaved NOT LIKE 'yes%' THEN 'INCONCLUSIVE' ELSE 'unexpected' END),
    ('C', 'with persistence OFF, it starts again from the oversized grant',
     'first execution after: ' + CAST(@offCg AS varchar(20)) + ' KB (it had come down to ' + CAST(@off5g AS varchar(20)) + ')',
     CASE WHEN @offCg >= 4 * @off5g AND @off5g * 4 <= @off1g THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. EVERY MEASUREMENT ===';
GO
SELECT Scenario, Label, Reads, GrantKB, Note FROM Demo.Results ORDER BY Seq;
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
PRINT ' Result set 3 should be EMPTY on SQL Server 2022 and';
PRINT ' later. On 2019 and earlier it lists every scenario as';
PRINT ' SKIPPED. Anything else in it is a genuine difference';
PRINT ' on your build, worth reading before you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
