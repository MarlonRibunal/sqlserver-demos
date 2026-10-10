/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, LogFullDemo, and puts everything inside it.
     Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched

     Inside LogFullDemo it turns on Service Broker (ENABLE_BROKER), and
     02-demo.sql switches LogFullDemo between SIMPLE and FULL recovery,
     changes ITS log file's size and growth, and backs it up to the NULL
     device (DISK = N'NUL') -- which writes no file anywhere and must never
     be done to a database you need to restore. Scenario D of 02-demo.sql
     briefly creates a second database, LogFullDemo_VLF, and drops it again.

  WHY SERVICE BROKER

     Scenario B needs another session holding a transaction open while this
     one watches. Service Broker activation runs Demo.usp_Holder in a
     background session when it receives a message -- see the
     rcsi-snapshot-isolation topic for the technique.

  Creates, all inside LogFullDemo:
     Demo.Ledger            - the table the background holder writes to
     Demo.Churn             - the table Demo.usp_GenerateLog writes to
     Demo.HolderStatus      - what the background session is doing
     Demo.usp_Holder        - the background session (activation procedure)
     HolderQueue / HolderService
     Demo.usp_Holder_Start  - start it, wait until it holds its transaction
     Demo.HolderControl     - the switch that releases it
     Demo.usp_Holder_Release
     Demo.usp_GenerateLog   - write roughly @MB megabytes of log
     Demo.usp_ShrinkLog     - shrink the log to a target size, reliably
     Demo.usp_NullBackup    - BACKUP DATABASE / LOG to the null device
     Demo.LogStates         - one row per measurement of the log

  COST: up to about 1 GB of transaction log at the peak of the demo, all
  inside LogFullDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create LogFullDemo ===';
GO

