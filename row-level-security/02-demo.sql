/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Five scenarios about row-level security in a multi-tenant table, where the
  application connects as one database user and says which tenant it's
  serving with SESSION_CONTEXT:

     A  the filter works: each tenant sees its own rows, and so does no one
        else, including you
     B  a filter predicate doesn't stop writes: a tenant inserts and updates
        rows into another tenant; BLOCK predicates stop it
     C  the session context is only as trustworthy as whoever can set it;
        @read_only = 1 stops it being changed
     D  rows you can't see still leak: a unique key names another tenant's
        order, and a new identity value counts everyone's
     E  what the predicate costs: an index on the tenant column, an admin
        bypass, and a missing CAST

  Every scenario reloads Sales.Orders first, so the file can be re-run.

  WHAT THIS CHANGES: only RlsDemo. Your session's TenantID is cleared at the
  start and at the end. Scenario C's read-only TenantID is set in a
  background session inside RlsDemo, never in yours.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE RlsDemo;
GO
SET NOCOUNT ON;
GO

-- A previous run in this window may have left a TenantID behind.
EXEC sys.sp_set_session_context @key = N'TenantID', @value = NULL;
TRUNCATE TABLE Demo.Results;
GO


/*==============================================================================
  A. The filter works. AppUser sees only the session's tenant; with no
     TenantID it sees nothing, and so does dbo.
==============================================================================*/
PRINT '=== A: the filter ===';
GO
EXEC Demo.usp_Reload;
EXEC Demo.usp_Policy @Fn = N'fn_Tenant';

DECLARE @t int = 1, @seen int, @want int;
WHILE @t <= 3
BEGIN
    EXEC sys.sp_set_session_context @key = N'TenantID', @value = @t;
    EXEC Demo.usp_App @Action = 'COUNT', @Seen = @seen OUTPUT;
    SET @want = CASE @t WHEN 1 THEN 90000 WHEN 2 THEN 9900 ELSE 100 END;
    INSERT Demo.Results VALUES ('A', N'AppUser, TenantID = ' + CAST(@t AS nvarchar(10)) + N': orders it sees',
        CAST(@seen AS nvarchar(20)), CAST(@want AS nvarchar(20)),
        CASE WHEN @seen = @want THEN 'WORKS' ELSE 'unexpected' END);
    SET @t += 1;
END

EXEC sys.sp_set_session_context @key = N'TenantID', @value = NULL;
EXEC Demo.usp_App @Action = 'COUNT', @Seen = @seen OUTPUT;
INSERT Demo.Results VALUES ('A', N'AppUser, no TenantID set: orders it sees',
    CAST(@seen AS nvarchar(20)) + N', and no error', N'0',
    CASE WHEN @seen = 0 THEN 'WORKS' ELSE 'unexpected' END);

-- You, as dbo (or sysadmin): the predicate has no exception for owners.
DECLARE @dbo int = (SELECT COUNT(*) FROM Sales.Orders);
INSERT Demo.Results VALUES ('A', N'you (' + USER_NAME() + N'), no TenantID set: orders you see',
    CAST(@dbo AS nvarchar(20)) + N', and no error', N'100000, for the report or ETL job',
    CASE WHEN @dbo = 0 THEN 'TRAP' ELSE 'unexpected' END);
GO


