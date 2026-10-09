/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, IsolationDemo, and puts everything inside
     it. Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched

     Inside IsolationDemo it turns on Service Broker (ENABLE_BROKER), and
     02-demo.sql switches IsolationDemo's READ_COMMITTED_SNAPSHOT and
     ALLOW_SNAPSHOT_ISOLATION options on and back off. The version store those
     options use lives in tempdb, which every database shares -- see
     scenario F.

  WHY SERVICE BROKER

     Blocking needs two sessions: one holding a lock, one waiting for it. A
     single script cannot be two sessions -- except that Service Broker
     ACTIVATION runs a procedure in a background session of its own when a
     message arrives on a queue. Demo.usp_Writer is that procedure. The demo
     sends it a command, it updates a row and holds (or commits, or rolls
     back) in its own session, and the main script does the reading. No
     second window, no SQL Agent.

  Creates, all inside IsolationDemo:
     Demo.Accounts            - ten accounts; account 1 is the one fought over
     Demo.WriterStatus        - what the background writer is doing
     Demo.usp_Writer          - the background writer (activation procedure)
     WriterQueue / WriterService - its Service Broker queue and service
     Demo.usp_Writer_Start    - send it a command, wait until it has the lock
     Demo.usp_Writer_WaitDone - wait until it has finished
     Demo.usp_ResetAccounts   - put the balances back
     Demo.Results             - one row per measured read or write

  COST: about 200 MB of data plus transaction log, all inside IsolationDemo,
  plus about 20 MB of version store in tempdb during scenario F.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create IsolationDemo, with Service Broker ===';
GO

