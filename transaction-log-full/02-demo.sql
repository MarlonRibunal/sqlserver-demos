/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  Four ways a transaction log fills up or misbehaves, each measured through
  sys.dm_db_log_space_usage, sys.databases.log_reuse_wait_desc and
  sys.dm_db_log_info. Evidence lands in Demo.LogStates and Demo.Verdicts;
  the summary at the bottom is the payoff.

  Scenarios
    A  FULL recovery, no log backups   -> LOG_BACKUP: nothing but a log
                                          backup frees it
    B  one open transaction            -> ACTIVE_TRANSACTION: nothing frees
                                          it until that transaction ends --
                                          and the DMVs name the session
    C  shrinking a log that is held    -> DBCC SHRINKFILE gives nothing back
    D  autogrowth in tiny steps        -> hundreds of VLFs instead of a few

  This file switches LogFullDemo's recovery model, resizes its log, and
  backs it up to the NUL device -- its own database only (see 01-setup.sql).
  Scenario D also creates and drops a scratch database, LogFullDemo_VLF.

  Expected runtime: about a minute; scenarios B and D hold a transaction
  open on purpose.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE LogFullDemo;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('Demo.usp_Snapshot') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- Release any background holder an interrupted earlier run left behind, and
-- wait for it to commit: a forgotten open transaction is exactly what this
-- topic is about, and it would distort every scenario below.
UPDATE Demo.HolderControl SET Release = 1 WHERE ID = 1;
DECLARE @i int = 0;
WHILE (SELECT State FROM Demo.HolderStatus WITH (NOLOCK) WHERE ID = 1) = 'holding' AND @i < 300
BEGIN
    WAITFOR DELAY '00:00:00.100';
    SET @i += 1;
END
GO

-- Start from setup's state: SIMPLE recovery, a 64 MB log growing 64 MB.
ALTER DATABASE CURRENT SET RECOVERY SIMPLE;
GO
DELETE Demo.Ledger;
DELETE Demo.Churn;
EXEC Demo.usp_ShrinkLog 64;
ALTER DATABASE CURRENT MODIFY FILE (NAME = N'LogFullDemo_log', FILEGROWTH = 64MB);
TRUNCATE TABLE Demo.LogStates;
DROP TABLE IF EXISTS Demo.Verdicts;
CREATE TABLE Demo.Verdicts
(
    Scenario  varchar(60)   NOT NULL,
    Item      varchar(90)   NOT NULL,
    Detail    nvarchar(300) NULL,
    Expected  nvarchar(140) NULL,
    Verdict   varchar(24)   NULL
);
GO