IF DB_ID('LogFullDemo') IS NOT NULL
BEGIN
    RAISERROR('LogFullDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE LogFullDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE LogFullDemo;
END
GO

CREATE DATABASE LogFullDemo;
GO

ALTER DATABASE LogFullDemo SET RECOVERY SIMPLE;
ALTER DATABASE LogFullDemo SET ENABLE_BROKER;
-- A known starting point for the log: 64 MB, growing 64 MB at a time.
ALTER DATABASE LogFullDemo MODIFY FILE (NAME = N'LogFullDemo_log', SIZE = 64MB, FILEGROWTH = 64MB);
GO

USE LogFullDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: tables ===';
GO

CREATE TABLE Demo.Ledger
(
    ID      int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Payload char(2000)        NOT NULL
);

-- Where Demo.usp_GenerateLog does its inserting and deleting: a table of its
-- own, so that it never touches the row the background holder keeps locked.
CREATE TABLE Demo.Churn
(
    ID      int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Payload char(2000)        NOT NULL
);

CREATE TABLE Demo.HolderStatus
(
    ID    int          NOT NULL PRIMARY KEY,
    State varchar(20)  NOT NULL,
    Spid  int          NULL,
    At    datetime2(3) NULL
);
INSERT Demo.HolderStatus (ID, State, At) VALUES (1, 'idle', SYSDATETIME());

-- The release switch. A separate table, because the holder keeps a lock on
-- its own HolderStatus row while it holds.
CREATE TABLE Demo.HolderControl
(
    ID      int NOT NULL PRIMARY KEY,
    Release bit NOT NULL
);
INSERT Demo.HolderControl (ID, Release) VALUES (1, 0);

CREATE TABLE Demo.LogStates
(
    StateID        int            IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Scenario       varchar(60)    NOT NULL,
    Label          varchar(90)    NOT NULL,
    RecoveryModel  varchar(20)    NULL,
    LogSizeMB      decimal(10,1)  NULL,
    LogUsedMB      decimal(10,1)  NULL,
    LogUsedPct     decimal(6,1)   NULL,
    ReuseWait      nvarchar(60)   NULL,     -- sys.databases.log_reuse_wait_desc
    VLFs           int            NULL,     -- sys.dm_db_log_info
    ActiveVLFs     int            NULL,
    CapturedAt     datetime2(3)   NOT NULL CONSTRAINT DF_LFStates_CapturedAt DEFAULT SYSDATETIME()
);
GO


PRINT '=== STEP 3: procedures ===';
GO

/*------------------------------------------------------------------------------
  Demo.usp_Snapshot -- record the state of this database's log.

     LogUsed / LogSize      sys.dm_db_log_space_usage
     ReuseWait              sys.databases.log_reuse_wait_desc: WHY the log
                            cannot currently be truncated (NOTHING, LOG_BACKUP,
                            ACTIVE_TRANSACTION, CHECKPOINT, REPLICATION, ...).
                            The single most useful column for a full log.
     VLFs / ActiveVLFs      sys.dm_db_log_info: the log file's virtual log
                            files, and how many are active (cannot be reused)
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Snapshot
    @Scenario varchar(60),
    @Label    varchar(90)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT Demo.LogStates (Scenario, Label, RecoveryModel, LogSizeMB, LogUsedMB, LogUsedPct, ReuseWait, VLFs, ActiveVLFs)
    SELECT  @Scenario, @Label,
            d.recovery_model_desc,
            u.total_log_size_in_bytes / 1048576.0,
            u.used_log_space_in_bytes / 1048576.0,
            u.used_log_space_in_percent,
            d.log_reuse_wait_desc,
            (SELECT COUNT(*) FROM sys.dm_db_log_info(DB_ID())),
            (SELECT COUNT(*) FROM sys.dm_db_log_info(DB_ID()) WHERE vlf_active = 1)
    FROM    sys.dm_db_log_space_usage AS u
    CROSS JOIN sys.databases AS d
    WHERE   d.database_id = DB_ID();
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_GenerateLog -- write about @MB megabytes of log: insert rows of
  2,000 bytes in committed batches of 1,000, then delete them again. Each
  batch commits, so this procedure never holds a transaction open itself.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_GenerateLog
    @MB int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @batches int = CEILING(@MB / 4.0), @b int = 0;    -- ~4 MB of log per insert+delete batch
    WHILE @b < @batches
    BEGIN
        INSERT Demo.Churn (Payload)
        SELECT TOP (1000) 'x' FROM sys.all_columns;
        DELETE Demo.Churn;
        SET @b += 1;
    END
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_ShrinkLog -- shrink the log to @TargetMB, for real.

  One DBCC SHRINKFILE cannot release the ACTIVE part of the log, and that
  part is often at the end of the file. So: checkpoint, shrink, write a
  little log so the active part wraps round to the start of the file, and
  repeat -- at most ten times, until the file is no bigger than the target.
  (The same loop, by hand, is how a bloated log is usually brought back.)
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_ShrinkLog
    @TargetMB int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @i int = 0;
    WHILE @i < 10 AND (SELECT size / 128 FROM sys.database_files WHERE type_desc = 'LOG') > @TargetMB + 1
    BEGIN
        CHECKPOINT;
        DBCC SHRINKFILE (N'LogFullDemo_log', @TargetMB) WITH NO_INFOMSGS;
        INSERT Demo.Churn (Payload) SELECT TOP (100) 'x' FROM sys.all_columns;
        DELETE Demo.Churn;
        SET @i += 1;
    END
END
GO

-- BACKUP DATABASE or BACKUP LOG of this database to the null device. 'NUL'
-- works on Windows and Linux (DISK = '/dev/null' does not, on Linux).
CREATE OR ALTER PROCEDURE Demo.usp_NullBackup
    @Kind varchar(10)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql nvarchar(200) =
        N'BACKUP ' + CASE @Kind WHEN 'LOG' THEN N'LOG' ELSE N'DATABASE' END + N' LogFullDemo TO DISK = N''NUL'';';
    EXEC sys.sp_executesql @sql;
END
GO

/*------------------------------------------------------------------------------
  The background session. On the message HOLD it opens a transaction, writes
  ONE small row, reports 'holding' (inside its transaction -- the demo reads
  it WITH (NOLOCK)), and then keeps the transaction open until the demo sets
  Demo.HolderControl.Release (at most two minutes), commits, and reports
  'done'. One open transaction, one row: that is all it takes.

  It holds until RELEASED rather than for a fixed time because how long the
  demo needs depends on how fast the instance writes log; a fixed hold that
  ran out early would let the log truncate and prove nothing.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Holder
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @h uniqueidentifier, @body nvarchar(100), @type sysname;
    WAITFOR (RECEIVE TOP (1) @h = conversation_handle, @body = CAST(message_body AS nvarchar(100)),
                             @type = message_type_name FROM HolderQueue), TIMEOUT 1000;
    IF @h IS NULL RETURN;
    IF @type = N'http://schemas.microsoft.com/SQL/ServiceBroker/EndDialog'
    BEGIN
        END CONVERSATION @h;
        RETURN;
    END

    DECLARE @t0 datetime2(3) = SYSDATETIME();

    BEGIN TRANSACTION;
        INSERT Demo.Ledger (Payload) VALUES ('held open');
        UPDATE Demo.HolderStatus SET State = 'holding', Spid = @@SPID, At = SYSDATETIME() WHERE ID = 1;
        WHILE (SELECT Release FROM Demo.HolderControl WITH (NOLOCK) WHERE ID = 1) = 0
          AND DATEDIFF(second, @t0, SYSDATETIME()) < 120
            WAITFOR DELAY '00:00:00.100';
    COMMIT;

    UPDATE Demo.HolderStatus SET State = 'done', Spid = @@SPID, At = SYSDATETIME() WHERE ID = 1;
    END CONVERSATION @h;
END
GO

CREATE QUEUE HolderQueue
    WITH STATUS = ON, ACTIVATION (STATUS = ON, PROCEDURE_NAME = Demo.usp_Holder, MAX_QUEUE_READERS = 1, EXECUTE AS OWNER);
CREATE SERVICE HolderService ON QUEUE HolderQueue ([DEFAULT]);
GO

-- Arm the release switch, send HOLD, and wait until the holder reports
-- 'holding'. Never called inside an open transaction (SEND is transactional).
CREATE OR ALTER PROCEDURE Demo.usp_Holder_Start
    @HolderSpid int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE Demo.HolderControl SET Release = 0 WHERE ID = 1;
    DECLARE @before datetime2(3) = (SELECT At FROM Demo.HolderStatus WITH (NOLOCK) WHERE ID = 1);
    DECLARE @h uniqueidentifier, @msg nvarchar(40) = N'HOLD';
    BEGIN DIALOG CONVERSATION @h FROM SERVICE HolderService TO SERVICE 'HolderService' ON CONTRACT [DEFAULT] WITH ENCRYPTION = OFF;
    SEND ON CONVERSATION @h (@msg);

    DECLARE @state varchar(20) = '', @at datetime2(3) = @before, @i int = 0;
    WHILE (@state <> 'holding' OR @at <= @before) AND @i < 200
    BEGIN
        WAITFOR DELAY '00:00:00.050';
        SELECT @state = State, @at = At, @HolderSpid = Spid FROM Demo.HolderStatus WITH (NOLOCK) WHERE ID = 1;
        SET @i += 1;
    END
    IF @state <> 'holding'
        RAISERROR('The background session did not start within 10 seconds. Is Service Broker enabled?', 16, 1);
END
GO

-- Release the holder and wait until it has committed.
CREATE OR ALTER PROCEDURE Demo.usp_Holder_Release
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE Demo.HolderControl SET Release = 1 WHERE ID = 1;
    DECLARE @state varchar(20) = '', @i int = 0;
    WHILE @state <> 'done' AND @i < 1200
    BEGIN
        WAITFOR DELAY '00:00:00.050';
        SELECT @state = State FROM Demo.HolderStatus WITH (NOLOCK) WHERE ID = 1;
        SET @i += 1;
    END
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the LogFullDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
