/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, RlsDemo, and puts everything inside it.
     Nothing else on the instance is modified:

        - no server login is created: the demo's application user, AppUser,
          is a database user WITHOUT LOGIN, inside RlsDemo
        - Service Broker is enabled on RlsDemo only (see WHY SERVICE BROKER)
        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched

  Creates, all inside RlsDemo:
     Sales.Orders               - 100,000 orders for three tenants
     Security.fn_Tenant         - the predicate: the row's tenant is the
                                  session's TenantID
     Security.fn_TenantOrOwner  - the same, with a bypass for db_owner
     Security.fn_TenantNoCast   - the same, without CAST on SESSION_CONTEXT
     AppUser                    - the application's database user
     Demo.Numbers               - 1 to 100,000
     Demo.Results               - what each scenario returned
     Demo.usp_Policy            - (re)create the security policy
     Demo.usp_Reload            - Sales.Orders back to its 100,000 rows,
                                  with no policy
     Demo.usp_App               - do one thing as AppUser
     Demo.usp_Worker_Run        - the same, from a session whose TenantID
                                  is read-only

  WHY SERVICE BROKER

     SESSION_CONTEXT set with @read_only = 1 can't be changed again for the
     rest of the session. Doing that in your session would lock TenantID for
     the rest of the demo, and for the next run if you re-run it in the same
     SSMS window. So scenario C does it in a background session: sending a
     message to a queue in RlsDemo runs its activation procedure there.

  COST: about 30 MB, all inside RlsDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create RlsDemo ===';
GO