/*==============================================================================
  SCENARIO A -- FULL recovery, and no log backups

  The most common full log of all. In FULL recovery, log records are kept
  until a LOG BACKUP has copied them -- that is what makes point-in-time
  restore possible. A database put in FULL recovery and then only ever given
  full backups keeps every log record forever, and the log grows until the
  disk is full.

  (FULL recovery only behaves like this once a full backup has started the
  log chain; before that it truncates like SIMPLE. The demo takes that first
  backup to the NUL device -- see the minimal-logging topic.)

     A1  after ~200 MB of activity     reuse wait: LOG_BACKUP
     A2  after a CHECKPOINT            still LOG_BACKUP, nothing freed
     A3  after BACKUP LOG              NOTHING, and the space is reusable
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO A: FULL recovery, no log backups ---';
GO

ALTER DATABASE CURRENT SET RECOVERY FULL;
GO
EXEC Demo.usp_NullBackup 'DATABASE';
EXEC Demo.usp_NullBackup 'LOG';
GO

EXEC Demo.usp_GenerateLog @MB = 200;
EXEC Demo.usp_Snapshot 'A. No log backups', 'A1: after ~200 MB of activity';
CHECKPOINT;
EXEC Demo.usp_Snapshot 'A. No log backups', 'A2: after CHECKPOINT';
EXEC Demo.usp_NullBackup 'LOG';
EXEC Demo.usp_Snapshot 'A. No log backups', 'A3: after BACKUP LOG';
GO

DECLARE @w1 nvarchar(60), @u1 decimal(10,1), @w2 nvarchar(60), @u2 decimal(10,1), @w3 nvarchar(60), @u3 decimal(10,1);
SELECT @w1 = ReuseWait, @u1 = LogUsedMB FROM Demo.LogStates WHERE Label LIKE 'A1%';
SELECT @w2 = ReuseWait, @u2 = LogUsedMB FROM Demo.LogStates WHERE Label LIKE 'A2%';
SELECT @w3 = ReuseWait, @u3 = LogUsedMB FROM Demo.LogStates WHERE Label LIKE 'A3%';
DECLARE @d nvarchar(300) = N'used ' + CAST(@u1 AS nvarchar(20)) + N' MB (' + @w1 + N') -> after CHECKPOINT '
    + CAST(@u2 AS nvarchar(20)) + N' MB (' + @w2 + N') -> after BACKUP LOG ' + CAST(@u3 AS nvarchar(20)) + N' MB (' + @w3 + N')';
INSERT Demo.Verdicts VALUES ('A. No log backups', 'FULL recovery: activity, CHECKPOINT, BACKUP LOG', @d,
    'LOG_BACKUP until a log backup; CHECKPOINT frees nothing',
    CASE WHEN @w1 = N'LOG_BACKUP' AND @w2 = N'LOG_BACKUP' AND @u2 >= @u1 * 0.9 AND @u3 < @u2 * 0.25
         THEN 'NEEDS A LOG BACKUP' ELSE 'unexpected' END);
GO

ALTER DATABASE CURRENT SET RECOVERY SIMPLE;
GO
CHECKPOINT;
GO


/*==============================================================================
  SCENARIO B -- one open transaction

  SIMPLE recovery truncates the log at every checkpoint -- but only up to the
  start of the oldest transaction still open. A session that began a
  transaction and never finished it (an application that forgot to commit,
  a debugging session left open) pins the log at that point. Everything
  written after it, by anyone, stays.

  Here a background session (Service Broker -- see 01-setup.sql) opens a
  transaction and writes ONE small row, then sits. This session writes
  ~200 MB of perfectly ordinary, committed work.

  Then the two questions to ask about any full log:
     why?   sys.databases.log_reuse_wait_desc
     who?   the oldest transaction in sys.dm_tran_database_transactions,
            and its session in sys.dm_tran_session_transactions
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO B: one open transaction ---';
GO

DECLARE @spid int;
EXEC Demo.usp_Holder_Start @HolderSpid = @spid OUTPUT;

EXEC Demo.usp_GenerateLog @MB = 200;
CHECKPOINT;
EXEC Demo.usp_Snapshot 'B. Open transaction', 'B1: ~200 MB later, after CHECKPOINT';

-- Who is holding the log? The oldest transaction that has written to this
-- database, and the session that owns it. A user session's transaction is in
-- sys.dm_tran_session_transactions; a background task's (like this demo's
-- Service Broker holder) is not, but its running request carries the
-- transaction id -- so look in both.
DECLARE @oldestSpid int, @oldestBegin datetime2(3);
SELECT TOP (1) @oldestSpid = COALESCE(st.session_id, r.session_id), @oldestBegin = dt.database_transaction_begin_time
FROM   sys.dm_tran_database_transactions AS dt
LEFT JOIN sys.dm_tran_session_transactions AS st ON st.transaction_id = dt.transaction_id
LEFT JOIN sys.dm_exec_requests             AS r  ON r.transaction_id  = dt.transaction_id
WHERE  dt.database_id = DB_ID() AND dt.database_transaction_begin_time IS NOT NULL
ORDER BY dt.database_transaction_begin_time;

DECLARE @w nvarchar(60), @u decimal(10,1);
SELECT @w = ReuseWait, @u = LogUsedMB FROM Demo.LogStates WHERE Label LIKE 'B1%';
DECLARE @d nvarchar(300) = N'used ' + CAST(@u AS nvarchar(20)) + N' MB after CHECKPOINT; reuse wait ' + @w
    + N'; oldest transaction belongs to session ' + ISNULL(CAST(@oldestSpid AS nvarchar(10)), N'?')
    + N' (the holder is session ' + ISNULL(CAST(@spid AS nvarchar(10)), N'?') + N')';
INSERT Demo.Verdicts VALUES ('B. Open transaction', 'one open transaction, ~200 MB of committed work', @d,
    'ACTIVE_TRANSACTION; the oldest transaction is the holder''s',
    -- At least half of the ~200 MB written is still held. 2022 held 226 MB,
    -- 2019 127 MB; either way it is many times what a free log holds (B2).
    CASE WHEN @w = N'ACTIVE_TRANSACTION' AND @u >= 100 AND @oldestSpid = @spid THEN 'PINNED BY ONE SESSION' ELSE 'unexpected' END);


/*==============================================================================
  SCENARIO C -- shrinking a log that is held

  The reflex with a full log is DBCC SHRINKFILE. While the reason it is full
  is still there, the active part of the log cannot be released, and a
  shrink gives nothing back. Fix the reason first.
==============================================================================*/
DECLARE @s0 decimal(10,1) = (SELECT size / 128.0 FROM sys.database_files WHERE name = N'LogFullDemo_log');
DBCC SHRINKFILE (N'LogFullDemo_log', 1) WITH NO_INFOMSGS;
DECLARE @s1 decimal(10,1) = (SELECT size / 128.0 FROM sys.database_files WHERE name = N'LogFullDemo_log');
DECLARE @d2 nvarchar(300) = N'log file ' + CAST(@s0 AS nvarchar(20)) + N' MB before DBCC SHRINKFILE, '
    + CAST(@s1 AS nvarchar(20)) + N' MB after';
