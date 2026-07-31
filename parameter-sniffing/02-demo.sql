/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  This runs five scenarios end to end and records the evidence into
  Demo.DemoResults as it goes, so you do not have to sit there reading actual
  execution plans between executions. The summary at the bottom is the payoff.

  ############################################################################
  #  BEFORE YOU PRESS F5                                                     #
  #                                                                          #
  #  SSMS > Query Options > Results > Grid                                   #
  #         [x] Discard results after execution                              #
  #                                                                          #
  #  This procedure returns 500,000 wide rows about ten times over. Without   #
  #  that setting you are timing the client grid, not the server, and the     #
  #  elapsed times in the summary will be meaningless.                        #
  #                                                                          #
  #  Not on SSMS? Azure Data Studio and the VS Code mssql extension have no   #
  #  equivalent setting. Run this file through sqlcmd instead and send the    #
  #  rows to a file you then delete:                                          #
  #      sqlcmd -S <server> -d WideWorldImporters -i 02-demo.sql -o out.txt   #
  ############################################################################

  Expected runtime: a few minutes, most of it scenario C.

  Scenarios
    A  sniff the minnow, then run the whale   -> right plan for 300 rows, run for 500,000
    B  sniff the whale, then run the minnow   -> huge grant reserved for a handful of rows
    C  memory grant feedback                  -> watch the grant self-correct, plan shape does not
    D  OPTION (RECOMPILE)                     -> correct every time, and nothing left in cache
    E  Parameter Sensitive Plan optimization  -> 2022+ only; the engine handles it itself

  UNTESTED: written without access to a SQL Server instance.
==============================================================================*/

USE WideWorldImporters;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('Demo.usp_Capture') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

TRUNCATE TABLE Demo.DemoResults;
GO

-- Start the Extended Events session if 01-setup managed to create it.
BEGIN TRY
    IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'Demo_ParamSniffing')
       AND NOT EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = 'Demo_ParamSniffing')
        ALTER EVENT SESSION Demo_ParamSniffing ON SERVER STATE = START;
END TRY
BEGIN CATCH
    RAISERROR('Could not start XE session. Continuing on DMV evidence only.', 0, 1) WITH NOWAIT;
END CATCH
GO

DECLARE @compat int = (SELECT compatibility_level FROM sys.databases WHERE database_id = DB_ID());
RAISERROR('Compatibility level is %d. Row mode memory grant feedback (scenario C) needs 150 or higher.', 0, 1, @compat) WITH NOWAIT;
GO