/*==============================================================================
  B. A filter predicate filters reads. AppUser, serving tenant 3, inserts an
     order for tenant 2 and moves one of its own orders to tenant 2. Both
     work. Then the same with BLOCK predicates AFTER INSERT and AFTER UPDATE.
==============================================================================*/
PRINT '=== B: writes past the filter ===';
GO
DECLARE @block int = 0, @seen int, @rows int, @err int, @t2 int, @label nvarchar(40);
WHILE @block <= 1
BEGIN
    EXEC Demo.usp_Reload;
    EXEC Demo.usp_Policy @Fn = N'fn_Tenant', @Block = @block;
    SET @label = CASE @block WHEN 0 THEN N'filter only' ELSE N'fix: with BLOCK predicates' END;

    -- Insert an order for tenant 2.
    EXEC sys.sp_set_session_context @key = N'TenantID', @value = 3;
    EXEC Demo.usp_App @Action = 'INSERT', @Tenant = 2, @Number = 'SO-B-INS', @Seen = @seen OUTPUT, @Rows = @rows OUTPUT, @Err = @err OUTPUT;
    EXEC sys.sp_set_session_context @key = N'TenantID', @value = 2;
    EXEC Demo.usp_App @Action = 'COUNT', @Seen = @t2 OUTPUT;
    INSERT Demo.Results VALUES ('B', @label + N': tenant 3 inserts an order for tenant 2',
        CASE WHEN @err <> 0 THEN N'error ' + CAST(@err AS nvarchar(10))
             ELSE CAST(@rows AS nvarchar(10)) + N' inserted; tenant 3 still sees ' + CAST(@seen AS nvarchar(10))
                + N', tenant 2 now ' + CAST(@t2 AS nvarchar(10)) END,
        N'rejected',
        CASE WHEN @block = 0 THEN CASE WHEN @err = 0 AND @rows = 1 AND @seen = 100 AND @t2 = 9901 THEN 'TRAP' ELSE 'unexpected' END
             ELSE CASE WHEN @err = 33504 AND @t2 = 9900 THEN 'FIXED' ELSE 'unexpected' END END);

    -- Move one of tenant 3's orders to tenant 2.
    DECLARE @t2before int = @t2;
    EXEC sys.sp_set_session_context @key = N'TenantID', @value = 3;
    EXEC Demo.usp_App @Action = 'MOVE', @Tenant = 2, @Seen = @seen OUTPUT, @Rows = @rows OUTPUT, @Err = @err OUTPUT;
    EXEC sys.sp_set_session_context @key = N'TenantID', @value = 2;
    EXEC Demo.usp_App @Action = 'COUNT', @Seen = @t2 OUTPUT;
    INSERT Demo.Results VALUES ('B', @label + N': tenant 3 moves one of its orders to tenant 2',
        CASE WHEN @err <> 0 THEN N'error ' + CAST(@err AS nvarchar(10))
             ELSE CAST(@rows AS nvarchar(10)) + N' updated; tenant 3 now sees ' + CAST(@seen AS nvarchar(10))
                + N', tenant 2 ' + CAST(@t2 AS nvarchar(10)) END,
        N'rejected',
        CASE WHEN @block = 0 THEN CASE WHEN @err = 0 AND @rows = 1 AND @seen = 99 AND @t2 = @t2before + 1 THEN 'TRAP' ELSE 'unexpected' END
             ELSE CASE WHEN @err = 33504 AND @seen = 100 AND @t2 = @t2before THEN 'FIXED' ELSE 'unexpected' END END);

    SET @block += 1;
END

-- The BLOCK predicates bind you too: dbo, with no TenantID, loads an order.
EXEC sys.sp_set_session_context @key = N'TenantID', @value = NULL;
SET @err = 0;
BEGIN TRY
    INSERT Sales.Orders (TenantID, OrderNumber, Amount) VALUES (2, 'SO-B-ETL', 10.00);
END TRY
BEGIN CATCH
    SET @err = ERROR_NUMBER();
END CATCH
INSERT Demo.Results VALUES ('B', N'... and with them, you (' + USER_NAME() + N'), no TenantID set, load an order for tenant 2',
    CASE WHEN @err <> 0 THEN N'error ' + CAST(@err AS nvarchar(10)) ELSE N'inserted' END,
    N'inserted, for the ETL job',
    CASE WHEN @err = 33504 THEN 'TRAP' ELSE 'unexpected' END);
EXEC sys.sp_set_session_context @key = N'TenantID', @value = NULL;
GO


/*==============================================================================
  C. The predicate trusts SESSION_CONTEXT, and anyone who can run SQL on the
     connection can set it. AppUser, serving tenant 3, sets TenantID = 1
     itself. Then the same in a session where the data layer set TenantID
     WITH @read_only = 1 (the background worker).
==============================================================================*/
PRINT '=== C: who sets the session context ===';
GO
EXEC Demo.usp_Reload;
EXEC Demo.usp_Policy @Fn = N'fn_Tenant', @Block = 1;

DECLARE @seen int, @err int, @msg nvarchar(400), @done bit;
EXEC sys.sp_set_session_context @key = N'TenantID', @value = 3;
EXEC Demo.usp_App @Action = 'SETCTX', @Tenant = 1, @Seen = @seen OUTPUT, @Err = @err OUTPUT;
INSERT Demo.Results VALUES ('C', N'AppUser, serving tenant 3, sets TenantID = 1 itself: orders it sees',
    CASE WHEN @err <> 0 THEN N'error ' + CAST(@err AS nvarchar(10)) ELSE CAST(@seen AS nvarchar(20)) END,
    N'100, and an error',
    CASE WHEN @err = 0 AND @seen = 90000 THEN 'TRAP' ELSE 'unexpected' END);
EXEC sys.sp_set_session_context @key = N'TenantID', @value = NULL;

EXEC Demo.usp_Worker_Run @Seen = @seen OUTPUT, @Err = @err OUTPUT, @Msg = @msg OUTPUT, @Done = @done OUTPUT;
INSERT Demo.Results VALUES ('C', N'fix: TenantID set WITH @read_only = 1, then AppUser sets TenantID = 1',
    CASE WHEN @done = 0 THEN N'the background session did not answer within 10 s'
         ELSE N'error ' + CAST(@err AS nvarchar(10)) + N'; it still sees ' + CAST(@seen AS nvarchar(20)) END,
    N'100, and an error',
    CASE WHEN @done = 0 THEN 'INCONCLUSIVE'
         WHEN @err = 15664 AND @seen = 100 THEN 'FIXED' ELSE 'unexpected' END);