IF DB_ID('RlsDemo') IS NOT NULL
BEGIN
    RAISERROR('RlsDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE RlsDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE RlsDemo;
END
GO

CREATE DATABASE RlsDemo;
GO

ALTER DATABASE RlsDemo SET RECOVERY SIMPLE;
ALTER DATABASE RlsDemo SET ENABLE_BROKER;
GO

USE RlsDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL     EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
IF SCHEMA_ID('Sales') IS NULL    EXEC ('CREATE SCHEMA Sales AUTHORIZATION dbo;');
IF SCHEMA_ID('Security') IS NULL EXEC ('CREATE SCHEMA Security AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: tables ===';
GO

-- Three tenants share one table: tenant 1 has 90,000 orders, tenant 2 has
-- 9,900, tenant 3 has 100. Order numbers are unique across the table.
CREATE TABLE Sales.Orders
(
    OrderID     int            IDENTITY(1,1) NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    TenantID    int            NOT NULL,
    OrderNumber varchar(20)    NOT NULL,
    Amount      decimal(12,2)  NOT NULL,
    pad         char(200)      NOT NULL CONSTRAINT DF_Orders_pad DEFAULT ('x'),
    CONSTRAINT UQ_Orders_Number UNIQUE (OrderNumber)
);
GO

-- 1 to 100,000: usp_Reload's source, built once.
CREATE TABLE Demo.Numbers (n int NOT NULL PRIMARY KEY);
;WITH n AS
(
    SELECT TOP (100000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.Numbers WITH (TABLOCK) (n) SELECT rn FROM n;
GO

CREATE TABLE Demo.Results
(
    Scenario  char(1)        NOT NULL,
    Item      nvarchar(120)  NOT NULL,
    Got       nvarchar(300)  NULL,
    Wanted    nvarchar(200)  NULL,
    Verdict   varchar(30)    NULL,
    Seq       int            IDENTITY(1,1) NOT NULL   -- the order rows were written
);
GO

-- What the background session reported, one row per run.
CREATE TABLE Demo.WorkerResult
(
    Token      uniqueidentifier NOT NULL PRIMARY KEY,
    Err        int              NULL,
    Msg        nvarchar(400)    NULL,
    Seen       int              NULL,
    At         datetime2(3)     NOT NULL CONSTRAINT DF_WorkerResult_At DEFAULT SYSDATETIME()
);
GO


PRINT '=== STEP 3: the predicate functions ===';
GO

-- The predicate: a row is visible when its tenant is the session's
-- TenantID. SESSION_CONTEXT returns sql_variant, so it's CAST to the
-- column's type.
CREATE FUNCTION Security.fn_Tenant (@TenantID int)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN SELECT Visible = 1
       WHERE  @TenantID = CAST(SESSION_CONTEXT(N'TenantID') AS int);
GO

-- The same, but db_owner members see every row: the usual "admins and the
-- ETL job need everything" bypass. Scenario E measures what it costs.
CREATE FUNCTION Security.fn_TenantOrOwner (@TenantID int)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN SELECT Visible = 1
       WHERE  @TenantID = CAST(SESSION_CONTEXT(N'TenantID') AS int)
          OR  IS_MEMBER('db_owner') = 1;
GO

-- The same as fn_Tenant, without the CAST: the int column is compared with
-- a sql_variant.
CREATE FUNCTION Security.fn_TenantNoCast (@TenantID int)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN SELECT Visible = 1
       WHERE  @TenantID = SESSION_CONTEXT(N'TenantID');
GO


PRINT '=== STEP 4: the application user ===';
GO

-- The application's database user. WITHOUT LOGIN: nothing at server level.
CREATE USER AppUser WITHOUT LOGIN;
GRANT SELECT, INSERT, UPDATE ON SCHEMA::Sales TO AppUser;
GO


PRINT '=== STEP 5: procedures ===';
GO

/*------------------------------------------------------------------------------
  Demo.usp_Policy -- drop and recreate Security.TenantPolicy with predicate
  function @Fn: a FILTER predicate, and with @Block = 1 BLOCK predicates
  AFTER INSERT and AFTER UPDATE too. A function a policy uses can't be
  altered, even with the policy's STATE = OFF, so switching predicates means
  recreating the policy. @Fn = NULL just drops it.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Policy
    @Fn    sysname = NULL,
    @Block bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF OBJECT_ID(N'Security.TenantPolicy', N'SP') IS NOT NULL
        DROP SECURITY POLICY Security.TenantPolicy;
    IF @Fn IS NULL RETURN;

    DECLARE @f nvarchar(300) = N'Security.' + QUOTENAME(@Fn) + N'(TenantID) ON Sales.Orders';
    DECLARE @sql nvarchar(max) =
          N'CREATE SECURITY POLICY Security.TenantPolicy ADD FILTER PREDICATE ' + @f
        + CASE WHEN @Block = 1
               THEN N', ADD BLOCK PREDICATE ' + @f + N' AFTER INSERT'
                  + N', ADD BLOCK PREDICATE ' + @f + N' AFTER UPDATE'
               ELSE N'' END
        + N' WITH (STATE = ON);';
    EXEC (@sql);
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_Reload -- Sales.Orders back to its 100,000 rows, IDs from 1, and
  no security policy.
  @UniquePerTenant = 1 makes the order number unique per tenant instead of
  across the table (scenario D's fix). @TenantIndex = 0 leaves out the index
  on TenantID (scenario E).
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Reload
    @UniquePerTenant bit = 0,
    @TenantIndex     bit = 1
AS
BEGIN
    SET NOCOUNT ON;

    -- With BLOCK predicates on, even dbo's load would be rejected (33504):
    -- dbo has no TenantID either. So the policy goes first; the caller
    -- recreates it.
    EXEC Demo.usp_Policy @Fn = NULL;

    TRUNCATE TABLE Sales.Orders;

    IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_Orders_Number' AND parent_object_id = OBJECT_ID(N'Sales.Orders'))
        ALTER TABLE Sales.Orders DROP CONSTRAINT UQ_Orders_Number;
    IF @UniquePerTenant = 1
        ALTER TABLE Sales.Orders ADD CONSTRAINT UQ_Orders_Number UNIQUE (TenantID, OrderNumber);
    ELSE
        ALTER TABLE Sales.Orders ADD CONSTRAINT UQ_Orders_Number UNIQUE (OrderNumber);

    IF INDEXPROPERTY(OBJECT_ID(N'Sales.Orders'), N'IX_Orders_Tenant', 'IndexID') IS NOT NULL
        DROP INDEX IX_Orders_Tenant ON Sales.Orders;

    INSERT Sales.Orders WITH (TABLOCK) (TenantID, OrderNumber, Amount)
    SELECT CASE WHEN n <= 90000 THEN 1 WHEN n <= 99900 THEN 2 ELSE 3 END,
           'SO-' + RIGHT('000000' + CAST(n AS varchar(10)), 6),
           (n % 1000) + 0.50
    FROM   Demo.Numbers
    ORDER BY n;

    IF @TenantIndex = 1
        CREATE INDEX IX_Orders_Tenant ON Sales.Orders (TenantID) INCLUDE (Amount);
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_App -- do one thing AS AppUser, with whatever TenantID the session
  has. The EXECUTE AS ends with the procedure, even after an error.

  @Action:
     COUNT    how many orders AppUser sees, and the logical reads of a
              COUNT + SUM over them (run twice; the second, warm, is reported)
     INSERT   insert one order for tenant @Tenant, numbered @Number
     MOVE     move one visible order to tenant @Tenant
     SETCTX   set the session's TenantID to @Tenant itself, then COUNT

  Outputs: @Seen (rows visible afterwards), @Reads, @Rows (rows the INSERT or
  UPDATE changed), @NewID (SCOPE_IDENTITY after an INSERT), and @Err / @Msg
  if a statement failed.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_App
    @Action varchar(10),
    @Tenant int           = NULL,
    @Number varchar(20)   = NULL,
    @Seen   int           = NULL OUTPUT,
    @Reads  bigint        = NULL OUTPUT,
    @Rows   int           = NULL OUTPUT,
    @NewID  bigint        = NULL OUTPUT,
    @Err    int           = NULL OUTPUT,
    @Msg    nvarchar(400) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @Seen = NULL, @Reads = NULL, @Rows = NULL, @NewID = NULL, @Err = 0, @Msg = NULL;

    EXECUTE AS USER = 'AppUser';

    BEGIN TRY
        IF @Action = 'INSERT'
        BEGIN
            INSERT Sales.Orders (TenantID, OrderNumber, Amount) VALUES (@Tenant, @Number, 10.00);
            SELECT @Rows = @@ROWCOUNT, @NewID = SCOPE_IDENTITY();
        END
        ELSE IF @Action = 'MOVE'
        BEGIN
            UPDATE TOP (1) Sales.Orders SET TenantID = @Tenant;
            SET @Rows = @@ROWCOUNT;
        END
        ELSE IF @Action = 'SETCTX'
            EXEC sys.sp_set_session_context @key = N'TenantID', @value = @Tenant;
    END TRY
    BEGIN CATCH
        SELECT @Err = ERROR_NUMBER(), @Msg = LEFT(ERROR_MESSAGE(), 400);
    END CATCH

    -- How many rows AppUser sees now, and what reading them costs.
    DECLARE @i int = 0, @r0 bigint, @c int, @s decimal(18,2);
    WHILE @i < 2
    BEGIN
        SET @r0 = (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID);
        SELECT @c = COUNT(*), @s = SUM(Amount) FROM Sales.Orders;
        SET @Reads = (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0;
        SET @i += 1;
    END
    SET @Seen = @c;

    REVERT;
END
GO

/*------------------------------------------------------------------------------
  The background session (scenario C's fix). The worker sets TenantID = 3
  with @read_only = 1, the way an application's data layer would on opening
  a connection, then lets AppUser try to change it to 1.

  Activation sessions are reused, and SESSION_CONTEXT survives from one
  activation to the next. So if TenantID is already set (read-only, by an
  earlier run), the worker leaves it as it is.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Worker
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @h uniqueidentifier, @type sysname, @body varbinary(max);

    WAITFOR (RECEIVE TOP (1) @h = conversation_handle, @type = message_type_name, @body = message_body
             FROM Demo.WorkerQueue), TIMEOUT 1000;
    IF @h IS NULL RETURN;

    -- The other end closing the conversation: close ours.
    IF @type <> N'DEFAULT'
    BEGIN
        END CONVERSATION @h;
        RETURN;
    END

    DECLARE @token uniqueidentifier = CAST(CAST(@body AS nvarchar(100)) AS uniqueidentifier);
    DECLARE @seen int, @err int, @msg nvarchar(400);

    IF SESSION_CONTEXT(N'TenantID') IS NULL
        EXEC sys.sp_set_session_context @key = N'TenantID', @value = 3, @read_only = 1;

    EXEC Demo.usp_App @Action = 'SETCTX', @Tenant = 1, @Seen = @seen OUTPUT, @Err = @err OUTPUT, @Msg = @msg OUTPUT;

    INSERT Demo.WorkerResult (Token, Err, Msg, Seen) VALUES (@token, @err, @msg, @seen);
    END CONVERSATION @h;
END
GO

CREATE QUEUE Demo.WorkerQueue
    WITH STATUS = ON, ACTIVATION (STATUS = ON, PROCEDURE_NAME = Demo.usp_Worker, MAX_QUEUE_READERS = 1, EXECUTE AS OWNER);
CREATE SERVICE WorkerService ON QUEUE Demo.WorkerQueue ([DEFAULT]);
GO

-- Run the worker once and wait for its result. Not inside a transaction:
-- SEND is transactional.
CREATE OR ALTER PROCEDURE Demo.usp_Worker_Run
    @Seen int           = NULL OUTPUT,
    @Err  int           = NULL OUTPUT,
    @Msg  nvarchar(400) = NULL OUTPUT,
    @Done bit           = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @token uniqueidentifier = NEWID(), @h uniqueidentifier;
    DECLARE @m nvarchar(100) = CAST(@token AS nvarchar(100));
    BEGIN DIALOG CONVERSATION @h FROM SERVICE WorkerService TO SERVICE 'WorkerService' ON CONTRACT [DEFAULT] WITH ENCRYPTION = OFF;
    SEND ON CONVERSATION @h (@m);

    DECLARE @i int = 0;
    SET @Done = 0;
    WHILE @Done = 0 AND @i < 200
    BEGIN
        WAITFOR DELAY '00:00:00.050';
        IF EXISTS (SELECT 1 FROM Demo.WorkerResult WITH (NOLOCK) WHERE Token = @token) SET @Done = 1;
        SET @i += 1;
    END
    SELECT @Seen = Seen, @Err = Err, @Msg = Msg FROM Demo.WorkerResult WHERE Token = @token;
END
GO

EXEC Demo.usp_Reload;
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the RlsDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
