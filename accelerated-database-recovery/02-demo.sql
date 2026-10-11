/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  The same big transaction with Accelerated Database Recovery off, then on:
  what ADR gives (an instant rollback, a log that doesn't fill behind a long
  transaction) and what it costs (slower writes, a version store inside the
  database) -- and the one thing that makes that version store grow without
  limit. Evidence lands in Demo.Results and Demo.Verdicts; the summary at
  the bottom is the payoff.

  Scenarios
    A  update 1,000,000 rows twice, then ROLLBACK  -> seconds without ADR,
                                                       milliseconds with
    B  the log while that transaction is open      -> ADR lets it truncate
    C  what the update itself cost                 -> more time and CPU with
                                                       ADR, and a version store
    D  a failed batch while another session has a  -> its versions can't be
       transaction open                                cleaned up until that
                                                       transaction ends
    E  the table itself                            -> twice the size after ADR
                                                       versioned its rows; a
                                                       rebuild restores it

  This file switches ADR off and on for AdrDemo (only), rebuilds Demo.Big,
  shrinks AdrDemo's
  log between measurements, and runs sys.sp_persistent_version_cleanup on
  AdrDemo (through Demo.usp_CleanVersions).

  Expected runtime: about a minute.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE AdrDemo;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('Demo.usp_BigUpdate') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- Release a background holder an interrupted earlier run left behind: an
-- open transaction is exactly what scenario D is about.
EXEC Demo.usp_Holder_Release;
DELETE Demo.Results;
GO

IF OBJECT_ID('Demo.Verdicts') IS NOT NULL DROP TABLE Demo.Verdicts;
CREATE TABLE Demo.Verdicts
(
    Scenario  char(1)       NOT NULL,
    Item      varchar(70)   NOT NULL,
    Detail    varchar(300)  NOT NULL,
    Expected  varchar(100)  NOT NULL,
    Verdict   varchar(30)   NOT NULL
);
GO


/*==============================================================================
  A, B, C without ADR. Start clean: no version store, ADR off, a 64 MB log.
==============================================================================*/
PRINT '=== A-C: ADR off ===';
EXEC Demo.usp_CleanVersions;
ALTER DATABASE CURRENT SET ACCELERATED_DATABASE_RECOVERY = OFF;
GO
-- Scenario E needs Demo.Big at its original size: a rebuild with ADR off.
ALTER INDEX PK_Big ON Demo.Big REBUILD WITH (MAXDOP = 1);
DECLARE @u decimal(10,1), @s decimal(10,1), @p decimal(10,1), @adr bit, @tb decimal(10,1);
EXEC Demo.usp_State @u OUTPUT, @s OUTPUT, @p OUTPUT, @adr OUTPUT, @tb OUTPUT;
INSERT Demo.Results (Scenario, Label, Adr, TableMB) VALUES ('E', 'Demo.Big at the start', @adr, @tb);
EXEC Demo.usp_ResetLog;
EXEC Demo.usp_BigUpdate 'ADR off';
EXEC Demo.usp_ResetLog;
GO

/*==============================================================================
  ... and with it. With ADR on, every row change also writes the row's old
  version into the persistent version store (PVS), inside the database. A
  rollback then needs no log replay: each row's current version is simply
  marked as aborted, and readers see the old one. The aborted versions stay
  in the PVS until the cleaner removes them.
==============================================================================*/
PRINT '=== A-C: ADR on ===';
ALTER DATABASE CURRENT SET ACCELERATED_DATABASE_RECOVERY = ON;
GO
EXEC Demo.usp_CleanVersions;
DECLARE @u decimal(10,1), @s decimal(10,1), @p decimal(10,1), @adr bit, @tb decimal(10,1);
EXEC Demo.usp_BigUpdate 'ADR on';
EXEC Demo.usp_State @u OUTPUT, @s OUTPUT, @p OUTPUT, @adr OUTPUT, @tb OUTPUT;
INSERT Demo.Results (Scenario, Label, Adr, VersionsMB, TableMB) VALUES ('C', 'after the rollback', @adr, @p, @tb);
EXEC Demo.usp_CleanVersions;
EXEC Demo.usp_State @u OUTPUT, @s OUTPUT, @p OUTPUT, @adr OUTPUT, @tb OUTPUT;
INSERT Demo.Results (Scenario, Label, Adr, VersionsMB, TableMB) VALUES ('C', 'after cleanup', @adr, @p, @tb);
EXEC Demo.usp_ResetLog;
GO


