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
    C  memory grant feedback                  -> the grant corrects itself, the plan shape never does
    D  OPTION (RECOMPILE)                     -> correct plan AND grant every time, at a compile per call
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
-- Stopped first, deliberately: stopping discards the ring buffer, and this file
-- is re-runnable. A previous run that died before its own STOP at the bottom
-- would otherwise leave events behind for usp_BackfillMGFeedback to match
-- against the rows of this run.
BEGIN TRY
    IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = 'Demo_ParamSniffing')
        ALTER EVENT SESSION Demo_ParamSniffing ON SERVER STATE = STOP;

    IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'Demo_ParamSniffing')
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
    - GrantMB moving across steps 2..7 while the query keeps spilling
    - MGFeedbackState moving through the engine's feedback states. The strings
      come from the plan verbatim, colons and spaces included:
          No: First Execution      nothing to learn from yet
          No: Accurate Grant       the grant was already right
          Yes: Adjusting           feedback changed the grant
          Yes: Stable              feedback settled on a size
          Yes: Percentile Adjusting   2022+ percentile feedback (see below)
    - PlanShape NEVER changing. This is the whole point: memory grant feedback
      fixes the grant, never the plan. Those 500,000 key lookups are still there.

  Do not expect a tidy climb. On 2019 the grant walks up and stabilises. On
  2022+ percentile feedback sizes the grant from a history of executions rather
  than from the last one, so it can overshoot, settle below ideal, and move
  again several executions later. A grant that oscillates here is the feature
  working, not the demo failing.

  Needs compatibility level 150+ and ROW_MODE_MEMORY_GRANT_FEEDBACK on, both of
  which 01-setup.sql asserts. At 140 or below you will see a flat grant and
  MGFeedbackState stuck on "No: First Execution" -- a correct result for that
  build, not a broken script.

  MGFeedbackState is the one column here that comes from Extended Events rather
  than a DMV, because the attribute exists only in an actual execution plan.
  If 01-setup.sql could not create the event session, this column says so
  instead of reporting a state.
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
    - PlanShape ALSO changing per row -- seek for the minnow, clustered scan for
      the whale, seek again for the minnow. This is the one scenario in the file
      where the harness shows you the shape flipping, because each execution
      compiles the statement afresh and sys.dm_exec_query_plan hands back that
      most recent compile.
    - SniffedValue NULL on every row. Nothing was sniffed: with RECOMPILE the
      optimizer knows the literal value at compile time, so the plan carries no
      ParameterCompiledValue attribute to report.
    - ExecutionCount stuck at 1 while scenario C's climbed, and MGFeedbackState
      stuck at "No: First Execution". THAT is the real cost, and the reason
      scenario C's self-correcting grant cannot happen here: nothing accumulates
      across executions for feedback to learn from.

  Note what this scenario does NOT show, despite what you may have read: an
  emptied plan cache. A statement-level RECOMPILE does not remove the
  procedure's compiled plan -- sys.dm_exec_cached_plans still lists it, with a
  rising usecounts. What it removes is statement plan REUSE. Verify it yourself
  after the run:

      SELECT cp.cacheobjtype, cp.objtype, cp.usecounts,
             ObjName = OBJECT_NAME(st.objectid, st.dbid)
      FROM   sys.dm_exec_cached_plans AS cp
      CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS st
      WHERE  st.objectid = OBJECT_ID('Demo.usp_CustomerLinesByPrice_Recompile')
        AND  st.dbid = DB_ID();

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

-- Fill in MGFeedbackState from the captured actual plans. One pass over the
-- ring buffer for the whole run -- see the note on the procedure in 01-setup.
EXEC Demo.usp_BackfillMGFeedback;
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
    -- per event and per build. query_post_execution_showplan is excluded: it is
    -- collected for MGFeedbackState, it carries eighteen fields including a
    -- whole plan XML, and dumping it here would bury the spill and feedback
    -- events this result set exists to show.
    SELECT  EventName    = e.value('@name', 'sysname'),
            EventTimeUTC = e.value('@timestamp', 'datetime2(3)'),
            FieldName    = d.value('@name', 'sysname'),
            FieldValue   = d.value('(value/text())[1]', 'nvarchar(400)')
    FROM    @x.nodes('/RingBufferTarget/event') AS n(e)
    CROSS APPLY e.nodes('data') AS dn(d)
    WHERE   e.value('@name', 'sysname') <> 'query_post_execution_showplan'
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
     01-setup.sql prints it, and the whole run prints it again at the top --
     and that ROW_MODE_MEMORY_GRANT_FEEDBACK is ON:
        SELECT name, value FROM sys.database_scoped_configurations
        WHERE name = 'ROW_MODE_MEMORY_GRANT_FEEDBACK';

  4a. MGFeedbackState reads "(no XE session - state unavailable)" or
     "(no XE showplan event matched)". That column is sourced from the
     query_post_execution_showplan event, not from a DMV -- the attribute does
     not exist in any cached plan. Either 01-setup.sql could not create the
     event session (needs ALTER ANY EVENT SESSION at server level), or the
     session was not running. Everything else in the summary is unaffected.

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