INSERT Demo.Results VALUES ('C', N'... the error', @msg, NULL, 'info');
GO


/*==============================================================================
  D. Rows AppUser can't see still leave traces. Tenant 3 tries an order
     number that belongs to tenant 1, and inserts one order of its own and
     reads back its identity value. Then with the order number unique per
     tenant.
==============================================================================*/
PRINT '=== D: what leaks past the filter ===';
GO
EXEC Demo.usp_Reload;
EXEC Demo.usp_Policy @Fn = N'fn_Tenant', @Block = 1;

DECLARE @seen int, @rows int, @newid bigint, @err int, @msg nvarchar(400);
EXEC sys.sp_set_session_context @key = N'TenantID', @value = 3;

-- SO-000500 is tenant 1's.
EXEC Demo.usp_App @Action = 'INSERT', @Tenant = 3, @Number = 'SO-000500', @Rows = @rows OUTPUT, @Err = @err OUTPUT, @Msg = @msg OUTPUT;
INSERT Demo.Results VALUES ('D', N'tenant 3 inserts order number SO-000500 (tenant 1''s)',
    CASE WHEN @err <> 0 THEN N'error ' + CAST(@err AS nvarchar(10)) + N': ' + @msg ELSE CAST(@rows AS nvarchar(10)) + N' inserted' END,
    N'1 inserted: tenant 3 has no SO-000500',
    CASE WHEN @err IN (2627, 2601) AND @msg LIKE N'%SO-000500%' THEN 'TRAP' ELSE 'unexpected' END);

-- A new order of its own: the identity value counts every tenant's orders.
EXEC Demo.usp_App @Action = 'INSERT', @Tenant = 3, @Number = 'SO-D-NEW', @Seen = @seen OUTPUT, @NewID = @newid OUTPUT, @Err = @err OUTPUT;
INSERT Demo.Results VALUES ('D', N'tenant 3, which sees ' + CAST(@seen - 1 AS nvarchar(10)) + N' orders, inserts one: its new OrderID',
    CASE WHEN @err <> 0 THEN N'error ' + CAST(@err AS nvarchar(10)) ELSE CAST(@newid AS nvarchar(20)) END,
    N'a value that says nothing about other tenants',
    CASE WHEN @err = 0 AND @newid > 100000 THEN 'TRAP' ELSE 'unexpected' END);

-- The fix for the first: order numbers unique per tenant.
EXEC Demo.usp_Reload @UniquePerTenant = 1;
EXEC Demo.usp_Policy @Fn = N'fn_Tenant', @Block = 1;
EXEC Demo.usp_App @Action = 'INSERT', @Tenant = 3, @Number = 'SO-000500', @Seen = @seen OUTPUT, @Rows = @rows OUTPUT, @Err = @err OUTPUT;
INSERT Demo.Results VALUES ('D', N'fix: UNIQUE (TenantID, OrderNumber); tenant 3 inserts SO-000500',
    CASE WHEN @err <> 0 THEN N'error ' + CAST(@err AS nvarchar(10)) ELSE CAST(@rows AS nvarchar(10)) + N' inserted' END,
    N'1 inserted: tenant 3 has no SO-000500',
    CASE WHEN @err = 0 AND @rows = 1 THEN 'FIXED' ELSE 'unexpected' END);

EXEC sys.sp_set_session_context @key = N'TenantID', @value = NULL;
GO


/*==============================================================================
  E. What the predicate costs. Tenant 3 reads its 100 orders (COUNT and SUM
     of Amount; logical reads of a warm run) under four designs.
==============================================================================*/
PRINT '=== E: the cost of the predicate ===';
GO
DECLARE @seen int, @reads bigint, @base bigint, @dboSeen int;
EXEC sys.sp_set_session_context @key = N'TenantID', @value = 3;

-- 1. The predicate, with an index on TenantID.
EXEC Demo.usp_Reload;
EXEC Demo.usp_Policy @Fn = N'fn_Tenant';
EXEC Demo.usp_App @Action = 'COUNT', @Seen = @seen OUTPUT, @Reads = @base OUTPUT;
INSERT Demo.Results VALUES ('E', N'fn_Tenant, index on TenantID: logical reads',
    CAST(@base AS nvarchar(20)) + N' (sees ' + CAST(@seen AS nvarchar(10)) + N')', NULL,
    CASE WHEN @seen = 100 THEN 'info' ELSE 'unexpected' END);

