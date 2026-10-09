/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, BlockingDemo, and puts everything inside it.
     Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no instance setting (not even 'blocked process threshold')
        - no existing database is touched

     Inside BlockingDemo it turns on Service Broker (ENABLE_BROKER).

  WHY SERVICE BROKER, AND WHY FOUR QUEUES

     A blocking chain needs several sessions at once: a head blocker, sessions
     waiting on it, and sessions waiting on THEM. Service Broker activation
     runs a procedure in a background session when a message arrives on a
     queue -- see the rcsi-snapshot-isolation topic. One queue adds extra
     readers only gradually, so each worker has its own queue (Q1 to Q4), and
     each starts at once when sent a command.

  Creates, all inside BlockingDemo:
     Demo.Items              - six rows the workers fight over
     Demo.WorkerLog          - what each worker did, and when
     Demo.usp_Worker_Run     - the shared worker body
     Demo.usp_Worker1..4     - one activation procedure per queue
     Q1..Q4, S1..S4          - the queues and their services
     Demo.usp_Send           - send a worker a command
     Demo.usp_WaitForLog     - wait until a worker logs an event
     Demo.usp_WaitBlocked    - wait until N sessions in this database are blocked

  COST: under 100 MB, all inside BlockingDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create BlockingDemo, with Service Broker ===';
GO