/*==============================================================================
  SCENARIO A -- sniff the minnow, then run the whale

  The plan is compiled for a customer with a few hundred rows: index seek, key
  lookup, and the minimum memory grant. That plan is then reused for a customer
  with 500,000 rows. Half a million key lookups, and a sort sized for the minnow.

  What to look for in the summary:
    - SniffedValue stays the minnow's CustomerID on BOTH rows
    - PlanShape stays "Index Seek + Key Lookup + Sort" on both
    - step 2 ActualRows is ~500,000 against an EstimatedRows in the hundreds
    - step 2 IdealGrantMB is far above GrantMB  <- that gap is the tempdb spill
    - step 2 LogicalReads is enormous           <- that is the key lookups

  sp_recompile, not DBCC FREEPROCCACHE. There is no reason to flush an entire
  instance's plan cache to reset one procedure.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO A: sniff minnow, run whale ---';
GO

EXEC sys.sp_recompile N'Demo.usp_CustomerLinesByPrice';
GO

DECLARE @Whale  int = (SELECT CAST(SettingValue AS int) FROM Demo.DemoState WHERE SettingName = 'WhaleCustomerID'),
        @Minnow int = (SELECT CAST(SettingValue AS int) FROM Demo.DemoState WHERE SettingName = 'MinnowCustomerID');

EXEC Demo.usp_CustomerLinesByPrice @CustomerID = @Minnow;
EXEC Demo.usp_Capture 'A. Sniff minnow, run whale', 1,
     'Compiled here, for the minnow', 'Demo.usp_CustomerLinesByPrice', @Minnow, 'minnow';

EXEC Demo.usp_CustomerLinesByPrice @CustomerID = @Whale;
EXEC Demo.usp_Capture 'A. Sniff minnow, run whale', 2,
     'Reused the minnow plan for the whale', 'Demo.usp_CustomerLinesByPrice', @Whale, 'whale';
GO


/*==============================================================================
  SCENARIO B -- sniff the whale, then run the minnow

  The mirror image, and the one people miss. The plan is not slow, it is greedy:
  a clustered index scan plus a grant sized for 500,000 wide rows, reused to
  return a few hundred. Nothing spills, nothing looks broken in the query's own
  duration -- it just reserves workspace memory it never touches. Run it from
  several sessions at once and you get RESOURCE_SEMAPHORE waits.

  What to look for:
    - step 2 GrantMB is large while UsedGrantMB is tiny
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO B: sniff whale, run minnow ---';
GO

EXEC sys.sp_recompile N'Demo.usp_CustomerLinesByPrice';
GO

DECLARE @Whale  int = (SELECT CAST(SettingValue AS int) FROM Demo.DemoState WHERE SettingName = 'WhaleCustomerID'),
        @Minnow int = (SELECT CAST(SettingValue AS int) FROM Demo.DemoState WHERE SettingName = 'MinnowCustomerID');

EXEC Demo.usp_CustomerLinesByPrice @CustomerID = @Whale;
EXEC Demo.usp_Capture 'B. Sniff whale, run minnow', 1,
     'Compiled here, for the whale', 'Demo.usp_CustomerLinesByPrice', @Whale, 'whale';

EXEC Demo.usp_CustomerLinesByPrice @CustomerID = @Minnow;
EXEC Demo.usp_Capture 'B. Sniff whale, run minnow', 2,
     'Reused the whale plan for the minnow', 'Demo.usp_CustomerLinesByPrice', @Minnow, 'minnow';
GO


/*==============================================================================
  SCENARIO C -- memory grant feedback

  Same bad start as scenario A: compile for the minnow, then hammer the whale.
  The difference is that nothing recompiles in between, so the feedback loop has
  a cached plan to attach to and can act.

  Two constraints this scenario is built around:
    1. Feedback lives on the cached plan. Any recompile mid-run wipes the very
       thing you are trying to watch, which is why there is no sp_recompile
       inside this loop.
    2. An adjustment made after execution N shows up on execution N+1. So the
       grant column should move DOWN the rows, one step behind the spill.

  What to look for:
    - GrantMB climbing across steps 2..7 while the query keeps spilling
    - MGFeedbackState moving through values like NoFirstExecution ->
      YesAdjusting -> YesStable
    - PlanShape NEVER changing. This is the whole point: memory grant feedback
      fixes the grant, never the plan. Those 500,000 key lookups are still there.

  Needs compatibility level 150+. At 140 or below you will see a flat grant and
  MGFeedbackState will likely be NULL -- that is a correct result for that build,
  not a broken script.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO C: memory grant feedback (slowest scenario) ---';
GO

EXEC sys.sp_recompile N'Demo.usp_CustomerLinesByPrice';
GO

DECLARE @Whale  int = (SELECT CAST(SettingValue AS int) FROM Demo.DemoState WHERE SettingName = 'WhaleCustomerID'),
        @Minnow int = (SELECT CAST(SettingValue AS int) FROM Demo.DemoState WHERE SettingName = 'MinnowCustomerID'),
        @i      int = 1,
        @Iterations int = 6;

EXEC Demo.usp_CustomerLinesByPrice @CustomerID = @Minnow;
EXEC Demo.usp_Capture 'C. Memory grant feedback', 1,
     'Compiled for the minnow. Nothing recompiles after this point.',
     'Demo.usp_CustomerLinesByPrice', @Minnow, 'minnow';

DECLARE @desc varchar(200), @step int;

WHILE @i <= @Iterations
BEGIN
    EXEC Demo.usp_CustomerLinesByPrice @CustomerID = @Whale;

    -- EXEC parameters must be variables or constants, never expressions.
    SET @step = @i + 1;
    SET @desc = 'Whale execution ' + CAST(@i AS varchar(10))
              + ' of ' + CAST(@Iterations AS varchar(10)) + ' (no recompile)';

    EXEC Demo.usp_Capture 'C. Memory grant feedback', @step, @desc,
         'Demo.usp_CustomerLinesByPrice', @Whale, 'whale';

    RAISERROR('  scenario C iteration %d of %d done', 0, 1, @i, @Iterations) WITH NOWAIT;
    SET @i += 1;
END
GO


/*==============================================================================
  SCENARIO D -- OPTION (RECOMPILE)

  Same query, recompiled per execution against the actual parameter value.
  Both the plan shape and the grant are right every time.

  What to look for:
    - GrantMB tracking ActualRows in BOTH directions: small for the minnow, large
      for the whale, small again for the minnow. Compare against scenarios A and
      B, where one of the two was always wrong.
    - PlanShape and SniffedValue reported as "(no cached plan ...)". That is not
      a gap in the harness, it is the finding: a RECOMPILE statement leaves
      nothing in the plan cache, so there is nothing for memory grant feedback
      to attach to and improve across executions. Scenario C's self-correcting
      grant cannot happen here, because there is no plan to correct.

  Because there is no cached plan, this scenario cannot show you the plan SHAPE
  flipping. If you want to see that, turn on the actual execution plan and run
  the two EXEC statements below by hand -- seek+lookup for the minnow, scan for
  the whale, correctly chosen each time.

  The cost you are trading for this is a compile on every call, paid in CPU,
  and no plan reuse. On a procedure called thousands of times a minute that is
  a bad trade; on a reporting procedure called a few times an hour it is
  usually the right one.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO D: OPTION (RECOMPILE) ---';
GO

DECLARE @Whale  int = (SELECT CAST(SettingValue AS int) FROM Demo.DemoState WHERE SettingName = 'WhaleCustomerID'),
        @Minnow int = (SELECT CAST(SettingValue AS int) FROM Demo.DemoState WHERE SettingName = 'MinnowCustomerID');

EXEC Demo.usp_CustomerLinesByPrice_Recompile @CustomerID = @Minnow;
EXEC Demo.usp_Capture 'D. OPTION (RECOMPILE)', 1, 'Minnow',
     'Demo.usp_CustomerLinesByPrice_Recompile', @Minnow, 'minnow';

EXEC Demo.usp_CustomerLinesByPrice_Recompile @CustomerID = @Whale;
EXEC Demo.usp_Capture 'D. OPTION (RECOMPILE)', 2, 'Whale',
     'Demo.usp_CustomerLinesByPrice_Recompile', @Whale, 'whale';

EXEC Demo.usp_CustomerLinesByPrice_Recompile @CustomerID = @Minnow;
EXEC Demo.usp_Capture 'D. OPTION (RECOMPILE)', 3, 'Minnow again',
     'Demo.usp_CustomerLinesByPrice_Recompile', @Minnow, 'minnow';
GO


/*==============================================================================
  SCENARIO E -- Parameter Sensitive Plan optimization (SQL Server 2022+)

  01-setup.sql turned PSP off, because it targets exactly this shape -- a single
  equality predicate on a heavily skewed column -- and would have quietly fixed
  scenarios A and B before you saw them fail.

  Here it goes back on. PSP caches multiple plan variants for the same procedure
  and dispatches on the parameter's estimated cardinality, so both the minnow and
  the whale can get an appropriate plan without a recompile per call.

  What to look for:
    - the plan shape differing between the two rows even though neither
      execution recompiled
  Skipped automatically on builds without PSP.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO E: Parameter Sensitive Plan optimization ---';
GO

IF EXISTS (SELECT 1 FROM sys.database_scoped_configurations
           WHERE name = N'PARAMETER_SENSITIVE_PLAN_OPTIMIZATION')
BEGIN
    ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = ON;
    EXEC sys.sp_recompile N'Demo.usp_CustomerLinesByPrice';

    DECLARE @Whale  int = (SELECT CAST(SettingValue AS int) FROM Demo.DemoState WHERE SettingName = 'WhaleCustomerID'),
            @Minnow int = (SELECT CAST(SettingValue AS int) FROM Demo.DemoState WHERE SettingName = 'MinnowCustomerID');

    EXEC Demo.usp_CustomerLinesByPrice @CustomerID = @Minnow;
    EXEC Demo.usp_Capture 'E. PSP enabled', 1, 'Minnow (PSP on)',
         'Demo.usp_CustomerLinesByPrice', @Minnow, 'minnow';

    EXEC Demo.usp_CustomerLinesByPrice @CustomerID = @Whale;
    EXEC Demo.usp_Capture 'E. PSP enabled', 2, 'Whale (PSP on, no recompile)',
         'Demo.usp_CustomerLinesByPrice', @Whale, 'whale';

    -- Back off, so re-running 02-demo.sql behaves identically.
    ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = OFF;
END
ELSE
    RAISERROR('No PSP on this build (needs SQL Server 2022+ at compat 160). Scenario E skipped.', 0, 1) WITH NOWAIT;
GO


/*==============================================================================
  RESULTS
==============================================================================*/
PRINT '';
PRINT '--- collecting results ---';
GO