INSERT Demo.Verdicts VALUES ('C. Shrinking a held log', 'DBCC SHRINKFILE while the transaction is still open', @d2,
    'little or nothing given back',
    CASE WHEN @s1 >= @s0 * 0.75 THEN 'NOTHING GIVEN BACK' ELSE 'unexpected' END);
GO

-- Release the holder, and show the log releasing.
EXEC Demo.usp_Holder_Release;
CHECKPOINT;
EXEC Demo.usp_Snapshot 'B. Open transaction', 'B2: after the holder commits, CHECKPOINT';
GO

DECLARE @w nvarchar(60), @u decimal(10,1), @u1 decimal(10,1);
SELECT @w = ReuseWait, @u = LogUsedMB FROM Demo.LogStates WHERE Label LIKE 'B2%';
SELECT @u1 = LogUsedMB FROM Demo.LogStates WHERE Label LIKE 'B1%';
DECLARE @d nvarchar(300) = N'used ' + CAST(@u1 AS nvarchar(20)) + N' MB -> ' + CAST(@u AS nvarchar(20)) + N' MB; reuse wait ' + @w;
INSERT Demo.Verdicts VALUES ('B. Open transaction', 'after the open transaction commits', @d,
    'the next checkpoint frees it all',
    CASE WHEN @u < @u1 * 0.25 THEN 'RELEASED' ELSE 'unexpected' END);
GO


