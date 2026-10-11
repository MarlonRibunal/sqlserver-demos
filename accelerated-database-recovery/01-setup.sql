/*==============================================================================
  01-setup.sql          RUN ONCE. Takes under a minute.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, AdrDemo, and puts everything inside it.
     Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched

     Inside AdrDemo it turns on Service Broker (for the background session
     in scenario D). The demo switches Accelerated Database Recovery off and
     on for AdrDemo, and AdrDemo only.

  WHY SERVICE BROKER

     Scenario D needs a second session that opens a transaction and leaves
     it open while this one works. Service Broker activation runs
     Demo.usp_Holder in a background session (see the rcsi-snapshot-isolation
     and transaction-log-full topics), so the demo runs from one window.

  Creates, all inside AdrDemo:
     Demo.Big                - 1,000,000 rows to update and roll back
     Demo.Ledger             - the one row the background session writes
     Demo.Results            - one row per measurement
     Demo.usp_State          - log used, version store size, ADR on or off
     Demo.usp_BigUpdate      - the big transaction: update, measure, roll back
     Demo.usp_ResetLog       - shrink the log back to its starting size
     Demo.usp_CleanVersions  - run the version cleaner now
     Demo.usp_Holder / _Start / _Release, HolderQueue, HolderService
                             - the background session that holds a
                               transaction open

  COST: up to about 1.5 GB of log and version store at the demo's peak, all
  inside AdrDemo.

  REQUIRES SQL Server 2019 or later.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) < 15
BEGIN
    RAISERROR('Accelerated Database Recovery needs SQL Server 2019 or later.', 16, 1);
    SET NOEXEC ON;
END
GO

PRINT '=== STEP 1: create AdrDemo ===';
GO

IF DB_ID('AdrDemo') IS NOT NULL
BEGIN
    RAISERROR('AdrDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE AdrDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE AdrDemo;
END
GO

CREATE DATABASE AdrDemo;
GO

ALTER DATABASE AdrDemo SET RECOVERY SIMPLE;
ALTER DATABASE AdrDemo SET ENABLE_BROKER;
ALTER DATABASE AdrDemo MODIFY FILE (NAME = N'AdrDemo_log', SIZE = 64MB, FILEGROWTH = 64MB);
GO

USE AdrDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: tables ===';
GO

CREATE TABLE Demo.Big
(
    ID   int        NOT NULL CONSTRAINT PK_Big PRIMARY KEY CLUSTERED,
    V    int        NOT NULL,
    pad  char(200)  NOT NULL CONSTRAINT DF_Big_pad DEFAULT ('x')
);

;WITH n AS
(
    SELECT TOP (1000000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b CROSS JOIN sys.all_columns AS c
)
INSERT Demo.Big WITH (TABLOCK) (ID, V) SELECT rn, 0 FROM n;
GO

CREATE TABLE Demo.Ledger (ID int IDENTITY(1,1) NOT NULL PRIMARY KEY, Payload varchar(40) NOT NULL);

CREATE TABLE Demo.HolderStatus
(
    ID    int           NOT NULL PRIMARY KEY,
    State varchar(20)   NOT NULL,       -- idle | holding | done
    Spid  int           NULL,
    At    datetime2(3)  NOT NULL
);
INSERT Demo.HolderStatus (ID, State, At) VALUES (1, 'idle', SYSDATETIME());

CREATE TABLE Demo.HolderControl (ID int NOT NULL PRIMARY KEY, Release bit NOT NULL);
INSERT Demo.HolderControl (ID, Release) VALUES (1, 0);

CREATE TABLE Demo.Results
(
    Scenario    char(1)        NOT NULL,
    Label       varchar(60)    NOT NULL,
    Adr         bit            NULL,
    WorkMs      int            NULL,
    WorkCpuMs   int            NULL,
    RollbackMs  int            NULL,
    LogUsedMB   decimal(10,1)  NULL,
    LogSizeMB   decimal(10,1)  NULL,
    VersionsMB  decimal(10,1)  NULL,     -- the persistent version store
    TableMB     decimal(10,1)  NULL,     -- Demo.Big's size
    CapturedAt  datetime2(3)   NOT NULL CONSTRAINT DF_Results_CapturedAt DEFAULT SYSDATETIME()
);
GO


PRINT '=== STEP 3: measurement ===';
GO

/*------------------------------------------------------------------------------
  Demo.usp_State -- AdrDemo right now: log used and allocated, the size of
  the persistent version store, the size of Demo.Big, and whether ADR is on.

  The version store is the internal table persistent_version_store, inside
  the database; its size comes from its allocation units. The demo does NOT
  use sys.dm_tran_persistent_version_store_stats.persistent_version_store_size_kb:
  on the tested build that figure changed only when the cleaner ran, and
  read 136 KB while 300 MB of versions sat in the store.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_State
    @LogUsedMB decimal(10,1) OUTPUT,
    @LogSizeMB decimal(10,1) OUTPUT,
    @PvsMB     decimal(10,1) OUTPUT,
    @Adr       bit           OUTPUT,
    @TableMB   decimal(10,1) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @LogUsedMB = used_log_space_in_bytes / 1048576.0, @LogSizeMB = total_log_size_in_bytes / 1048576.0
    FROM   sys.dm_db_log_space_usage;
    SELECT @PvsMB = ISNULL(SUM(au.used_pages), 0) / 128.0
    FROM   sys.internal_tables AS it
    JOIN   sys.partitions AS p ON p.object_id = it.object_id
    JOIN   sys.allocation_units AS au ON au.container_id = p.partition_id
    WHERE  it.name LIKE N'persistent_version_store%';
    SELECT @TableMB = SUM(used_page_count) / 128.0 FROM sys.dm_db_partition_stats WHERE object_id = OBJECT_ID(N'Demo.Big');
    SELECT @Adr = is_accelerated_database_recovery_on FROM sys.databases WHERE database_id = DB_ID();
END
GO

-- Run the version cleaner now, rather than wait for its next pass.
CREATE OR ALTER PROCEDURE Demo.usp_CleanVersions
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sys.sp_persistent_version_cleanup N'AdrDemo';
END
GO

-- Shrink the log back to 64 MB between measurements, so each starts alike.
CREATE OR ALTER PROCEDURE Demo.usp_ResetLog
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @i int = 0;
    WHILE @i < 5 AND (SELECT total_log_size_in_bytes / 1048576 FROM sys.dm_db_log_space_usage) > 80
    BEGIN
        CHECKPOINT;
        DBCC SHRINKFILE (N'AdrDemo_log', 64) WITH NO_INFOMSGS;
        SET @i += 1;
    END
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_BigUpdate -- the big transaction. Update every row of Demo.Big
  twice in one transaction, record the time and CPU it took; CHECKPOINT and
  record how much log the still-open transaction is holding, and how big
  the version store is; then ROLL IT BACK and record how
  long that took.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_BigUpdate
    @Label varchar(60)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 datetime2(7), @tw datetime2(7), @t1 datetime2(7), @t2 datetime2(7), @c0 int, @c1 int,
            @u decimal(10,1), @s decimal(10,1), @p decimal(10,1), @adr bit, @tb1 decimal(10,1);
    SELECT @c0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    SET @t0 = SYSDATETIME();
    BEGIN TRANSACTION;
        UPDATE Demo.Big SET V = V + 1 OPTION (MAXDOP 1);
        UPDATE Demo.Big SET V = V + 1 OPTION (MAXDOP 1);
        SET @tw = SYSDATETIME();
        SELECT @c1 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;

        CHECKPOINT;
        EXEC Demo.usp_State @u OUTPUT, @s OUTPUT, @p OUTPUT, @adr OUTPUT, @tb1 OUTPUT;

        SET @t1 = SYSDATETIME();
    ROLLBACK;
    SET @t2 = SYSDATETIME();

    INSERT Demo.Results (Scenario, Label, Adr, WorkMs, WorkCpuMs, RollbackMs, LogUsedMB, LogSizeMB, VersionsMB, TableMB)
    VALUES ('A', @Label, @adr, DATEDIFF(millisecond, @t0, @tw), @c1 - @c0, DATEDIFF(millisecond, @t1, @t2), @u, @s,
            @p, @tb1);
END
GO


PRINT '=== STEP 4: the background session ===';
GO

/*------------------------------------------------------------------------------
  Demo.usp_Holder -- the activation procedure. Opens a transaction, writes
  one row, reports 'holding', and keeps the transaction open until
  Demo.HolderControl.Release (at most three minutes), then commits.
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
          AND DATEDIFF(second, @t0, SYSDATETIME()) < 180
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

-- Start the holder and wait until its transaction is open. Not inside a
-- transaction: SEND is transactional.
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

-- Release it, and wait until it has committed.
CREATE OR ALTER PROCEDURE Demo.usp_Holder_Release
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE Demo.HolderControl SET Release = 1 WHERE ID = 1;
    DECLARE @state varchar(20) = '', @i int = 0;
    WHILE @state NOT IN ('done', 'idle') AND @i < 1200
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
PRINT ' Everything lives in the AdrDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