/*==============================================================================
  D -- the version store's long-transaction problem. A background session
  opens a transaction and leaves it open: a forgotten BEGIN TRAN, a report
  that runs for an hour. Meanwhile a batch job in this session updates
  every row and fails (rolls back). Its versions are needed by nobody --
  but the cleaner can't remove aborted versions while an older transaction
  is still open, so they stay, and every further failure adds to them.
==============================================================================*/
PRINT '=== D: a transaction left open elsewhere ===';
EXEC Demo.usp_CleanVersions;
DECLARE @spid int, @u decimal(10,1), @s decimal(10,1), @p decimal(10,1), @adr bit, @tb decimal(10,1);
EXEC Demo.usp_Holder_Start @HolderSpid = @spid OUTPUT;

-- The batch job: two passes over every row, then it fails. (A single
-- pass added only about 16 MB to the version store on the tested build --
-- ADR can keep a row's previous version inside the row -- while two added
-- 320 MB, as in A.)
BEGIN TRANSACTION;
    UPDATE Demo.Big SET V = V + 1 OPTION (MAXDOP 1);
    UPDATE Demo.Big SET V = V + 1 OPTION (MAXDOP 1);
ROLLBACK;
EXEC Demo.usp_State @u OUTPUT, @s OUTPUT, @p OUTPUT, @adr OUTPUT, @tb OUTPUT;
INSERT Demo.Results (Scenario, Label, Adr, VersionsMB, TableMB) VALUES ('D', 'failed batch, another transaction open', @adr, @p, @tb);

EXEC Demo.usp_CleanVersions;
EXEC Demo.usp_State @u OUTPUT, @s OUTPUT, @p OUTPUT, @adr OUTPUT, @tb OUTPUT;
INSERT Demo.Results (Scenario, Label, Adr, VersionsMB, TableMB) VALUES ('D', 'cleanup, other transaction still open', @adr, @p, @tb);

EXEC Demo.usp_Holder_Release;
EXEC Demo.usp_CleanVersions;
EXEC Demo.usp_State @u OUTPUT, @s OUTPUT, @p OUTPUT, @adr OUTPUT, @tb OUTPUT;
INSERT Demo.Results (Scenario, Label, Adr, VersionsMB, TableMB) VALUES ('D', 'cleanup, after it ended', @adr, @p, @tb);
GO


/*==============================================================================
  E -- what versioning did to the table itself. With ADR on, a changed row
  can carry its previous version inside the row; the extra bytes don't fit
  on full pages, so pages split -- and the rows keep that room after the
  versions are gone. A rebuild packs them again.
==============================================================================*/
PRINT '=== E: the table itself ===';
DECLARE @u decimal(10,1), @s decimal(10,1), @p decimal(10,1), @adr bit, @tb decimal(10,1);
EXEC Demo.usp_State @u OUTPUT, @s OUTPUT, @p OUTPUT, @adr OUTPUT, @tb OUTPUT;
INSERT Demo.Results (Scenario, Label, Adr, TableMB) VALUES ('E', 'Demo.Big after ADR versioned its rows', @adr, @tb);
ALTER INDEX PK_Big ON Demo.Big REBUILD WITH (MAXDOP = 1);
EXEC Demo.usp_State @u OUTPUT, @s OUTPUT, @p OUTPUT, @adr OUTPUT, @tb OUTPUT;
INSERT Demo.Results (Scenario, Label, Adr, TableMB) VALUES ('E', 'Demo.Big rebuilt', @adr, @tb);
GO


/*==============================================================================
  Verdicts
==============================================================================*/
DECLARE @d varchar(300);
DECLARE @offRb int, @onRb int, @offLog decimal(10,1), @onLog decimal(10,1), @offCpu int, @onCpu int,
        @offMs int, @onMs int, @onPvs decimal(10,1), @offSize decimal(10,1), @onSize decimal(10,1);
SELECT @offRb = RollbackMs, @offLog = LogUsedMB, @offCpu = WorkCpuMs, @offMs = WorkMs, @offSize = LogSizeMB
FROM   Demo.Results WHERE Scenario = 'A' AND Adr = 0;
SELECT @onRb = RollbackMs, @onLog = LogUsedMB, @onCpu = WorkCpuMs, @onMs = WorkMs, @onPvs = VersionsMB, @onSize = LogSizeMB
FROM   Demo.Results WHERE Scenario = 'A' AND Adr = 1;

-- A
SET @d = CONCAT('rollback of 2,000,000 row updates: ADR off ', @offRb, ' ms; ADR on ', @onRb, ' ms');
INSERT Demo.Verdicts VALUES ('A', 'rollback is instant with ADR', @d, 'ADR on: under 1 s and under a fifth of off',
    CASE WHEN @onRb < 1000 AND @onRb * 5 < @offRb THEN 'INSTANT' ELSE 'unexpected' END);