-- Let the XE ring buffer flush (MAX_DISPATCH_LATENCY is 5 seconds).
WAITFOR DELAY '00:00:06';
GO

PRINT '';
PRINT '=== 1. THE SUMMARY ===';
GO

SELECT  r.Scenario,
        r.StepNo,
        r.StepDescription,
        r.ParamRole,
        r.ParamUsed,
        SniffedValue  = r.SniffedValue,
        r.PlanShape,
        EstRows       = CAST(r.EstimatedRows AS decimal(18,1)),
        ActualRows    = r.ActualRows,
        GrantMB       = r.GrantMB,
        UsedMB        = r.UsedGrantMB,
        IdealMB       = r.IdealGrantMB,
        -- Ideal far above granted is the fingerprint of a sort that spilled.
        SpillHint     = CASE WHEN r.IdealGrantMB > r.GrantMB * 1.5 THEN 'LIKELY SPILLED' ELSE '' END,
        -- Granted far above used is memory reserved and never touched.
        WasteHint     = CASE WHEN r.GrantMB > 5 AND r.GrantMB > r.UsedGrantMB * 2 THEN 'GRANT WASTED' ELSE '' END,
        r.LogicalReads,
        r.ElapsedMs,
        r.MGFeedbackState
FROM    Demo.DemoResults AS r
ORDER BY r.ResultID;
GO

