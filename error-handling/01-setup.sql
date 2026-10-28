/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, ErrorDemo, with Service Broker enabled,
     and nothing else.

     Some scenarios need code that runs with NO TRY/CATCH anywhere around
     it, because that is the behaviour being shown, and an uncaught error
     would end this script. That code runs in a background session instead:
     a Service Broker queue in ErrorDemo whose activation procedure runs one
     batch, with no error handling, and records what happened. SQL Server
     writes the errors raised there to its error log, as it does for any
     activation procedure.

  Creates, all inside ErrorDemo:
     Demo.Orders          - the table the transactions write to
     Demo.OrderAudit      - written by the triggers in scenario D
     Demo.Steps           - each step a batch reached, in order
     Demo.RunnerStatus    - one row per background batch
     Demo.RunnerQueue     - the queue, its service, and Demo.usp_Runner,
                            its activation procedure
     Demo.usp_RunUncaught - run a batch in the background session and wait
     Demo.usp_Step        - record a step
     Demo.Results         - one row per measurement
     Demo.Verdicts        - one row per claim

  TESTED end to end on SQL Server 2025 RTM-CU10 (17.0.5035.5) and 2022
  RTM-CU25 (16.0.4255.1), Linux containers.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create ErrorDemo ===';
GO

IF DB_ID('ErrorDemo') IS NOT NULL
BEGIN
    RAISERROR('ErrorDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE ErrorDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE ErrorDemo;
END
GO

CREATE DATABASE ErrorDemo;
GO

ALTER DATABASE ErrorDemo SET RECOVERY SIMPLE;
ALTER DATABASE ErrorDemo SET ENABLE_BROKER;
GO

USE ErrorDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: the tables ===';
GO

CREATE TABLE Demo.Orders
(
    OrderID   int          NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    Amount    int          NOT NULL
);

CREATE TABLE Demo.OrderAudit
(
    OrderID   int          NOT NULL,
    AuditID   int          IDENTITY(1,1) NOT NULL
);

CREATE TABLE Demo.Steps
(
    Step      varchar(60)  NOT NULL,
    Seq       int          IDENTITY(1,1) NOT NULL
);

CREATE TABLE Demo.RunnerStatus
(
    Token     uniqueidentifier NOT NULL PRIMARY KEY,
    State     varchar(20)      NOT NULL,
    At        datetime2(3)     NOT NULL DEFAULT (SYSDATETIME())
);
GO

-- Record a step. A separate procedure, so a batch reads as a list of steps.
CREATE OR ALTER PROCEDURE Demo.usp_Step
    @Step varchar(60)
AS
    INSERT Demo.Steps (Step) VALUES (@Step);
GO


PRINT '=== STEP 3: the background session ===';
GO

/*------------------------------------------------------------------------------
  Demo.usp_Runner -- the activation procedure. Receives one batch, records
  'started', runs the batch with EXEC () and NO error handling, then records
  'returned'. If an error aborts the batch, it aborts this procedure too, and
  the status stays 'started': that is part of what the demo measures.

  RECEIVE commits on its own, before the batch runs, so a failed batch never
  puts the message back on the queue.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Runner
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @h uniqueidentifier, @type sysname, @body varbinary(max);
    WAITFOR (RECEIVE TOP (1) @h = conversation_handle, @type = message_type_name, @body = message_body
             FROM Demo.RunnerQueue), TIMEOUT 1000;
    IF @h IS NULL RETURN;
    END CONVERSATION @h;
    IF @type <> N'DEFAULT' RETURN;

    DECLARE @msg nvarchar(max) = CAST(@body AS nvarchar(max));
    DECLARE @token uniqueidentifier = CAST(LEFT(@msg, 36) AS uniqueidentifier),
            @batch nvarchar(max) = SUBSTRING(@msg, 38, LEN(@msg));

    INSERT Demo.RunnerStatus (Token, State) VALUES (@token, 'started');
    EXEC (@batch);
    UPDATE Demo.RunnerStatus SET State = 'returned', At = SYSDATETIME() WHERE Token = @token;
END
GO

CREATE QUEUE Demo.RunnerQueue
    WITH STATUS = ON, ACTIVATION (STATUS = ON, PROCEDURE_NAME = Demo.usp_Runner, MAX_QUEUE_READERS = 1, EXECUTE AS OWNER);
CREATE SERVICE RunnerService ON QUEUE Demo.RunnerQueue ([DEFAULT]);
GO

/*------------------------------------------------------------------------------
  Demo.usp_RunUncaught -- empty Demo.Steps, send @Batch to the background
  session, and wait up to 3 seconds for it to return. @Returned is 1 if the
  runner got past the batch, 0 if an error aborted it. Call it OUTSIDE a
  transaction: SEND is transactional.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_RunUncaught
    @Batch     nvarchar(max),
    @Returned  bit OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @h uniqueidentifier, @token uniqueidentifier = NEWID(), @i int = 0, @state varchar(20) = '';
    TRUNCATE TABLE Demo.Steps;
    DECLARE @m nvarchar(max) = CAST(@token AS nvarchar(36)) + N'|' + @Batch;
    BEGIN DIALOG CONVERSATION @h FROM SERVICE RunnerService TO SERVICE 'RunnerService' ON CONTRACT [DEFAULT] WITH ENCRYPTION = OFF;
    SEND ON CONVERSATION @h (@m);
    END CONVERSATION @h;

    -- Wait for 'started' (up to 10 s), then for 'returned' (up to 3 s more).
    WHILE @state = '' AND @i < 200
    BEGIN
        WAITFOR DELAY '00:00:00.050';
        SELECT @state = State FROM Demo.RunnerStatus WITH (NOLOCK) WHERE Token = @token;
        SET @i += 1;
    END
    SET @i = 0;
    WHILE @state <> 'returned' AND @i < 60
    BEGIN
        WAITFOR DELAY '00:00:00.050';
        SELECT @state = State FROM Demo.RunnerStatus WITH (NOLOCK) WHERE Token = @token;
        SET @i += 1;
    END
    SET @Returned = CASE WHEN @state = 'returned' THEN 1 ELSE 0 END;
END
GO


PRINT '=== STEP 4: the harness ===';
GO

CREATE TABLE Demo.Results
(
    Scenario  char(1)        NOT NULL,
    Item      varchar(160)   NOT NULL,
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

-- The steps a batch reached, as one string: 'begin > insert 1 > ...'.
CREATE OR ALTER FUNCTION Demo.fn_Steps ()
RETURNS varchar(400)
AS
BEGIN
    RETURN ISNULL((SELECT STRING_AGG(Step, ' > ') WITHIN GROUP (ORDER BY Seq) FROM Demo.Steps), '(none)');
END
GO

-- The order IDs in Demo.Orders, as one string.
CREATE OR ALTER FUNCTION Demo.fn_Orders ()
RETURNS varchar(400)
AS
BEGIN
    RETURN ISNULL((SELECT STRING_AGG(CAST(OrderID AS varchar(10)), ',') WITHIN GROUP (ORDER BY OrderID) FROM Demo.Orders), '(none)');
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the ErrorDemo database.';
PRINT ' No instance setting was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