IF DB_ID('BlockingDemo') IS NOT NULL
BEGIN
    RAISERROR('BlockingDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE BlockingDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE BlockingDemo;
END
GO

CREATE DATABASE BlockingDemo;
GO

ALTER DATABASE BlockingDemo SET RECOVERY SIMPLE;
ALTER DATABASE BlockingDemo SET ENABLE_BROKER;
GO

USE BlockingDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: tables ===';
GO

CREATE TABLE Demo.Items
(
    ItemID int NOT NULL PRIMARY KEY,
    Qty    int NOT NULL
);
INSERT Demo.Items (ItemID, Qty) VALUES (1, 0), (2, 0), (3, 0), (4, 0), (5, 0), (6, 0);
GO

CREATE TABLE Demo.WorkerLog
(
    LogID     int            IDENTITY(1,1) NOT NULL PRIMARY KEY,
    RunTag    varchar(20)    NOT NULL,      -- which scenario run this belongs to
    Worker    varchar(10)    NOT NULL,      -- Q1..Q4
    Command   nvarchar(40)   NOT NULL,
    Event     varchar(40)    NOT NULL,
    Spid      int            NOT NULL,
    ErrorNum  int            NULL,
    At        datetime2(3)   NOT NULL CONSTRAINT DF_BDLog_At DEFAULT SYSDATETIME()
);
GO


PRINT '=== STEP 3: the workers ===';
GO

/*------------------------------------------------------------------------------
  Demo.usp_Worker_Run -- the body every worker runs, in its own session.

  The message is "<runtag>|<command>". Commands:

     HEAD:<ms>    take an exclusive lock on item 1, then sit for <ms> with the
                  transaction open, doing nothing -- the classic head blocker:
                  an application that began a transaction and went quiet
     B1           lock item 2, THEN ask for item 1 (blocked by HEAD)
     B2           read item 1 under locking READ COMMITTED (blocked by HEAD)
     B3           read item 2 (blocked by B1, which holds it while it waits)
     DL_A         lock item 3, pause, then ask for item 4
     DL_B         lock item 4, pause, then ask for item 3   (a deadlock)

  Log rows written INSIDE an open transaction are uncommitted; the demo reads
  Demo.WorkerLog WITH (NOLOCK) so it can see them as they happen. Errors are
  caught and logged after the transaction has ended, so they always survive.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Worker_Run
    @Queue sysname
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @h uniqueidentifier, @body nvarchar(100), @type sysname;
    DECLARE @sql nvarchar(400) =
        N'WAITFOR (RECEIVE TOP (1) @h = conversation_handle, @body = CAST(message_body AS nvarchar(100)),
                   @type = message_type_name FROM ' + QUOTENAME(@Queue) + N'), TIMEOUT 1000;';
    EXEC sys.sp_executesql @sql, N'@h uniqueidentifier OUTPUT, @body nvarchar(100) OUTPUT, @type sysname OUTPUT',
         @h = @h OUTPUT, @body = @body OUTPUT, @type = @type OUTPUT;
    IF @h IS NULL RETURN;
    IF @type = N'http://schemas.microsoft.com/SQL/ServiceBroker/EndDialog'
    BEGIN
        END CONVERSATION @h;
        RETURN;
    END

    DECLARE @tag varchar(20) = LEFT(@body, CHARINDEX(N'|', @body) - 1);
    DECLARE @cmd nvarchar(40) = SUBSTRING(@body, CHARINDEX(N'|', @body) + 1, 40);
    DECLARE @w varchar(10) = @Queue;
    DECLARE @ms int = CASE WHEN CHARINDEX(N':', @cmd) > 0 THEN CAST(SUBSTRING(@cmd, CHARINDEX(N':', @cmd) + 1, 10) AS int) ELSE 0 END;
    DECLARE @delay datetime = DATEADD(millisecond, @ms, CAST(0 AS datetime));
    DECLARE @pause datetime = DATEADD(millisecond, 500, CAST(0 AS datetime));
    DECLARE @q int, @err int;

    BEGIN TRY
        INSERT Demo.WorkerLog (RunTag, Worker, Command, Event, Spid) VALUES (@tag, @w, @cmd, 'started', @@SPID);

        IF @cmd LIKE N'HEAD%'
        BEGIN
            BEGIN TRANSACTION;
                UPDATE Demo.Items SET Qty = Qty + 1 WHERE ItemID = 1;
                INSERT Demo.WorkerLog (RunTag, Worker, Command, Event, Spid) VALUES (@tag, @w, @cmd, 'holding item 1', @@SPID);
                WAITFOR DELAY @delay;
            COMMIT;
        END
        ELSE IF @cmd = N'B1'
        BEGIN
            BEGIN TRANSACTION;
                UPDATE Demo.Items SET Qty = Qty + 1 WHERE ItemID = 2;
                INSERT Demo.WorkerLog (RunTag, Worker, Command, Event, Spid) VALUES (@tag, @w, @cmd, 'holding item 2', @@SPID);
                UPDATE Demo.Items SET Qty = Qty + 1 WHERE ItemID = 1;
            COMMIT;
        END
        ELSE IF @cmd = N'B2'
            SELECT @q = Qty FROM Demo.Items WHERE ItemID = 1;
        ELSE IF @cmd = N'B3'
            SELECT @q = Qty FROM Demo.Items WHERE ItemID = 2;
        ELSE IF @cmd = N'DL_A'
        BEGIN
            BEGIN TRANSACTION;
                UPDATE Demo.Items SET Qty = Qty + 1 WHERE ItemID = 3;
                WAITFOR DELAY @pause;
                UPDATE Demo.Items SET Qty = Qty + 1 WHERE ItemID = 4;
            COMMIT;
        END
        ELSE IF @cmd = N'DL_B'
        BEGIN
            BEGIN TRANSACTION;
                UPDATE Demo.Items SET Qty = Qty + 1 WHERE ItemID = 4;
                WAITFOR DELAY @pause;
                UPDATE Demo.Items SET Qty = Qty + 1 WHERE ItemID = 3;
            COMMIT;
        END

        INSERT Demo.WorkerLog (RunTag, Worker, Command, Event, Spid) VALUES (@tag, @w, @cmd, 'done', @@SPID);
    END TRY
    BEGIN CATCH
        SET @err = ERROR_NUMBER();
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT Demo.WorkerLog (RunTag, Worker, Command, Event, Spid, ErrorNum) VALUES (@tag, @w, @cmd, 'failed', @@SPID, @err);
    END CATCH

    END CONVERSATION @h;
END
GO

CREATE OR ALTER PROCEDURE Demo.usp_Worker1 AS EXEC Demo.usp_Worker_Run N'Q1';
GO
CREATE OR ALTER PROCEDURE Demo.usp_Worker2 AS EXEC Demo.usp_Worker_Run N'Q2';
GO
CREATE OR ALTER PROCEDURE Demo.usp_Worker3 AS EXEC Demo.usp_Worker_Run N'Q3';
GO
CREATE OR ALTER PROCEDURE Demo.usp_Worker4 AS EXEC Demo.usp_Worker_Run N'Q4';
GO

CREATE QUEUE Q1 WITH STATUS = ON, ACTIVATION (STATUS = ON, PROCEDURE_NAME = Demo.usp_Worker1, MAX_QUEUE_READERS = 1, EXECUTE AS OWNER);
CREATE QUEUE Q2 WITH STATUS = ON, ACTIVATION (STATUS = ON, PROCEDURE_NAME = Demo.usp_Worker2, MAX_QUEUE_READERS = 1, EXECUTE AS OWNER);
CREATE QUEUE Q3 WITH STATUS = ON, ACTIVATION (STATUS = ON, PROCEDURE_NAME = Demo.usp_Worker3, MAX_QUEUE_READERS = 1, EXECUTE AS OWNER);
CREATE QUEUE Q4 WITH STATUS = ON, ACTIVATION (STATUS = ON, PROCEDURE_NAME = Demo.usp_Worker4, MAX_QUEUE_READERS = 1, EXECUTE AS OWNER);
GO
CREATE SERVICE S1 ON QUEUE Q1 ([DEFAULT]);
CREATE SERVICE S2 ON QUEUE Q2 ([DEFAULT]);
CREATE SERVICE S3 ON QUEUE Q3 ([DEFAULT]);
CREATE SERVICE S4 ON QUEUE Q4 ([DEFAULT]);
GO


PRINT '=== STEP 4: the helpers ===';
GO

-- Send "<runtag>|<command>" to worker @Worker (1 to 4). Must not be called
-- inside an open transaction: SEND is transactional.
CREATE OR ALTER PROCEDURE Demo.usp_Send
    @Worker  int,
    @RunTag  varchar(20),
    @Command nvarchar(40)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @svc sysname = N'S' + CAST(@Worker AS nvarchar(2)), @h uniqueidentifier;
    DECLARE @msg nvarchar(100) = CAST(@RunTag AS nvarchar(20)) + N'|' + @Command;
    BEGIN DIALOG CONVERSATION @h FROM SERVICE @svc TO SERVICE @svc ON CONTRACT [DEFAULT] WITH ENCRYPTION = OFF;
    SEND ON CONVERSATION @h (@msg);
END
GO

-- Wait (50 ms polls, at most @TimeoutMs) until worker @Worker has logged
-- @Event for @RunTag. Read-only, WITH (NOLOCK): the event may still be inside
-- the worker's open transaction.
CREATE OR ALTER PROCEDURE Demo.usp_WaitForLog
    @RunTag    varchar(20),
    @Worker    varchar(10),
    @Event     varchar(40),
    @TimeoutMs int = 10000
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 datetime2(3) = SYSDATETIME();
    WHILE NOT EXISTS (SELECT 1 FROM Demo.WorkerLog WITH (NOLOCK)
                      WHERE RunTag = @RunTag AND Worker = @Worker AND Event = @Event)
      AND DATEDIFF(millisecond, @t0, SYSDATETIME()) < @TimeoutMs
        WAITFOR DELAY '00:00:00.050';
END
GO

-- Wait until at least @Count sessions in this database are blocked.
CREATE OR ALTER PROCEDURE Demo.usp_WaitBlocked
    @Count     int,
    @TimeoutMs int = 10000
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 datetime2(3) = SYSDATETIME();
    WHILE (SELECT COUNT(*) FROM sys.dm_exec_requests
           WHERE database_id = DB_ID() AND blocking_session_id <> 0) < @Count
      AND DATEDIFF(millisecond, @t0, SYSDATETIME()) < @TimeoutMs
        WAITFOR DELAY '00:00:00.050';
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the BlockingDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
