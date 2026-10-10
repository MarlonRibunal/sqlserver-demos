/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, UpsertDemo, and puts everything inside it.
     Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched

     Inside UpsertDemo it turns on Service Broker (ENABLE_BROKER).

  WHY SERVICE BROKER

     A race condition needs sessions running at the same moment. Four
     background workers, one Service Broker queue each (see the
     blocking-chains topic), wait for a shared "go" signal and then all
     upsert the same keys at once.

  Creates, all inside UpsertDemo:
     Demo.Counters        - KeyID primary key, Hits: the table being upserted
     Demo.CountersNoKey   - the same, with NO unique constraint
     Demo.Control         - the "go" signal
     Demo.WorkerResults   - one row per worker per run
     Demo.usp_Upsert      - one upsert of one key, by pattern
     Demo.usp_Worker_Run  - a worker: wait for "go", then upsert keys 1..N
     Demo.usp_Worker1..4, Q1..Q4, S1..S4
     Demo.usp_Race        - run one pattern on all four workers at once
     Demo.Outcomes, Demo.usp_Scenario - one measured race, and its result

  COST: under 100 MB, all inside UpsertDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers,
  Linux container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create UpsertDemo, with Service Broker ===';
GO

IF DB_ID('UpsertDemo') IS NOT NULL
BEGIN
    RAISERROR('UpsertDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE UpsertDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE UpsertDemo;
END
GO

CREATE DATABASE UpsertDemo;
GO

ALTER DATABASE UpsertDemo SET RECOVERY SIMPLE;
ALTER DATABASE UpsertDemo SET ENABLE_BROKER;
GO

USE UpsertDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: tables ===';
GO

CREATE TABLE Demo.Counters
(
    KeyID int NOT NULL CONSTRAINT PK_Counters PRIMARY KEY,
    Hits  int NOT NULL
);

-- The same table as plenty of real ones are built: no unique constraint on
-- the key, because "the application checks first".
CREATE TABLE Demo.CountersNoKey
(
    KeyID int NOT NULL,
    Hits  int NOT NULL
);
CREATE INDEX IX_CountersNoKey_KeyID ON Demo.CountersNoKey (KeyID);

CREATE TABLE Demo.Control
(
    ID     int         NOT NULL PRIMARY KEY,
    RunTag varchar(20) NULL,
    GoFlag bit         NOT NULL     -- not "Go": sqlcmd reads a line starting with Go as a batch separator
);
INSERT Demo.Control (ID, RunTag, GoFlag) VALUES (1, NULL, 0);

CREATE TABLE Demo.WorkerResults
(
    RunTag         varchar(20)   NOT NULL,
    Worker         varchar(10)   NOT NULL,
    Pattern        varchar(30)   NOT NULL,
    State          varchar(10)   NOT NULL,     -- ready | done
    Upserts        int           NULL,
    PkViolations   int           NULL,         -- Msg 2627 / 2601
    Deadlocks      int           NULL,         -- Msg 1205
    OtherErrors    int           NULL,
    LastError      nvarchar(200) NULL,
    ElapsedMs      int           NULL,
    At             datetime2(3)  NOT NULL CONSTRAINT DF_UDResults_At DEFAULT SYSDATETIME()
);
GO


PRINT '=== STEP 3: the upsert patterns ===';
GO

/*------------------------------------------------------------------------------
  Demo.usp_Upsert -- add 1 to the Hits of @KeyID, inserting the row if it
  does not exist yet, using one of seven patterns:

     CHECK_THEN_ACT        IF EXISTS (SELECT ...) UPDATE ELSE INSERT
                           -- into Demo.Counters (has a primary key)
     CHECK_THEN_ACT_NOKEY  the same, into Demo.CountersNoKey (no key)
     MERGE                 MERGE ... WHEN MATCHED UPDATE WHEN NOT MATCHED INSERT
     MERGE_HOLDLOCK        the same MERGE, WITH (HOLDLOCK) on the target
     UPDLOCK_SERIALIZABLE  in a transaction: UPDATE ... WITH (UPDLOCK,
                           SERIALIZABLE); IF @@ROWCOUNT = 0 INSERT
     READ_THEN_WRITE       SELECT @h = Hits; UPDATE SET Hits = @h + 1
                           (only on rows that already exist: the lost-update
                           pattern, a different race from the others)
     READ_UPDLOCK_THEN_WRITE  the same, in a transaction, with the SELECT
                           WITH (UPDLOCK)

  @GapMs adds a pause between the read and the write of the read-first
  patterns, and of the two locked patterns that have a read and a write. It stands in for the work real code does between
  deciding and acting -- a call out, a calculation, a second query -- and
  widens the race window so the demo shows the race reliably instead of a
  handful of times in thousands. It does not create the race: without it,
  the tested build still showed a few violations, duplicates and lost
  updates per 8,000 upserts. The locked patterns get the same pause, to show
  that the lock, not luck, is what makes them right. MERGE is a single
  statement with no gap to widen.

  WAITFOR DELAY takes a datetime, which counts in 1/300 s: 1 ms rounds to
  0 and waits not at all. Use 10.

  Errors are NOT caught here; the worker counts them.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Upsert
    @Pattern varchar(30),
    @KeyID   int,
    @GapMs   int = 0        -- a pause between the read and the write; see below
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @gap datetime = DATEADD(millisecond, @GapMs, CAST(0 AS datetime));

    IF @Pattern = 'CHECK_THEN_ACT'
    BEGIN
        IF EXISTS (SELECT 1 FROM Demo.Counters WHERE KeyID = @KeyID)
            UPDATE Demo.Counters SET Hits = Hits + 1 WHERE KeyID = @KeyID;
        ELSE
        BEGIN
            IF @GapMs > 0 WAITFOR DELAY @gap;
            INSERT Demo.Counters (KeyID, Hits) VALUES (@KeyID, 1);
        END
    END
    ELSE IF @Pattern = 'CHECK_THEN_ACT_NOKEY'
    BEGIN
        IF EXISTS (SELECT 1 FROM Demo.CountersNoKey WHERE KeyID = @KeyID)
            UPDATE Demo.CountersNoKey SET Hits = Hits + 1 WHERE KeyID = @KeyID;
        ELSE
        BEGIN
            IF @GapMs > 0 WAITFOR DELAY @gap;
            INSERT Demo.CountersNoKey (KeyID, Hits) VALUES (@KeyID, 1);
        END
    END
    ELSE IF @Pattern = 'MERGE'
    BEGIN
        MERGE Demo.Counters AS t
        USING (SELECT KeyID = @KeyID) AS s ON t.KeyID = s.KeyID
        WHEN MATCHED THEN UPDATE SET Hits = t.Hits + 1
        WHEN NOT MATCHED THEN INSERT (KeyID, Hits) VALUES (s.KeyID, 1);
    END
    ELSE IF @Pattern = 'MERGE_HOLDLOCK'
    BEGIN
        MERGE Demo.Counters WITH (HOLDLOCK) AS t
        USING (SELECT KeyID = @KeyID) AS s ON t.KeyID = s.KeyID
        WHEN MATCHED THEN UPDATE SET Hits = t.Hits + 1
        WHEN NOT MATCHED THEN INSERT (KeyID, Hits) VALUES (s.KeyID, 1);
    END
    ELSE IF @Pattern = 'UPDLOCK_SERIALIZABLE'
    BEGIN
        BEGIN TRANSACTION;
            UPDATE Demo.Counters WITH (UPDLOCK, SERIALIZABLE) SET Hits = Hits + 1 WHERE KeyID = @KeyID;
            IF @@ROWCOUNT = 0
            BEGIN
                IF @GapMs > 0 WAITFOR DELAY @gap;
                INSERT Demo.Counters (KeyID, Hits) VALUES (@KeyID, 1);
            END
        COMMIT;
    END
    ELSE IF @Pattern = 'READ_THEN_WRITE'
    BEGIN
        DECLARE @h int = (SELECT Hits FROM Demo.Counters WHERE KeyID = @KeyID);
        IF @GapMs > 0 WAITFOR DELAY @gap;
        UPDATE Demo.Counters SET Hits = @h + 1 WHERE KeyID = @KeyID;
    END
    ELSE IF @Pattern = 'READ_UPDLOCK_THEN_WRITE'
    BEGIN
        BEGIN TRANSACTION;
            DECLARE @h2 int = (SELECT Hits FROM Demo.Counters WITH (UPDLOCK) WHERE KeyID = @KeyID);
            IF @GapMs > 0 WAITFOR DELAY @gap;
            UPDATE Demo.Counters SET Hits = @h2 + 1 WHERE KeyID = @KeyID;
        COMMIT;
    END
END
GO


PRINT '=== STEP 4: the workers ===';
GO

/*------------------------------------------------------------------------------
  Demo.usp_Worker_Run -- one background worker. The message is
  "<runtag>|<pattern>|<keys>|<gap ms>". It reports 'ready', waits for the go signal
  (Demo.Control.GoFlag, read WITH (NOLOCK), polling every millisecond so that all four start
  together), then upserts keys 1..<keys> in order, counting errors by type,
  and reports 'done'.
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

    DECLARE @p1 int = CHARINDEX(N'|', @body), @p2 int;
    SET @p2 = CHARINDEX(N'|', @body, @p1 + 1);
    DECLARE @tag varchar(20)     = LEFT(@body, @p1 - 1);
    DECLARE @pattern varchar(30) = SUBSTRING(@body, @p1 + 1, @p2 - @p1 - 1);
    DECLARE @p3 int              = CHARINDEX(N'|', @body, @p2 + 1);
    DECLARE @keys int            = CAST(SUBSTRING(@body, @p2 + 1, @p3 - @p2 - 1) AS int);
    DECLARE @gapMs int           = CAST(SUBSTRING(@body, @p3 + 1, 10) AS int);
    DECLARE @w varchar(10)       = @Queue;

    INSERT Demo.WorkerResults (RunTag, Worker, Pattern, State) VALUES (@tag, @w, @pattern, 'ready');

    DECLARE @waited int = 0;
    WHILE ISNULL((SELECT GoFlag FROM Demo.Control WITH (NOLOCK) WHERE ID = 1 AND RunTag = @tag), 0) = 0 AND @waited < 20000
    BEGIN
        WAITFOR DELAY '00:00:00.001';
        SET @waited += 1;
    END

    DECLARE @t0 datetime2(7) = SYSDATETIME();
    DECLARE @k int = 1, @pk int = 0, @dl int = 0, @other int = 0, @last nvarchar(200), @err int;
    WHILE @k <= @keys
    BEGIN
        BEGIN TRY
            EXEC Demo.usp_Upsert @pattern, @k, @gapMs;
        END TRY
        BEGIN CATCH
            SET @err = ERROR_NUMBER();
            IF @@TRANCOUNT > 0 ROLLBACK;
            IF @err IN (2627, 2601) SET @pk += 1;
            ELSE IF @err = 1205 SET @dl += 1;
            ELSE BEGIN SET @other += 1; SET @last = LEFT(ERROR_MESSAGE(), 200); END
        END CATCH
        SET @k += 1;
    END

    UPDATE Demo.WorkerResults
    SET    State = 'done', Upserts = @keys, PkViolations = @pk, Deadlocks = @dl, OtherErrors = @other,
           LastError = @last, ElapsedMs = DATEDIFF(millisecond, @t0, SYSDATETIME()), At = SYSDATETIME()
    WHERE  RunTag = @tag AND Worker = @w;

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


PRINT '=== STEP 5: the race ===';
GO

/*------------------------------------------------------------------------------
  Demo.usp_Race -- run @Pattern on all four workers at once, over keys
  1..@Keys, and wait for them to finish (at most three minutes).

  Sequence: reset the "go" flag for this run, send each worker its command,
  wait until all four report 'ready', THEN set "go" -- so the four start
  within a millisecond of one another instead of a few hundred apart.

  Must not be called inside a transaction: SEND is transactional.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Race
    @RunTag  varchar(20),
    @Pattern varchar(30),
    @Keys    int,
    @GapMs   int = 0
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE Demo.Control SET RunTag = @RunTag, GoFlag = 0 WHERE ID = 1;

    DECLARE @w int = 1, @svc sysname, @h uniqueidentifier;
    DECLARE @msg nvarchar(100) = CAST(@RunTag AS nvarchar(20)) + N'|' + CAST(@Pattern AS nvarchar(30)) + N'|'
                               + CAST(@Keys AS nvarchar(10)) + N'|' + CAST(@GapMs AS nvarchar(10));
    WHILE @w <= 4
    BEGIN
        SET @svc = N'S' + CAST(@w AS nvarchar(2));
        BEGIN DIALOG CONVERSATION @h FROM SERVICE @svc TO SERVICE @svc ON CONTRACT [DEFAULT] WITH ENCRYPTION = OFF;
        SEND ON CONVERSATION @h (@msg);
        SET @w += 1;
    END

    DECLARE @t0 datetime2(3) = SYSDATETIME();
    WHILE (SELECT COUNT(*) FROM Demo.WorkerResults WITH (NOLOCK) WHERE RunTag = @RunTag) < 4
      AND DATEDIFF(millisecond, @t0, SYSDATETIME()) < 15000
        WAITFOR DELAY '00:00:00.020';

    UPDATE Demo.Control SET GoFlag = 1 WHERE ID = 1;

    SET @t0 = SYSDATETIME();
    WHILE (SELECT COUNT(*) FROM Demo.WorkerResults WITH (NOLOCK) WHERE RunTag = @RunTag AND State = 'done') < 4
      AND DATEDIFF(millisecond, @t0, SYSDATETIME()) < 180000
        WAITFOR DELAY '00:00:00.050';
END
GO


/*------------------------------------------------------------------------------
  Demo.usp_Scenario -- one measured race: empty both tables (or, for the
  read-then-write patterns, fill Demo.Counters with @Keys rows at Hits = 0),
  run @Pattern on four workers over keys 1..@Keys, and record what the table
  holds afterwards against what four correct workers would have left:
  @Keys rows, one per key, and Hits adding up to 4 x @Keys.
------------------------------------------------------------------------------*/
CREATE TABLE Demo.Outcomes
(
    Scenario      varchar(60)  NOT NULL,
    Pattern       varchar(30)  NOT NULL,
    RunTag        varchar(20)  NOT NULL,
    Keys          int          NOT NULL,
    GapMs         int          NOT NULL,
    Upserts       int          NULL,      -- attempted, all four workers
    RowsLeft      int          NULL,
    DistinctKeys  int          NULL,
    TotalHits     int          NULL,
    ExpectedHits  int          NULL,
    PkViolations  int          NULL,
    Deadlocks     int          NULL,
    OtherErrors   int          NULL,
    LastError     nvarchar(200) NULL,
    WorkersDone   int          NULL,
    ElapsedMs     int          NULL
);
GO

CREATE OR ALTER PROCEDURE Demo.usp_Scenario
    @Scenario varchar(60),
    @Pattern  varchar(30),
    @Keys     int,
    @GapMs    int = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tag varchar(20) = LEFT(@Pattern, 6) + '_' + FORMAT(SYSDATETIME(), 'HHmmssfff');

    TRUNCATE TABLE Demo.Counters;
    TRUNCATE TABLE Demo.CountersNoKey;
    IF @Pattern LIKE 'READ%'
        INSERT Demo.Counters (KeyID, Hits)
        SELECT TOP (@Keys) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 0
        FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b;

    EXEC Demo.usp_Race @tag, @Pattern, @Keys, @GapMs;

    DECLARE @rows int, @distinct int, @hits int;
    IF @Pattern LIKE '%NOKEY'
        SELECT @rows = COUNT(*), @distinct = COUNT(DISTINCT KeyID), @hits = SUM(Hits) FROM Demo.CountersNoKey;
    ELSE
        SELECT @rows = COUNT(*), @distinct = COUNT(DISTINCT KeyID), @hits = SUM(Hits) FROM Demo.Counters;

    INSERT Demo.Outcomes (Scenario, Pattern, RunTag, Keys, GapMs, Upserts, RowsLeft, DistinctKeys, TotalHits, ExpectedHits,
                          PkViolations, Deadlocks, OtherErrors, LastError, WorkersDone, ElapsedMs)
    SELECT @Scenario, @Pattern, @tag, @Keys, @GapMs, SUM(Upserts), @rows, @distinct, ISNULL(@hits, 0), 4 * @Keys,
           SUM(PkViolations), SUM(Deadlocks), SUM(OtherErrors), MAX(LastError),
           SUM(CASE WHEN State = 'done' THEN 1 ELSE 0 END), MAX(ElapsedMs)
    FROM   Demo.WorkerResults
    WHERE  RunTag = @tag;
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the UpsertDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