/*==============================================================================
  SCENARIO D -- autogrowth in tiny steps

  A log file is divided into virtual log files (VLFs), and every growth adds
  more. A log that grew to its size in hundreds of 1 MB steps has hundreds
  of VLFs; one that grew in a few large steps has a few. Thousands of VLFs
  slow down database startup and restore (every VLF is examined during
  recovery) and some log operations.

  This scenario uses a scratch database of its own, LogFullDemo_VLF, created
  here and dropped at the end of it, so that each half starts from the same
  small, freshly created log -- shrinking LogFullDemo's log back down after
  scenarios A to C is not reliable enough to compare from. In each half ONE
  transaction inserts 90,000 rows of 2 KB (about 180 MB), so the log cannot
  truncate and has to grow to hold all of it -- on the tested build, about
  520 MB, once logging overhead and the space reserved for a rollback are
  counted:

     D1  FILEGROWTH = 1MB
     D2  FILEGROWTH = 256MB
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO D: VLFs (scratch database LogFullDemo_VLF) ---';
GO

CREATE OR ALTER PROCEDURE Demo.usp_VlfTrial
    @Label    varchar(90),
    @GrowthMB int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql nvarchar(max);

    IF DB_ID('LogFullDemo_VLF') IS NOT NULL
        EXEC (N'ALTER DATABASE LogFullDemo_VLF SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE LogFullDemo_VLF;');
    EXEC (N'CREATE DATABASE LogFullDemo_VLF;');
    EXEC (N'ALTER DATABASE LogFullDemo_VLF SET RECOVERY SIMPLE;');
    SET @sql = N'ALTER DATABASE LogFullDemo_VLF MODIFY FILE (NAME = N''LogFullDemo_VLF_log'', FILEGROWTH = '
             + CAST(@GrowthMB AS nvarchar(10)) + N'MB);';
    EXEC (@sql);

    DECLARE @vlf0 int, @size0 decimal(10,1), @vlf1 int, @size1 decimal(10,1);
    SELECT @vlf0 = COUNT(*) FROM sys.dm_db_log_info(DB_ID('LogFullDemo_VLF'));
    SELECT @size0 = size / 128.0 FROM sys.master_files WHERE database_id = DB_ID('LogFullDemo_VLF') AND type_desc = 'LOG';

    -- One transaction of ~180 MB of rows: the log has to grow to hold all of it.
    SET @sql = N'USE LogFullDemo_VLF;
        CREATE TABLE dbo.Fill (ID int IDENTITY PRIMARY KEY, Payload char(2000) NOT NULL);
        BEGIN TRANSACTION;
            INSERT dbo.Fill (Payload) SELECT TOP (90000) ''x'' FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b;
        COMMIT;';
    EXEC (@sql);

    SELECT @vlf1 = COUNT(*) FROM sys.dm_db_log_info(DB_ID('LogFullDemo_VLF'));
    SELECT @size1 = size / 128.0 FROM sys.master_files WHERE database_id = DB_ID('LogFullDemo_VLF') AND type_desc = 'LOG';

    INSERT Demo.LogStates (Scenario, Label, RecoveryModel, LogSizeMB, VLFs)
    VALUES ('D. VLFs', @Label + ' (before)', 'SIMPLE', @size0, @vlf0),
           ('D. VLFs', @Label, 'SIMPLE', @size1, @vlf1);

    EXEC (N'ALTER DATABASE LogFullDemo_VLF SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE LogFullDemo_VLF;');
END
GO

EXEC Demo.usp_VlfTrial 'D1: one big transaction, FILEGROWTH 1MB',   1;
EXEC Demo.usp_VlfTrial 'D2: one big transaction, FILEGROWTH 256MB', 256;
GO

DECLARE @v1 int, @s1 decimal(10,1), @v2 int, @s2 decimal(10,1);
SELECT @v1 = VLFs, @s1 = LogSizeMB FROM Demo.LogStates WHERE Label LIKE 'D1:%' AND Label NOT LIKE '%(before)';
SELECT @v2 = VLFs, @s2 = LogSizeMB FROM Demo.LogStates WHERE Label LIKE 'D2:%' AND Label NOT LIKE '%(before)';
DECLARE @d nvarchar(300) = N'1 MB growth: ' + CAST(@v1 AS nvarchar(10)) + N' VLFs in a ' + CAST(@s1 AS nvarchar(20))
    + N' MB log; 256 MB growth: ' + CAST(@v2 AS nvarchar(10)) + N' VLFs in ' + CAST(@s2 AS nvarchar(20)) + N' MB';
INSERT Demo.Verdicts VALUES ('D. VLFs', 'the same transaction, 1 MB vs 256 MB growth', @d,
    'hundreds of VLFs vs a handful',
    CASE WHEN @v1 >= 100 AND @v2 * 10 <= @v1 THEN 'TINY GROWTH, MANY VLFs' ELSE 'unexpected' END);
GO
DROP PROCEDURE Demo.usp_VlfTrial;
GO

-- Back to setup's state.
EXEC Demo.usp_ShrinkLog 64;
ALTER DATABASE CURRENT MODIFY FILE (NAME = N'LogFullDemo_log', FILEGROWTH = 64MB);
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. THE LOG AT EACH STEP ===';
GO
SELECT Scenario, Label, RecoveryModel, LogSizeMB, LogUsedMB, LogUsedPct, ReuseWait, VLFs, ActiveVLFs
FROM   Demo.LogStates ORDER BY StateID;
GO

PRINT '';
PRINT '=== 2. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario;
GO

PRINT '';
PRINT '=== 3. THE QUERY TO RUN WHEN A LOG IS FULL ===';
GO
-- Why each database's log cannot be reused, and the oldest open transaction
-- in each. Run it as is on your own instance.
SELECT  d.name, d.recovery_model_desc, d.log_reuse_wait_desc,
        OldestTranBegin = MIN(dt.database_transaction_begin_time),
        OldestTranSession = (SELECT TOP (1) COALESCE(st.session_id, r.session_id)
                             FROM sys.dm_tran_database_transactions AS x
                             LEFT JOIN sys.dm_tran_session_transactions AS st ON st.transaction_id = x.transaction_id
                             LEFT JOIN sys.dm_exec_requests AS r ON r.transaction_id = x.transaction_id
                             WHERE x.database_id = d.database_id AND x.database_transaction_begin_time IS NOT NULL
                             ORDER BY x.database_transaction_begin_time)
FROM    sys.databases AS d
LEFT JOIN sys.dm_tran_database_transactions AS dt
       ON dt.database_id = d.database_id AND dt.database_transaction_begin_time IS NOT NULL
WHERE   d.name = DB_NAME()          -- remove this line to see every database
GROUP BY d.database_id, d.name, d.recovery_model_desc, d.log_reuse_wait_desc;
GO

PRINT '';
PRINT '=== 4. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Detail, Verdict FROM Demo.Verdicts WHERE Verdict = 'unexpected';
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 4 should be EMPTY. Anything in it is a';
PRINT ' genuine difference on your build, worth reading before';
PRINT ' you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