IF DB_ID('IsolationDemo') IS NOT NULL
BEGIN
    RAISERROR('IsolationDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE IsolationDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE IsolationDemo;
END
GO

CREATE DATABASE IsolationDemo;
GO

ALTER DATABASE IsolationDemo SET RECOVERY SIMPLE;
ALTER DATABASE IsolationDemo SET ENABLE_BROKER;
GO

USE IsolationDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: tables ===';
GO

CREATE TABLE Demo.Accounts
(
    AccountID int NOT NULL PRIMARY KEY,
    Balance   int NOT NULL
);
INSERT Demo.Accounts (AccountID, Balance)
SELECT TOP (10) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 1000 FROM sys.all_columns;
GO

CREATE TABLE Demo.WriterStatus
(
    ID      int          NOT NULL PRIMARY KEY,
    Command nvarchar(40) NULL,
    State   varchar(20)  NOT NULL,      -- idle | holding | done
    Spid    int          NULL,
    At      datetime2(3) NULL
);
INSERT Demo.WriterStatus (ID, State, At) VALUES (1, 'idle', SYSDATETIME());
GO

CREATE TABLE Demo.Results
(
    ResultID   int            IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Scenario   varchar(60)    NOT NULL,
    Item       varchar(90)    NOT NULL,
    WaitedMs   int            NULL,
    ValueRead  int            NULL,
    Detail     nvarchar(300)  NULL,
    Expected   nvarchar(140)  NULL,
    Verdict    varchar(24)    NULL,
    CapturedAt datetime2(3)   NOT NULL CONSTRAINT DF_IDResults_CapturedAt DEFAULT SYSDATETIME()
);
GO


PRINT '=== STEP 3: the background writer ===';
GO

/*------------------------------------------------------------------------------
  Demo.usp_Writer -- the activation procedure. Runs in its OWN session.

  Commands (the message body):
     HOLD_COMMIT:<ms>     add 100 to account 1, hold the lock <ms>, commit
     HOLD_ROLLBACK:<ms>   add 100 to account 1, hold the lock <ms>, roll back
     COMMIT_NOW           add 100 to account 1 and commit at once
     DELAY_COMMIT:<ms>    wait <ms> FIRST, then add 100 and commit at once.
                          Scenarios D and E use this: the main script sends
                          it, THEN opens its own transaction, and the
                          writer's commit lands inside that transaction.
                          (Sending from inside the transaction would not
                          work -- SEND is transactional, so the message is
                          not delivered until the sender commits.)

  Inside its transaction, right after the UPDATE has taken the lock, it sets
  Demo.WriterStatus to 'holding'. That status is uncommitted -- the main
  script reads it WITH (NOLOCK), the one honest use of NOLOCK in this
  topic -- so "holding" is never reported before the lock is really held.
  After the commit or rollback it sets 'done'.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Writer
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @h uniqueidentifier, @body nvarchar(100), @type sysname;

    WAITFOR (RECEIVE TOP (1) @h = conversation_handle,
                             @body = CAST(message_body AS nvarchar(100)),
                             @type = message_type_name
             FROM WriterQueue), TIMEOUT 1000;
    IF @h IS NULL RETURN;

    IF @type = N'http://schemas.microsoft.com/SQL/ServiceBroker/EndDialog'
    BEGIN
        END CONVERSATION @h;
        RETURN;
    END

    DECLARE @ms int = CASE WHEN CHARINDEX(N':', @body) > 0
                           THEN CAST(SUBSTRING(@body, CHARINDEX(N':', @body) + 1, 10) AS int) ELSE 0 END;
    -- WAITFOR DELAY takes a datetime variable directly. (A string built with
    -- CONVERT style 114 does not work: it puts a colon before the
    -- milliseconds, and WAITFOR rejects it -- silently, inside activation.)
    DECLARE @delay datetime = DATEADD(millisecond, @ms, CAST(0 AS datetime));

    IF @body LIKE N'DELAY_COMMIT%' AND @ms > 0
        WAITFOR DELAY @delay;

    BEGIN TRANSACTION;
        UPDATE Demo.Accounts SET Balance = Balance + 100 WHERE AccountID = 1;
        UPDATE Demo.WriterStatus SET Command = @body, State = 'holding', Spid = @@SPID, At = SYSDATETIME() WHERE ID = 1;
        IF @body LIKE N'HOLD%' AND @ms > 0 WAITFOR DELAY @delay;
    IF @body LIKE N'HOLD_ROLLBACK%' ROLLBACK; ELSE COMMIT;

    UPDATE Demo.WriterStatus SET Command = @body, State = 'done', Spid = @@SPID, At = SYSDATETIME() WHERE ID = 1;
    END CONVERSATION @h;
END
GO

CREATE QUEUE WriterQueue
    WITH STATUS = ON,
         ACTIVATION (STATUS = ON, PROCEDURE_NAME = Demo.usp_Writer, MAX_QUEUE_READERS = 1, EXECUTE AS OWNER);
GO
CREATE SERVICE WriterService ON QUEUE WriterQueue ([DEFAULT]);
GO

/*------------------------------------------------------------------------------
  Demo.usp_Writer_Start -- send the writer a command, then wait (polling
  every 50 ms, at most 10 seconds) until it reports 'holding' -- or 'done'.
  With @WaitFor = 'none' it returns straight after sending, and @Since
  carries the status timestamp to pass to Demo.usp_Writer_WaitDone.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Writer_Start
    @Command    nvarchar(40),
    @WaitFor    varchar(20) = 'holding',
    @WriterSpid int = NULL OUTPUT,
    @Since      datetime2(3) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    -- This procedure WRITES nothing. It may be called inside the caller's
    -- open transaction (scenarios D and E), and any lock it took there --
    -- say, on Demo.WriterStatus -- would be held until that transaction
    -- ends, blocking the writer it is waiting for. So it only notes the
    -- writer's last timestamp and waits for a newer one.
    DECLARE @before datetime2(3) = (SELECT At FROM Demo.WriterStatus WITH (NOLOCK) WHERE ID = 1);
    SET @Since = @before;

    DECLARE @h uniqueidentifier;
    BEGIN DIALOG CONVERSATION @h FROM SERVICE WriterService TO SERVICE 'WriterService'
        ON CONTRACT [DEFAULT] WITH ENCRYPTION = OFF;
    SEND ON CONVERSATION @h (@Command);
    IF @WaitFor = 'none' RETURN;

    DECLARE @state varchar(20) = 'idle', @at datetime2(3) = @before, @i int = 0;
    WHILE (@at IS NULL OR @at = @before OR @state NOT IN (@WaitFor, 'done')) AND @i < 200
    BEGIN
        WAITFOR DELAY '00:00:00.050';
        SELECT @state = State, @at = At, @WriterSpid = Spid FROM Demo.WriterStatus WITH (NOLOCK) WHERE ID = 1;
        SET @i += 1;
    END
    IF @at IS NULL OR @at = @before OR @state NOT IN (@WaitFor, 'done')
        RAISERROR('The background writer did not start within 10 seconds. Is Service Broker enabled?', 16, 1);
END
GO

-- Read-only, so it is safe inside the caller's transaction. With @Since,
-- waits for a 'done' newer than that timestamp.
CREATE OR ALTER PROCEDURE Demo.usp_Writer_WaitDone
    @Since datetime2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @state varchar(20) = '', @at datetime2(3), @i int = 0;
    WHILE (@state <> 'done' OR (@Since IS NOT NULL AND (@at IS NULL OR @at <= @Since))) AND @i < 400
    BEGIN
        WAITFOR DELAY '00:00:00.050';
        SELECT @state = State, @at = At FROM Demo.WriterStatus WITH (NOLOCK) WHERE ID = 1;
        SET @i += 1;
    END
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_ResetAccounts
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE Demo.Accounts SET Balance = 1000;
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the IsolationDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