PRINT '';
PRINT '=== 2. SCENARIO C, GRANT TRAJECTORY (memory grant feedback) ===';
GO

SELECT  r.StepNo,
        r.StepDescription,
        GrantMB      = r.GrantMB,
        UsedMB       = r.UsedGrantMB,
        IdealMB      = r.IdealGrantMB,
        GrantDeltaMB = r.GrantMB - LAG(r.GrantMB) OVER (ORDER BY r.StepNo),
        r.MGFeedbackState,
        -- PlanShape should be IDENTICAL on every row. Memory grant feedback
        -- fixes the grant, never the plan. The key lookups never go away.
        r.PlanShape,
        -- LogicalReads will drift DOWN as the grant grows, because this counter
        -- includes worktable/workfile reads and the spills are shrinking. The
        -- base table cost underneath it stays just as pathological.
        r.LogicalReads
FROM    Demo.DemoResults AS r
WHERE   r.Scenario = 'C. Memory grant feedback'
ORDER BY r.StepNo;
GO

PRINT '';
PRINT '=== 3. EXTENDED EVENTS: spills and feedback adjustments ===';
GO

DECLARE @x xml;

SELECT @x = CAST(t.target_data AS xml)
FROM   sys.dm_xe_sessions AS s
JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
WHERE  s.name = 'Demo_ParamSniffing'
  AND  t.target_name = 'ring_buffer';

IF @x IS NULL
    RAISERROR('No XE data (session not running, or not created). DMV evidence above still stands.', 0, 1) WITH NOWAIT;
ELSE
    -- Shredded generically as name/value pairs, because the useful fields differ
    -- per event and per build.
    SELECT  EventName    = e.value('@name', 'sysname'),
            EventTimeUTC = e.value('@timestamp', 'datetime2(3)'),
            FieldName    = d.value('@name', 'sysname'),
            FieldValue   = d.value('(value/text())[1]', 'nvarchar(400)')
    FROM    @x.nodes('/RingBufferTarget/event') AS n(e)
    CROSS APPLY e.nodes('data') AS dn(d)
    ORDER BY EventTimeUTC, EventName, FieldName;
GO

-- Stop the session so it is not collecting in the background.
BEGIN TRY
    IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = 'Demo_ParamSniffing')
        ALTER EVENT SESSION Demo_ParamSniffing ON SERVER STATE = STOP;
END TRY
BEGIN CATCH
END CATCH
GO


/*------------------------------------------------------------------------------
  IF NOTHING MISBEHAVED, CHECK THESE IN ORDER

  1. PlanShape says "Top N Sort". The demo is not measuring what you think --
     see the note in 01-setup.sql step 4.

  2. PlanShape says "PARALLEL". Parallelism changes the grant arithmetic and
     muddies the comparison. Add OPTION (MAXDOP 1) to both procedure bodies
     while establishing a baseline.

  3. Scenarios A and B show a different PlanShape per row without recompiling.
     PSP is still on. Confirm:
        SELECT name, value FROM sys.database_scoped_configurations
        WHERE name = 'PARAMETER_SENSITIVE_PLAN_OPTIMIZATION';

  4. Scenario C shows a flat grant. Check the compatibility level is 150+ --
     01-setup.sql prints it, and the whole run prints it again at the top.

  5. GrantMB never gets large. Your instance may have a low max server memory,
     capping the grant. Compare GrantMB against IdealMB rather than against an
     absolute number.

  6. Everything is fast. Confirm "Discard results after execution" is on --
     otherwise the elapsed times are dominated by SSMS rendering.
------------------------------------------------------------------------------*/
PRINT '';
PRINT '=== DEMO COMPLETE. Raw evidence is in Demo.DemoResults. ===';
PRINT '=== Run 03-cleanup.sql when you are finished.          ===';
GO