-- 2. The same, with no index on TenantID.
EXEC Demo.usp_Reload @TenantIndex = 0;
EXEC Demo.usp_Policy @Fn = N'fn_Tenant';
EXEC Demo.usp_App @Action = 'COUNT', @Seen = @seen OUTPUT, @Reads = @reads OUTPUT;
INSERT Demo.Results VALUES ('E', N'fn_Tenant, no index on TenantID: logical reads',
    CAST(@reads AS nvarchar(20)) + N' (sees ' + CAST(@seen AS nvarchar(10)) + N')', N'about ' + CAST(@base AS nvarchar(20)),
    CASE WHEN @seen = 100 AND @reads >= 10 * @base THEN 'TRAP' ELSE 'unexpected' END);

-- 3. With the db_owner bypass.
EXEC Demo.usp_Reload;
EXEC Demo.usp_Policy @Fn = N'fn_TenantOrOwner';
EXEC Demo.usp_App @Action = 'COUNT', @Seen = @seen OUTPUT, @Reads = @reads OUTPUT;
SET @dboSeen = (SELECT COUNT(*) FROM Sales.Orders);
INSERT Demo.Results VALUES ('E', N'fn_TenantOrOwner (OR IS_MEMBER(''db_owner'') = 1): logical reads',
    CAST(@reads AS nvarchar(20)) + N' (sees ' + CAST(@seen AS nvarchar(10)) + N'; you see ' + CAST(@dboSeen AS nvarchar(10)) + N')',
    N'about ' + CAST(@base AS nvarchar(20)),
    CASE WHEN @seen = 100 AND @dboSeen = 100000 AND @reads >= 5 * @base THEN 'TRAP' ELSE 'unexpected' END);

-- 4. Without the CAST.
EXEC Demo.usp_Policy @Fn = N'fn_TenantNoCast';
EXEC Demo.usp_App @Action = 'COUNT', @Seen = @seen OUTPUT, @Reads = @reads OUTPUT;
INSERT Demo.Results VALUES ('E', N'fn_TenantNoCast (no CAST on SESSION_CONTEXT): logical reads',
    CAST(@reads AS nvarchar(20)) + N' (sees ' + CAST(@seen AS nvarchar(10)) + N')',
    N'about ' + CAST(@base AS nvarchar(20)),
    CASE WHEN @seen = 100 AND @reads >= 5 * @base THEN 'TRAP' ELSE 'unexpected' END);

-- ... and when the application sets TenantID as a string, '3'.
EXEC sys.sp_set_session_context @key = N'TenantID', @value = N'3';
EXEC Demo.usp_App @Action = 'COUNT', @Seen = @seen OUTPUT;
INSERT Demo.Results VALUES ('E', N'fn_TenantNoCast, TenantID set as the string ''3'': orders tenant 3 sees',
    CAST(@seen AS nvarchar(10)) + N', and no error', N'100',
    CASE WHEN @seen = 0 THEN 'TRAP' ELSE 'unexpected' END);

EXEC Demo.usp_Policy @Fn = N'fn_Tenant';
EXEC Demo.usp_App @Action = 'COUNT', @Seen = @seen OUTPUT;
INSERT Demo.Results VALUES ('E', N'fix: fn_Tenant (with CAST), TenantID still the string ''3'': orders it sees',
    CAST(@seen AS nvarchar(10)), N'100',
    CASE WHEN @seen = 100 THEN 'FIXED' ELSE 'unexpected' END);

EXEC sys.sp_set_session_context @key = N'TenantID', @value = NULL;
GO


/*==============================================================================
  Leave things as the scenarios found them: the plain policy, and this
  session back to itself, with no TenantID.
==============================================================================*/
EXEC Demo.usp_Reload;
EXEC Demo.usp_Policy @Fn = N'fn_Tenant';
EXEC sys.sp_set_session_context @key = N'TenantID', @value = NULL;

INSERT Demo.Results VALUES ('-', N'this session afterwards: user, and TenantID',
    USER_NAME() + N', ' + ISNULL(CAST(SESSION_CONTEXT(N'TenantID') AS nvarchar(20)), N'none'), N'dbo, none',
    CASE WHEN USER_NAME() = N'dbo' AND SESSION_CONTEXT(N'TenantID') IS NULL THEN 'info' ELSE 'unexpected' END);
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. WHAT SQL SERVER RETURNED ===';
GO
SELECT Scenario, Item, Got, Wanted, Verdict FROM Demo.Results ORDER BY Seq;
GO

PRINT '';
PRINT '=== 2. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Got, Wanted, Verdict FROM Demo.Results WHERE Verdict IN ('unexpected', 'INCONCLUSIVE') ORDER BY Seq;
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 2 should be EMPTY. Anything in it is a';
PRINT ' genuine difference on your build, worth reading';
PRINT ' before you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