-- B
SET @d = CONCAT('log in use with the transaction still open, after CHECKPOINT: ADR off ', @offLog, ' MB (file ', @offSize,
                ' MB); ADR on ', @onLog, ' MB (file ', @onSize, ' MB)');
INSERT Demo.Verdicts VALUES ('B', 'ADR lets the log truncate under an open transaction', @d, 'ADR on: under half of off',
    CASE WHEN @onLog * 2 < @offLog THEN 'TRUNCATED' ELSE 'unexpected' END);

-- C
DECLARE @pAfterRb decimal(10,1), @pClean decimal(10,1);
SELECT @pAfterRb = MAX(CASE WHEN Label = 'after the rollback' THEN VersionsMB END),
       @pClean = MAX(CASE WHEN Label = 'after cleanup' THEN VersionsMB END)
FROM   Demo.Results WHERE Scenario = 'C';
SET @d = CONCAT('the updates: ADR off ', @offMs, ' ms (', @offCpu, ' ms CPU); ADR on ', @onMs, ' ms (', @onCpu,
                ' ms CPU) and a ', @onPvs, ' MB version store');
INSERT Demo.Verdicts VALUES ('C', 'ADR makes the writes cost more', @d, 'ADR on: more CPU; a version store of 100 MB+',
    CASE WHEN @onCpu > @offCpu AND @onPvs >= 100 THEN 'COSTLIER WRITES' ELSE 'unexpected' END);
SET @d = CONCAT('version store: ', @pAfterRb, ' MB after the rollback, ', @pClean, ' MB after cleanup');
INSERT Demo.Verdicts VALUES ('C', 'the version store is cleaned up afterwards', @d, 'under 10% left',
    CASE WHEN @pClean < @pAfterRb * 0.1 THEN 'CLEANED' ELSE 'unexpected' END);

-- D
DECLARE @dBefore decimal(10,1), @dBlocked decimal(10,1), @dAfter decimal(10,1);
SELECT @dBefore = MAX(CASE WHEN Label = 'failed batch, another transaction open' THEN VersionsMB END),
       @dBlocked = MAX(CASE WHEN Label = 'cleanup, other transaction still open' THEN VersionsMB END),
       @dAfter = MAX(CASE WHEN Label = 'cleanup, after it ended' THEN VersionsMB END)
FROM   Demo.Results WHERE Scenario = 'D';
SET @d = CONCAT('version store: ', @dBefore, ' MB after the failed batch; ', @dBlocked,
                ' MB after cleanup while the other transaction was open; ', @dAfter, ' MB once it ended');
INSERT Demo.Verdicts VALUES ('D', 'one open transaction blocks the cleanup', @d, 'blocked: most remains; after: under 10%',
    CASE WHEN @dBefore >= 100 AND @dBlocked >= @dBefore * 0.9 AND @dAfter < @dBefore * 0.1 THEN 'BLOCKED' ELSE 'unexpected' END);

-- E
DECLARE @e0 decimal(10,1), @e1 decimal(10,1), @e2 decimal(10,1);
SELECT @e0 = MAX(CASE WHEN Label = 'Demo.Big at the start' THEN TableMB END),
       @e1 = MAX(CASE WHEN Label = 'Demo.Big after ADR versioned its rows' THEN TableMB END),
       @e2 = MAX(CASE WHEN Label = 'Demo.Big rebuilt' THEN TableMB END)
FROM   Demo.Results WHERE Scenario = 'E';
SET @d = CONCAT('Demo.Big: ', @e0, ' MB at the start; ', @e1, ' MB after ADR versioned its rows (rolled back, versions cleaned); ',
                @e2, ' MB rebuilt');
INSERT Demo.Verdicts VALUES ('E', 'in-row versions grew the table, and it stays grown', @d, 'at least 1.5x; a rebuild restores it',
    CASE WHEN @e1 >= @e0 * 1.5 AND @e2 <= @e0 * 1.1 THEN 'GREW' ELSE 'unexpected' END);
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. EVERY MEASUREMENT ===';
GO
SELECT Scenario, Label, Adr, WorkMs, WorkCpuMs, RollbackMs, LogUsedMB, LogSizeMB, VersionsMB, TableMB
FROM   Demo.Results
ORDER BY CapturedAt;
GO

PRINT '';
PRINT '=== 2. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario, Item;
GO

PRINT '';
PRINT '=== 3. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Detail, Verdict FROM Demo.Verdicts WHERE Verdict IN ('unexpected', 'INCONCLUSIVE');
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 3 should be EMPTY. Anything in it is a';
PRINT ' genuine difference on your build, worth reading before';
PRINT ' you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
