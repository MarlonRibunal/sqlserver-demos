/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, DeadlockDemo, and puts everything inside
     it. Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set (not 1204, not 1222)
        - no Extended Events session is created: the demo reads the
          deadlock graphs the built-in system_health session already keeps
        - no existing database is touched

     Inside DeadlockDemo it turns on Service Broker (ENABLE_BROKER).

  WHY SERVICE BROKER

     A deadlock needs two sessions. The second one is a Service Broker
     activation procedure running in the background (see the
     rcsi-snapshot-isolation topic), so the whole demo runs from one window.
     The worker takes its first lock, says so, waits, then reaches for the
     lock the demo's session has taken in the meantime -- so each deadlock
     happens on cue instead of by luck.

  Creates, all inside DeadlockDemo:
     Demo.Accounts           - 10,000 accounts; rows 1 and 2 are fought over
     Demo.WorkerStatus       - what the worker is doing now
     Demo.Outcomes           - how each side of each scenario ended
     Demo.usp_Worker         - the worker: one move per scenario
     Q1, S1                  - its queue and service
     Demo.usp_Send           - send it a command
     Demo.usp_WaitFor        - wait until it reports a state
     Demo.usp_Scenario       - one choreographed scenario: the worker's move,
                               then the demo session's, with retries
     Demo.usp_LookupRace     - scenario E: a reader against the worker's writer

  COST: under 100 MB, all inside DeadlockDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create DeadlockDemo, with Service Broker ===';
GO

