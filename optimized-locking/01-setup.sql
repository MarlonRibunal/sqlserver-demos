/*==============================================================================
  01-setup.sql          RUN ONCE. Takes about 10 seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, LockDemo, and puts everything inside it.
     Nothing else on the instance is modified. Inside LockDemo it sets:

        - ACCELERATED_DATABASE_RECOVERY = ON (optimized locking requires it)
        - Service Broker on, for the demo's background session (see WHY
          SERVICE BROKER)

     The demo turns OPTIMIZED_LOCKING and READ_COMMITTED_SNAPSHOT on and off
     for LockDemo, and says so at the top of 02-demo.sql.

  ON SQL SERVER 2022 AND EARLIER the database is created without optimized
  locking, which arrived in 2025, and the demo reports every scenario as
  SKIPPED.

  Creates, all inside LockDemo:
     Demo.Orders           - 100,000 rows; Status is one of 100 values, with
                             no index on it
     Demo.w_*              - what the background session tries to do
     Demo.usp_Locks        - the locks an open UPDATE holds
     Demo.usp_Contend      - hold a lock, and watch the background session
     Demo.Results          - one row per measurement
     Demo.Verdicts         - one row per claim

  WHY SERVICE BROKER

     The blocking scenarios need a second session that tries to change rows
     while this one holds locks, so this one can watch it wait. Sending a
     message to a queue in LockDemo runs its activation procedure in a
     background session.

  TESTED end to end on SQL Server 2025 RTM-CU8 (17.0.4075.5), Linux
  container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create LockDemo ===';
GO

IF DB_ID('LockDemo') IS NOT NULL
BEGIN
    RAISERROR('LockDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE LockDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE LockDemo;
END
GO

CREATE DATABASE LockDemo;
GO

ALTER DATABASE LockDemo SET RECOVERY SIMPLE;
ALTER DATABASE LockDemo SET ENABLE_BROKER;
GO

-- ADR exists from 2019; optimized locking needs it.
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 15
    EXEC (N'ALTER DATABASE LockDemo SET ACCELERATED_DATABASE_RECOVERY = ON;');
GO

USE LockDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: tables ===';
GO

CREATE TABLE Demo.Orders
(
    OrderID  int          NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    Status   varchar(10)  NOT NULL,      -- 's0' to 's99'; no index
    Qty      int          NOT NULL,
    pad      char(200)    NOT NULL CONSTRAINT DF_Orders_pad DEFAULT ('x')
);
;WITH n AS
(
    SELECT TOP (100000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.Orders WITH (TABLOCK) (OrderID, Status, Qty)
SELECT rn, 's' + CAST(rn % 100 AS varchar(10)), 0
FROM   n;
GO

CREATE TABLE Demo.Results
(
    Scenario  char(1)        NOT NULL,
    Label     varchar(120)   NOT NULL,
    Value     varchar(400)   NULL,
    Seq       int            IDENTITY(1,1) NOT NULL
);
GO

CREATE TABLE Demo.Verdicts
(
    Scenario  char(1)        NOT NULL,
    Claim     varchar(200)   NOT NULL,
    Evidence  varchar(400)   NULL,
    Verdict   varchar(30)    NOT NULL,
    Seq       int            IDENTITY(1,1) NOT NULL
);
GO

-- Set to 1 (uncommitted, inside the demo's transaction) once the demo holds
-- its locks; the background session polls it WITH (NOLOCK).
CREATE TABLE Demo.Control (ID int NOT NULL PRIMARY KEY, Locked bit NOT NULL);
INSERT Demo.Control (ID, Locked) VALUES (1, 0);
GO

CREATE TABLE Demo.WorkerStatus
(
    Token     uniqueidentifier NOT NULL PRIMARY KEY,
    Spid      int              NULL,
    State     varchar(20)      NOT NULL,     -- started, done
    Err       int              NULL,         -- 1222: gave up waiting for a lock
    RowsDone  int              NULL,
    Ms        int              NULL,
    At        datetime2(3)     NOT NULL CONSTRAINT DF_WorkerStatus_At DEFAULT SYSDATETIME()
);
GO


PRINT '=== STEP 3: what the background session tries ===';
GO

-- B: an order far from the ones the demo is updating.
CREATE OR ALTER PROCEDURE Demo.w_OtherRow @Rows int OUTPUT AS
    UPDATE Demo.Orders SET Qty += 1 WHERE OrderID = 90000;
    SET @Rows = @@ROWCOUNT;
GO

-- C: the 's2' orders among the first 1,000. Status has no index, so the
-- update reads every one of the 1,000 rows, including order 1, which the
-- demo holds. Order 1 is 's1': it doesn't qualify.
CREATE OR ALTER PROCEDURE Demo.w_ScanUpdate @Rows int OUTPUT AS
    UPDATE Demo.Orders SET Qty += 1 WHERE OrderID <= 1000 AND Status = 's2';
    SET @Rows = @@ROWCOUNT;
GO

-- D: order 1 itself.
CREATE OR ALTER PROCEDURE Demo.w_SameRow @Rows int OUTPUT AS
    UPDATE Demo.Orders SET Qty += 1 WHERE OrderID = 1;
    SET @Rows = @@ROWCOUNT;
GO


PRINT '=== STEP 4: the background session ===';
GO

/*------------------------------------------------------------------------------
  Demo.usp_Worker -- the activation procedure. The message is a token and a
  procedure name. Reports its session id, waits until the demo holds its
  locks, runs Demo.<name> with LOCK_TIMEOUT 3 s, and reports how it went.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Worker
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @h uniqueidentifier, @type sysname, @body nvarchar(200);
    WAITFOR (RECEIVE TOP (1) @h = conversation_handle, @type = message_type_name,
                             @body = CAST(message_body AS nvarchar(200)) FROM Demo.WorkerQueue), TIMEOUT 1000;
    IF @h IS NULL RETURN;
    IF @type <> N'DEFAULT'
    BEGIN
        END CONVERSATION @h;
        RETURN;
    END

    DECLARE @token uniqueidentifier = CAST(LEFT(@body, 36) AS uniqueidentifier),
            @proc  nvarchar(200) = N'Demo.' + SUBSTRING(@body, 38, 100),
            @rows int = NULL, @err int = 0, @t0 datetime2(7), @i int = 0;

    INSERT Demo.WorkerStatus (Token, Spid, State) VALUES (@token, @@SPID, 'started');
    WHILE (SELECT Locked FROM Demo.Control WITH (NOLOCK) WHERE ID = 1) = 0 AND @i < 200
    BEGIN
        WAITFOR DELAY '00:00:00.050';
        SET @i += 1;
    END

    SET LOCK_TIMEOUT 3000;
    SET @t0 = SYSDATETIME();
    BEGIN TRY
        EXEC @proc @Rows = @rows OUTPUT;
    END TRY
    BEGIN CATCH
        SET @err = ERROR_NUMBER();
    END CATCH
    SET LOCK_TIMEOUT -1;

    UPDATE Demo.WorkerStatus
    SET    State = 'done', Err = @err, RowsDone = @rows, Ms = DATEDIFF(millisecond, @t0, SYSDATETIME()), At = SYSDATETIME()
    WHERE  Token = @token;
    END CONVERSATION @h;
END
GO

CREATE QUEUE Demo.WorkerQueue
    WITH STATUS = ON, ACTIVATION (STATUS = ON, PROCEDURE_NAME = Demo.usp_Worker, MAX_QUEUE_READERS = 1, EXECUTE AS OWNER);
CREATE SERVICE WorkerService ON QUEUE Demo.WorkerQueue ([DEFAULT]);
GO


PRINT '=== STEP 5: the measurements ===';
GO

/*------------------------------------------------------------------------------
  Demo.usp_Locks -- update the first @Rows orders in a transaction, list the
  locks this session holds in LockDemo while it's open, then roll back.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Locks
    @Rows  int,
    @Label varchar(60)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @locks varchar(400);
    BEGIN TRANSACTION;
        UPDATE Demo.Orders SET Qty += 1 WHERE OrderID <= @Rows;
        SELECT @locks = STRING_AGG(CAST(resource_type + ' ' + request_mode + ': ' + CAST(n AS varchar(10)) AS varchar(400)), ', ')
                        WITHIN GROUP (ORDER BY n DESC)
        FROM  (SELECT resource_type, request_mode, n = COUNT(*)
               FROM   sys.dm_tran_locks
               WHERE  request_session_id = @@SPID AND resource_database_id = DB_ID() AND resource_type <> 'DATABASE'
               GROUP BY resource_type, request_mode) AS l;
    ROLLBACK;
    INSERT Demo.Results (Scenario, Label, Value)
    VALUES ('A', @Label + ': locks held by an open UPDATE of ' + CAST(@Rows AS varchar(10)) + ' rows', @locks);
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_Contend -- start the background session on Demo.@Work; update
  @HoldRows orders (from order 1) in a transaction; watch the background
  session in sys.dm_os_waiting_tasks for 2 seconds or until it finishes;
  roll back; and record what it waited on and how it ended.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Contend
    @Scenario char(1),
    @Label    varchar(80),
    @Work     sysname,
    @HoldRows int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @token uniqueidentifier = NEWID(), @h uniqueidentifier, @m nvarchar(200), @spid int, @i int = 0,
            @wait nvarchar(60), @res nvarchar(200), @state varchar(20) = '', @err int, @rows int, @ms int;

    UPDATE Demo.Control SET Locked = 0 WHERE ID = 1;
    SET @m = CAST(@token AS nvarchar(36)) + N'|' + @Work;
    BEGIN DIALOG CONVERSATION @h FROM SERVICE WorkerService TO SERVICE 'WorkerService' ON CONTRACT [DEFAULT] WITH ENCRYPTION = OFF;
    SEND ON CONVERSATION @h (@m);
    WHILE @spid IS NULL AND @i < 200
    BEGIN
        WAITFOR DELAY '00:00:00.050';
        SELECT @spid = Spid FROM Demo.WorkerStatus WITH (NOLOCK) WHERE Token = @token;
        SET @i += 1;
    END
    IF @spid IS NULL
    BEGIN
        INSERT Demo.Results (Scenario, Label, Value) VALUES (@Scenario, @Label, 'the background session did not start');
        RETURN;
    END

    BEGIN TRANSACTION;
        UPDATE Demo.Orders SET Qty += 1 WHERE OrderID <= @HoldRows;
        UPDATE Demo.Control SET Locked = 1 WHERE ID = 1;

        SET @i = 0;
        WHILE @i < 40 AND @state <> 'done'
        BEGIN
            WAITFOR DELAY '00:00:00.050';
            IF @wait IS NULL
                SELECT TOP (1) @wait = wait_type, @res = LEFT(resource_description, 200)
                FROM   sys.dm_os_waiting_tasks
                WHERE  session_id = @spid AND wait_type LIKE N'LCK[_]M[_]%';
            SELECT @state = State FROM Demo.WorkerStatus WITH (NOLOCK) WHERE Token = @token;
            SET @i += 1;
        END
    ROLLBACK;

    SET @i = 0;
    WHILE @state <> 'done' AND @i < 200
    BEGIN
        WAITFOR DELAY '00:00:00.050';
        SELECT @state = State FROM Demo.WorkerStatus WITH (NOLOCK) WHERE Token = @token;
        SET @i += 1;
    END
    SELECT @err = Err, @rows = RowsDone, @ms = Ms FROM Demo.WorkerStatus WITH (NOLOCK) WHERE Token = @token;

    INSERT Demo.Results (Scenario, Label, Value)
    VALUES (@Scenario, @Label,
            CASE WHEN @state <> 'done' THEN 'the background session did not finish'
                 WHEN @err = 1222 THEN 'BLOCKED: gave up after ' + CAST(@ms AS varchar(10)) + ' ms (error 1222)'
                 WHEN @err <> 0 THEN 'error ' + CAST(@err AS varchar(10))
                 -- Blocked until this session rolled back, 2 s in, then done.
                 WHEN @wait IS NOT NULL AND @ms >= 1500
                      THEN 'BLOCKED ' + CAST(@ms AS varchar(10)) + ' ms, until the holder rolled back; then ' + CAST(@rows AS varchar(10)) + ' row(s) updated'
                 ELSE 'done in ' + CAST(@ms AS varchar(10)) + ' ms, ' + CAST(@rows AS varchar(10)) + ' row(s) updated' END
            + CASE WHEN @wait IS NOT NULL THEN '; waited on ' + @wait + ' (' + ISNULL(@res, '') + ')' ELSE '; never waited on a lock' END);
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the LockDemo database.';
PRINT ' No instance setting was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
