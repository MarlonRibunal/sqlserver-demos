/*==============================================================================
  01-setup.sql          RUN ONCE. Takes about 15 seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, WaitDemo, and puts everything inside it.
     Nothing else on the instance is modified:

        - Service Broker is enabled on WaitDemo only (see WHY SERVICE
          BROKER)
        - no instance setting is changed, and the instance's wait
          statistics are never cleared: the demo only reads them, and works
          from before/after differences
        - no buffer pool flush for the instance: scenario C takes WaitDemo
          OFFLINE and back ONLINE, which empties the cache of WaitDemo's
          pages only
        - no compatibility level changed, no trace flag set
        - no existing database touched

  Creates, all inside WaitDemo:
     Demo.Accounts         - 10 rows; scenario A locks one
     Demo.Control          - tells the reader the lock is held
     Demo.Big              - 400,000 rows, about 100 MB; scenarios C and D
     Demo.Log              - where scenario B inserts
     Demo.Waits            - each measurement's waits, from this session's
                             sys.dm_exec_session_wait_stats
     Demo.Runs             - each measurement's elapsed and CPU time
     Demo.Verdicts         - one row per claim
     Demo.usp_Snap / usp_Measure - the measuring harness
     Demo.usp_Reader_*     - scenario A's background reader
     Demo.usp_A_Run        - scenario A: hold a lock, watch the reader wait

  WHY SERVICE BROKER

     Scenario A needs a second session that gets blocked while this one
     holds a lock, so this one can watch it wait. Sending a message to a
     queue in WaitDemo runs its activation procedure in a background session.

  COST: about 110 MB, all inside WaitDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create WaitDemo ===';
GO

IF DB_ID('WaitDemo') IS NOT NULL
BEGIN
    RAISERROR('WaitDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    IF DATABASEPROPERTYEX('WaitDemo', 'Status') = 'ONLINE'
        ALTER DATABASE WaitDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE WaitDemo;
END
GO

CREATE DATABASE WaitDemo;
GO

ALTER DATABASE WaitDemo SET RECOVERY SIMPLE;
ALTER DATABASE WaitDemo SET ENABLE_BROKER;
GO

USE WaitDemo;
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
    AccountID int            NOT NULL CONSTRAINT PK_Accounts PRIMARY KEY,
    Balance   decimal(12,2)  NOT NULL
);
INSERT Demo.Accounts (AccountID, Balance)
SELECT TOP (10) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 100.00 FROM sys.all_columns;
GO

-- About 100 MB: big enough that reading it from disk takes visible time.
CREATE TABLE Demo.Big
(
    ID       int            NOT NULL CONSTRAINT PK_Big PRIMARY KEY CLUSTERED,
    GroupID  int            NOT NULL,
    Amount   decimal(12,2)  NOT NULL,
    Note     varchar(40)    NOT NULL,
    pad      char(200)      NOT NULL CONSTRAINT DF_Big_pad DEFAULT ('x')
);
;WITH n AS
(
    SELECT TOP (400000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.Big WITH (TABLOCK) (ID, GroupID, Amount, Note)
SELECT rn, rn % 4000, rn % 1000 + 0.25, 'note ' + CAST(rn AS varchar(10))
FROM   n;
CREATE INDEX IX_Big_Group ON Demo.Big (GroupID) INCLUDE (Amount);
GO

CREATE TABLE Demo.Log
(
    LogID  int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Log PRIMARY KEY,
    Msg    varchar(40)       NOT NULL,
    At     datetime2(3)      NOT NULL CONSTRAINT DF_Log_At DEFAULT SYSDATETIME()
);
GO


PRINT '=== STEP 3: the harness ===';
GO

CREATE TABLE Demo.Snap
(
    Tag       varchar(20)   NOT NULL,
    WaitType  nvarchar(60)  NOT NULL,
    Tasks     bigint        NOT NULL,
    WaitMs    bigint        NOT NULL,
    SignalMs  bigint        NOT NULL
);
GO

CREATE TABLE Demo.Waits
(
    Scenario  char(1)       NOT NULL,
    Label     varchar(80)   NOT NULL,
    WaitType  nvarchar(60)  NOT NULL,
    Tasks     bigint        NOT NULL,
    WaitMs    bigint        NOT NULL,
    SignalMs  bigint        NOT NULL     -- of WaitMs: time spent runnable, waiting for a CPU
);
GO

CREATE TABLE Demo.Runs
(
    Scenario   char(1)      NOT NULL,
    Label      varchar(80)  NOT NULL,
    ElapsedMs  bigint       NOT NULL,
    CpuMs      bigint       NOT NULL,
    WaitMs     bigint       NOT NULL,    -- every wait this session recorded
    PreemptMs  bigint       NOT NULL,    -- of WaitMs: PREEMPTIVE_% (time in an OS call)
    FileReads  bigint       NOT NULL,    -- physical reads from WaitDemo's files (sys.dm_io_virtual_file_stats)
    ReadStallMs bigint      NOT NULL,    -- the time those reads took, from the file's point of view
    Seq        int          IDENTITY(1,1) NOT NULL
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

/*------------------------------------------------------------------------------
  Demo.usp_Snap -- copy this session's waits so far
  (sys.dm_exec_session_wait_stats) into Demo.Snap under @Tag.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Snap
    @Tag varchar(20)
AS
BEGIN
    SET NOCOUNT ON;
    DELETE Demo.Snap WHERE Tag = @Tag;
    INSERT Demo.Snap (Tag, WaitType, Tasks, WaitMs, SignalMs)
    SELECT @Tag, wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
    FROM   sys.dm_exec_session_wait_stats
    WHERE  session_id = @@SPID;
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_Measure -- run @Sql (a batch of T-SQL) in this session, and
  record where its time went: elapsed, CPU (sys.dm_exec_requests), each
  wait type it added to this session's waits, and the physical reads from
  WaitDemo's files (sys.dm_io_virtual_file_stats: anyone's, but nothing
  else runs in WaitDemo). The harness's own waits are
  tiny and outside the timed part.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Measure
    @Scenario char(1),
    @Label    varchar(80),
    @Sql      nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @c0 bigint, @c1 bigint, @t0 datetime2(7), @t1 datetime2(7), @r0 bigint, @s0 bigint, @r1 bigint, @s1 bigint;

    EXEC Demo.usp_Snap 'before';
    SELECT @r0 = SUM(num_of_reads), @s0 = SUM(io_stall_read_ms) FROM sys.dm_io_virtual_file_stats(DB_ID(), NULL);
    SELECT @c0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    SET @t0 = SYSDATETIME();

    EXEC sys.sp_executesql @Sql;

    SET @t1 = SYSDATETIME();
    SELECT @c1 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    SELECT @r1 = SUM(num_of_reads), @s1 = SUM(io_stall_read_ms) FROM sys.dm_io_virtual_file_stats(DB_ID(), NULL);
    EXEC Demo.usp_Snap 'after';

    INSERT Demo.Waits (Scenario, Label, WaitType, Tasks, WaitMs, SignalMs)
    SELECT @Scenario, @Label, a.WaitType,
           a.Tasks - ISNULL(b.Tasks, 0), a.WaitMs - ISNULL(b.WaitMs, 0), a.SignalMs - ISNULL(b.SignalMs, 0)
    FROM   Demo.Snap AS a
    LEFT JOIN Demo.Snap AS b ON b.Tag = 'before' AND b.WaitType = a.WaitType
    WHERE  a.Tag = 'after'
      AND  a.Tasks - ISNULL(b.Tasks, 0) > 0;

    INSERT Demo.Runs (Scenario, Label, ElapsedMs, CpuMs, WaitMs, PreemptMs, FileReads, ReadStallMs)
    SELECT @Scenario, @Label, DATEDIFF(millisecond, @t0, @t1), @c1 - @c0,
           ISNULL((SELECT SUM(WaitMs) FROM Demo.Waits WHERE Scenario = @Scenario AND Label = @Label), 0),
           ISNULL((SELECT SUM(WaitMs) FROM Demo.Waits WHERE Scenario = @Scenario AND Label = @Label AND WaitType LIKE N'PREEMPTIVE[_]%'), 0),
           @r1 - @r0, @s1 - @s0;
END
GO


PRINT '=== STEP 4: the background reader (scenario A) ===';
GO

-- Set to 1 (uncommitted, inside the demo's transaction) once the lock is
-- taken; the reader polls it WITH (NOLOCK) before it reads.
CREATE TABLE Demo.Control (ID int NOT NULL PRIMARY KEY, Locked bit NOT NULL);
INSERT Demo.Control (ID, Locked) VALUES (1, 0);
GO

CREATE TABLE Demo.ReaderStatus
(
    Token     uniqueidentifier NOT NULL PRIMARY KEY,
    Spid      int              NULL,
    State     varchar(20)      NOT NULL,     -- started, done
    ReadMs    int              NULL,
    LockWaitMs bigint          NULL,         -- LCK_M_% waits during the read
    At        datetime2(3)     NOT NULL CONSTRAINT DF_ReaderStatus_At DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  Demo.usp_Reader -- the activation procedure. Reports its session id,
  waits until Demo.Control says the demo holds its lock, then reads
  account 1 under READ COMMITTED and reports how long that took and
  how long it waited on locks. Its waits come from its own session's
  sys.dm_exec_session_wait_stats, before and after: activation sessions are
  reused, so they already have some.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Reader
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @h uniqueidentifier, @type sysname, @body varbinary(max);
    WAITFOR (RECEIVE TOP (1) @h = conversation_handle, @type = message_type_name, @body = message_body
             FROM Demo.ReaderQueue), TIMEOUT 1000;
    IF @h IS NULL RETURN;
    IF @type <> N'DEFAULT'
    BEGIN
        END CONVERSATION @h;
        RETURN;
    END

    DECLARE @token uniqueidentifier = CAST(CAST(@body AS nvarchar(100)) AS uniqueidentifier);
    DECLARE @w0 bigint, @w1 bigint, @t0 datetime2(7), @b decimal(12,2);

    INSERT Demo.ReaderStatus (Token, Spid, State) VALUES (@token, @@SPID, 'started');

    -- Wait (up to 10 s) until the demo holds its lock.
    DECLARE @i int = 0;
    WHILE (SELECT Locked FROM Demo.Control WITH (NOLOCK) WHERE ID = 1) = 0 AND @i < 200
    BEGIN
        WAITFOR DELAY '00:00:00.050';
        SET @i += 1;
    END

    SELECT @w0 = ISNULL(SUM(wait_time_ms), 0) FROM sys.dm_exec_session_wait_stats
    WHERE  session_id = @@SPID AND wait_type LIKE N'LCK[_]M[_]%';
    SET @t0 = SYSDATETIME();

    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    SELECT @b = Balance FROM Demo.Accounts WHERE AccountID = 1;

    SELECT @w1 = ISNULL(SUM(wait_time_ms), 0) FROM sys.dm_exec_session_wait_stats
    WHERE  session_id = @@SPID AND wait_type LIKE N'LCK[_]M[_]%';

    UPDATE Demo.ReaderStatus
    SET    State = 'done', ReadMs = DATEDIFF(millisecond, @t0, SYSDATETIME()), LockWaitMs = @w1 - @w0, At = SYSDATETIME()
    WHERE  Token = @token;
    END CONVERSATION @h;
END
GO

CREATE QUEUE Demo.ReaderQueue
    WITH STATUS = ON, ACTIVATION (STATUS = ON, PROCEDURE_NAME = Demo.usp_Reader, MAX_QUEUE_READERS = 1, EXECUTE AS OWNER);
CREATE SERVICE ReaderService ON QUEUE Demo.ReaderQueue ([DEFAULT]);
GO

/*------------------------------------------------------------------------------
  Demo.usp_Reader_Start -- start the reader and wait until it has reported
  its session id. Must be called OUTSIDE a transaction: SEND is
  transactional.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Reader_Start
    @Token uniqueidentifier OUTPUT,
    @Spid  int              OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @h uniqueidentifier, @m nvarchar(100), @i int = 0;
    SET @Token = NEWID();
    SET @m = CAST(@Token AS nvarchar(100));
    SET @Spid = NULL;
    UPDATE Demo.Control SET Locked = 0 WHERE ID = 1;
    BEGIN DIALOG CONVERSATION @h FROM SERVICE ReaderService TO SERVICE 'ReaderService' ON CONTRACT [DEFAULT] WITH ENCRYPTION = OFF;
    SEND ON CONVERSATION @h (@m);
    WHILE @Spid IS NULL AND @i < 200
    BEGIN
        WAITFOR DELAY '00:00:00.050';
        SELECT @Spid = Spid FROM Demo.ReaderStatus WITH (NOLOCK) WHERE Token = @Token;
        SET @i += 1;
    END
END
GO

-- Wait (up to 10 s) for the reader to finish, and return what it reported.
CREATE OR ALTER PROCEDURE Demo.usp_Reader_Wait
    @Token      uniqueidentifier,
    @ReadMs     int    OUTPUT,
    @LockWaitMs bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @state varchar(20) = '', @i int = 0;
    WHILE @state <> 'done' AND @i < 200
    BEGIN
        WAITFOR DELAY '00:00:00.050';
        SELECT @state = State, @ReadMs = ReadMs, @LockWaitMs = LockWaitMs
        FROM   Demo.ReaderStatus WITH (NOLOCK) WHERE Token = @Token;
        SET @i += 1;
    END
END
GO


/*------------------------------------------------------------------------------
  Demo.usp_A_Run -- scenario A: start the reader, take an update lock on
  account 1 and hold it for 2 seconds, watching sys.dm_os_waiting_tasks for
  the reader's lock wait (as you would during an incident: the last sighting
  gives the longest wait_duration_ms); roll back, and collect what the
  reader reported.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_A_Run
    @Label        varchar(80),
    @WaitType     nvarchar(60)  OUTPUT,
    @BlockedBy    int           OUTPUT,
    @Resource     nvarchar(200) OUTPUT,
    @ReadMs       int           OUTPUT,
    @LockWaitMs   bigint        OUTPUT,
    @SeenWaitMs   bigint        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @token uniqueidentifier, @spid int, @i int = 0;
    SELECT @WaitType = NULL, @BlockedBy = NULL, @Resource = NULL, @SeenWaitMs = NULL;

    EXEC Demo.usp_Reader_Start @token OUTPUT, @spid OUTPUT;
    IF @spid IS NULL RETURN;    -- the reader never started

    BEGIN TRANSACTION;
        UPDATE Demo.Accounts SET Balance += 1 WHERE AccountID = 1;
        UPDATE Demo.Control SET Locked = 1 WHERE ID = 1;     -- the reader sees this WITH (NOLOCK)

        -- Watch the reader for 2 seconds, as you would during an incident.
        WHILE @i < 40
        BEGIN
            WAITFOR DELAY '00:00:00.050';
            SELECT TOP (1) @WaitType = wait_type, @BlockedBy = blocking_session_id, @Resource = LEFT(resource_description, 200),
                           @SeenWaitMs = wait_duration_ms
            FROM   sys.dm_os_waiting_tasks
            WHERE  session_id = @spid AND wait_type LIKE N'LCK[_]M[_]%';
            SET @i += 1;
        END
    ROLLBACK;

    EXEC Demo.usp_Reader_Wait @token, @ReadMs OUTPUT, @LockWaitMs OUTPUT;
END
GO

PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the WaitDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