IF DB_ID('DeadlockDemo') IS NOT NULL
BEGIN
    RAISERROR('DeadlockDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE DeadlockDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DeadlockDemo;
END
GO

CREATE DATABASE DeadlockDemo;
GO

ALTER DATABASE DeadlockDemo SET RECOVERY SIMPLE;
ALTER DATABASE DeadlockDemo SET ENABLE_BROKER;
GO

USE DeadlockDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: tables ===';
GO

/*------------------------------------------------------------------------------
  Demo.Accounts. IX_Accounts_Ref is keyed on (AccountRef, Status) and does
  NOT include Balance, so "look up the balance by reference" is a seek on
  IX_Accounts_Ref plus a key lookup into the clustered index -- the shape
  scenario E needs. The demo adds Balance to it as the fix.
------------------------------------------------------------------------------*/
CREATE TABLE Demo.Accounts
(
    AccountID   int            NOT NULL CONSTRAINT PK_Accounts PRIMARY KEY CLUSTERED,
    AccountRef  char(10)       NOT NULL,
    Status      tinyint        NOT NULL,
    Balance     decimal(12,2)  NOT NULL,
    pad         char(200)      NOT NULL CONSTRAINT DF_Accounts_pad DEFAULT ('x')
);

;WITH n AS
(
    SELECT TOP (10000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.Accounts (AccountID, AccountRef, Status, Balance)
SELECT rn, 'ACC' + RIGHT('0000000' + CAST(rn AS varchar(7)), 7), 0, 1000
FROM   n;

CREATE INDEX IX_Accounts_Ref ON Demo.Accounts (AccountRef, Status);
GO

CREATE TABLE Demo.WorkerStatus
(
    ID     int          NOT NULL PRIMARY KEY,
    RunTag varchar(30)  NULL,
    State  varchar(20)  NOT NULL
);
INSERT Demo.WorkerStatus (ID, RunTag, State) VALUES (1, NULL, 'idle');

CREATE TABLE Demo.Outcomes
(
    RunTag       varchar(30)    NOT NULL,
    Who          varchar(10)    NOT NULL,     -- demo | worker
    Attempts     int            NOT NULL,
    Deadlocks    int            NOT NULL,     -- Msg 1205 received
    Iterations   int            NULL,         -- loops in scenario E
    OtherError   nvarchar(200)  NULL,
    ElapsedMs    int            NULL,
    StartedUtc   datetime2(3)   NULL,         -- the demo's row: when the scenario began
    At           datetime2(3)   NOT NULL CONSTRAINT DF_Outcomes_At DEFAULT SYSDATETIME()
);
GO


PRINT '=== STEP 3: the worker ===';
GO

/*------------------------------------------------------------------------------
  Demo.usp_Worker -- the activation procedure. The message is
  "<runtag>|<move>". Every move reports 'holding' (through Demo.WorkerStatus,
  which the demo reads WITH (NOLOCK)) once it has its first lock, waits two
  seconds for the demo to take its own, then reaches for the demo's lock.

     OPPOSITE   UPDATE account 2, then account 1    (the demo goes 1, then 2)
     SAME       UPDATE account 1, then account 2    (the demo does the same)
     CONVERT    REPEATABLE READ: read account 1, then UPDATE it
     UPDLOCK    read account 1 WITH (UPDLOCK), then UPDATE it
     WRITER     for <seconds>, flip account 5000's Status, in a loop
                ("WRITER:5" -- the move carries the duration)

  Deadlocks (Msg 1205) are caught and counted; the outcome is written after
  the transaction has ended, so it survives being chosen as the victim.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Worker
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @h uniqueidentifier, @body nvarchar(100), @type sysname;
    WAITFOR (RECEIVE TOP (1) @h = conversation_handle, @body = CAST(message_body AS nvarchar(100)),
             @type = message_type_name FROM Q1), TIMEOUT 1000;
    IF @h IS NULL RETURN;
    IF @type = N'http://schemas.microsoft.com/SQL/ServiceBroker/EndDialog'
    BEGIN
        END CONVERSATION @h;
        RETURN;
    END
    END CONVERSATION @h;

    DECLARE @tag varchar(30) = LEFT(@body, CHARINDEX(N'|', @body) - 1);
    DECLARE @move varchar(30) = SUBSTRING(@body, CHARINDEX(N'|', @body) + 1, 30);
    DECLARE @hold datetime = '00:00:02';
    DECLARE @t0 datetime2(7) = SYSDATETIME(), @dl int = 0, @other nvarchar(200), @iter int = NULL, @b decimal(12,2);

    IF @move LIKE 'WRITER:%'
    BEGIN
        -- Scenario E's writer: autocommit updates of a column in
        -- IX_Accounts_Ref's key, so each one locks the clustered row and
        -- then the index row.
        DECLARE @until datetime2(7) = DATEADD(second, CAST(SUBSTRING(@move, 8, 5) AS int), SYSDATETIME());
        SET @iter = 0;
        UPDATE Demo.WorkerStatus SET RunTag = @tag, State = 'holding' WHERE ID = 1;
        WHILE SYSDATETIME() < @until
        BEGIN
            BEGIN TRY
                UPDATE Demo.Accounts SET Status = 1 - Status WHERE AccountID = 5000;
            END TRY
            BEGIN CATCH
                IF ERROR_NUMBER() = 1205 SET @dl += 1;
                ELSE SET @other = LEFT(ERROR_MESSAGE(), 200);
            END CATCH
            SET @iter += 1;
        END
    END
    ELSE
    BEGIN
        BEGIN TRY
            IF @move = 'CONVERT' SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
            BEGIN TRANSACTION;
                IF @move = 'OPPOSITE'
                    UPDATE Demo.Accounts SET Balance += 10 WHERE AccountID = 2;
                ELSE IF @move = 'SAME'
                    UPDATE Demo.Accounts SET Balance += 10 WHERE AccountID = 1;
                ELSE IF @move = 'CONVERT'
                    SELECT @b = Balance FROM Demo.Accounts WHERE AccountID = 1;
                ELSE IF @move = 'UPDLOCK'
                    SELECT @b = Balance FROM Demo.Accounts WITH (UPDLOCK) WHERE AccountID = 1;

                UPDATE Demo.WorkerStatus SET RunTag = @tag, State = 'holding' WHERE ID = 1;
                WAITFOR DELAY @hold;

                IF @move = 'OPPOSITE'
                    UPDATE Demo.Accounts SET Balance += 10 WHERE AccountID = 1;
                ELSE IF @move = 'SAME'
                    UPDATE Demo.Accounts SET Balance += 10 WHERE AccountID = 2;
                ELSE
                    UPDATE Demo.Accounts SET Balance = @b + 10 WHERE AccountID = 1;
            COMMIT;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            IF ERROR_NUMBER() = 1205 SET @dl += 1;
            ELSE SET @other = LEFT(ERROR_MESSAGE(), 200);
        END CATCH
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    END

    INSERT Demo.Outcomes (RunTag, Who, Attempts, Deadlocks, Iterations, OtherError, ElapsedMs)
    VALUES (@tag, 'worker', 1, @dl, @iter, @other, DATEDIFF(millisecond, @t0, SYSDATETIME()));
    UPDATE Demo.WorkerStatus SET RunTag = @tag, State = 'done' WHERE ID = 1;
END
GO

CREATE QUEUE Q1 WITH STATUS = ON,
    ACTIVATION (STATUS = ON, PROCEDURE_NAME = Demo.usp_Worker, MAX_QUEUE_READERS = 1, EXECUTE AS OWNER);
GO
CREATE SERVICE S1 ON QUEUE Q1 ([DEFAULT]);
GO

/*------------------------------------------------------------------------------
  Demo.usp_Send -- give the worker a move. Must not be called inside a
  transaction: SEND is transactional, and the message would not leave until
  the commit.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Send
    @RunTag varchar(30),
    @Move   varchar(30)
AS
BEGIN
    SET NOCOUNT ON;
    IF @@TRANCOUNT > 0
    BEGIN
        RAISERROR('Demo.usp_Send must not run inside a transaction.', 16, 1);
        RETURN;
    END
    UPDATE Demo.WorkerStatus SET RunTag = @RunTag, State = 'sent' WHERE ID = 1;
    DECLARE @h uniqueidentifier, @msg nvarchar(100) = CAST(@RunTag AS nvarchar(30)) + N'|' + CAST(@Move AS nvarchar(30));
    BEGIN DIALOG CONVERSATION @h FROM SERVICE [S1] TO SERVICE 'S1' ON CONTRACT [DEFAULT] WITH ENCRYPTION = OFF;
    SEND ON CONVERSATION @h (@msg);
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_WaitFor -- wait (at most @MaxSeconds) until the worker reports
  @State for @RunTag. Reads WITH (NOLOCK): the worker writes 'holding' inside
  its open transaction, and this may be called inside the demo's own.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_WaitFor
    @RunTag     varchar(30),
    @State      varchar(20),
    @MaxSeconds int = 30
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 datetime2(3) = SYSDATETIME();
    WHILE NOT EXISTS (SELECT 1 FROM Demo.WorkerStatus WITH (NOLOCK)
                      WHERE ID = 1 AND RunTag = @RunTag AND State = @State)
      AND DATEDIFF(millisecond, @t0, SYSDATETIME()) < @MaxSeconds * 1000
        WAITFOR DELAY '00:00:00.020';
END
GO


PRINT '=== STEP 4: the demo session''s side ===';
GO

/*------------------------------------------------------------------------------
  Demo.usp_Scenario -- send the worker @Move, wait until it holds its first
  lock, then do the mirror image in THIS session, retrying up to
  @MaxAttempts times on a deadlock:

     OPPOSITE   UPDATE account 1, then account 2
     SAME       UPDATE account 1, then account 2
     CONVERT    REPEATABLE READ: read account 1, then UPDATE it
     UPDLOCK    read account 1 WITH (UPDLOCK), then UPDATE it

  DEADLOCK_PRIORITY LOW makes this session the victim whenever there is a
  deadlock, so the worker always finishes and the result is predictable.
  Without it SQL Server picks whichever transaction is cheaper to roll back.
  The SET lasts only until this procedure returns, as does the isolation
  level.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Scenario
    @RunTag      varchar(30),
    @Move        varchar(30),
    @MaxAttempts int = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET DEADLOCK_PRIORITY LOW;
    DECLARE @started datetime2(3) = SYSUTCDATETIME(), @t0 datetime2(7), @attempt int = 0, @dl int = 0,
            @other nvarchar(200), @b decimal(12,2), @ok bit = 0;

    EXEC Demo.usp_Send @RunTag, @Move;
    EXEC Demo.usp_WaitFor @RunTag, 'holding';
    SET @t0 = SYSDATETIME();

    IF @Move = 'CONVERT' SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
    WHILE @ok = 0 AND @attempt < @MaxAttempts AND @other IS NULL
    BEGIN
        SET @attempt += 1;
        BEGIN TRY
            BEGIN TRANSACTION;
                IF @Move IN ('OPPOSITE', 'SAME')
                BEGIN
                    UPDATE Demo.Accounts SET Balance += 1 WHERE AccountID = 1;
                    UPDATE Demo.Accounts SET Balance += 1 WHERE AccountID = 2;
                END
                ELSE
                BEGIN
                    IF @Move = 'CONVERT'
                        SELECT @b = Balance FROM Demo.Accounts WHERE AccountID = 1;
                    ELSE
                        SELECT @b = Balance FROM Demo.Accounts WITH (UPDLOCK) WHERE AccountID = 1;
                    UPDATE Demo.Accounts SET Balance = @b + 1 WHERE AccountID = 1;
                END
            COMMIT;
            SET @ok = 1;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            IF ERROR_NUMBER() = 1205 SET @dl += 1;
            ELSE SET @other = LEFT(ERROR_MESSAGE(), 200);
        END CATCH
    END

    INSERT Demo.Outcomes (RunTag, Who, Attempts, Deadlocks, OtherError, ElapsedMs, StartedUtc)
    VALUES (@RunTag, 'demo', @attempt, @dl, @other, DATEDIFF(millisecond, @t0, SYSDATETIME()), @started);
    EXEC Demo.usp_WaitFor @RunTag, 'done';
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_LookupRace -- scenario E. The worker flips account 5000's Status
  (a column in IX_Accounts_Ref's key) for @Seconds; meanwhile this session
  reads account 5000's Balance by AccountRef -- a seek on IX_Accounts_Ref
  and a key lookup into the clustered index. The writer locks the clustered
  row, then the index row; the reader locks the index row, then the
  clustered row. Opposite order, and no transaction in sight.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_LookupRace
    @RunTag  varchar(30),
    @Seconds int = 5
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @started datetime2(3) = SYSUTCDATETIME(), @t0 datetime2(7), @i int = 0, @dl int = 0,
            @other nvarchar(200), @b decimal(12,2), @move varchar(30) = 'WRITER:' + CAST(@Seconds AS varchar(5));

    EXEC Demo.usp_Send @RunTag, @move;
    EXEC Demo.usp_WaitFor @RunTag, 'holding';
    SET @t0 = SYSDATETIME();
    DECLARE @until datetime2(7) = DATEADD(second, @Seconds, @t0);
    WHILE SYSDATETIME() < @until
    BEGIN
        BEGIN TRY
            SELECT @b = Balance FROM Demo.Accounts WHERE AccountRef = 'ACC0005000';
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() = 1205 SET @dl += 1;
            ELSE SET @other = LEFT(ERROR_MESSAGE(), 200);
        END CATCH
        SET @i += 1;
    END

    INSERT Demo.Outcomes (RunTag, Who, Attempts, Deadlocks, Iterations, OtherError, ElapsedMs, StartedUtc)
    VALUES (@RunTag, 'demo', 1, @dl, @i, @other, DATEDIFF(millisecond, @t0, SYSDATETIME()), @started);
    EXEC Demo.usp_WaitFor @RunTag, 'done', 60;
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the DeadlockDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
