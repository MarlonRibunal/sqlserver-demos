/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  A background session (Demo.usp_Writer, started through Service Broker --
  see 01-setup.sql) updates account 1 and holds, commits or rolls back on
  command. This script reads account 1 under each isolation level and
  records how long it waited and what it saw. Evidence lands in
  Demo.Results; the summary is the payoff.

  Scenarios
    A  locking READ COMMITTED   -> the reader waits for the writer
    B  NOLOCK                   -> no wait, and a value that never existed
    C  RCSI                     -> no wait, the last committed value; but
                                   writers still block writers
    D  RCSI vs SNAPSHOT         -> statement-level vs transaction-level
                                   consistency
    E  the update conflict      -> SNAPSHOT refuses to overwrite a change it
                                   cannot see
    F  the cost                 -> the version store, and 14 bytes per row

  This file turns IsolationDemo's READ_COMMITTED_SNAPSHOT and
  ALLOW_SNAPSHOT_ISOLATION on, and both off again at the end.

  Expected runtime: about twenty seconds, most of it the writer holding its
  lock on purpose.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE IsolationDemo;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('Demo.usp_Writer_Start') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- Start from locking READ COMMITTED, whatever a previous run left.
ALTER DATABASE CURRENT SET READ_COMMITTED_SNAPSHOT OFF WITH ROLLBACK IMMEDIATE;
ALTER DATABASE CURRENT SET ALLOW_SNAPSHOT_ISOLATION OFF;
GO
TRUNCATE TABLE Demo.Results;
EXEC Demo.usp_ResetAccounts;
GO


/*==============================================================================
  SCENARIO A -- locking READ COMMITTED (the default)

  The writer adds 100 to account 1 and holds its exclusive lock for two
  seconds before committing. The reader asks for account 1's balance under
  the default isolation level, with READ_COMMITTED_SNAPSHOT off: it needs a
  shared lock, cannot have one, and waits -- then reads the new value.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO A: locking READ COMMITTED ---';
GO

DECLARE @spid int, @t0 datetime2(7), @b int;
EXEC Demo.usp_Writer_Start N'HOLD_COMMIT:2000', 'holding', @spid OUTPUT;
SET @t0 = SYSDATETIME();
SELECT @b = Balance FROM Demo.Accounts WHERE AccountID = 1;
DECLARE @ms int = DATEDIFF(millisecond, @t0, SYSDATETIME());
EXEC Demo.usp_Writer_WaitDone;

DECLARE @d nvarchar(300) = N'writer session ' + CAST(@spid AS nvarchar(10)) + N', this session ' + CAST(@@SPID AS nvarchar(10));
INSERT Demo.Results (Scenario, Item, WaitedMs, ValueRead, Detail, Expected, Verdict)
VALUES ('A. Locking READ COMMITTED', 'reader while the writer holds 2 s, then commits', @ms, @b, @d,
        'waits about 2 s; reads 1100 (the committed new value)',
        CASE WHEN @ms >= 1500 AND @b = 1100 THEN 'BLOCKED' ELSE 'unexpected' END);
EXEC Demo.usp_ResetAccounts;
GO


/*==============================================================================
  SCENARIO B -- NOLOCK

  The same, but the writer ROLLS BACK, and the reader uses WITH (NOLOCK).
  It does not wait. It reads 1100 -- a balance that is then rolled back and
  never existed. That is a dirty read, and it is what NOLOCK means.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO B: NOLOCK ---';
GO

DECLARE @spid int, @t0 datetime2(7), @b int;
EXEC Demo.usp_Writer_Start N'HOLD_ROLLBACK:2000', 'holding', @spid OUTPUT;
SET @t0 = SYSDATETIME();
SELECT @b = Balance FROM Demo.Accounts WITH (NOLOCK) WHERE AccountID = 1;
DECLARE @ms int = DATEDIFF(millisecond, @t0, SYSDATETIME());
EXEC Demo.usp_Writer_WaitDone;
DECLARE @after int = (SELECT Balance FROM Demo.Accounts WHERE AccountID = 1);

DECLARE @d nvarchar(300) = N'balance after the rollback: ' + CAST(@after AS nvarchar(10));
INSERT Demo.Results (Scenario, Item, WaitedMs, ValueRead, Detail, Expected, Verdict)
VALUES ('B. NOLOCK', 'reader WITH (NOLOCK) while the writer holds, then rolls back', @ms, @b, @d,
        'no wait; reads 1100, which is then rolled back to 1000',
        CASE WHEN @ms < 500 AND @b = 1100 AND @after = 1000 THEN 'DIRTY READ' ELSE 'unexpected' END);
EXEC Demo.usp_ResetAccounts;
GO


/*==============================================================================
  SCENARIO C -- READ_COMMITTED_SNAPSHOT

  Turn on RCSI for this database: READ COMMITTED now reads row VERSIONS --
  the last committed value, kept in tempdb's version store -- instead of
  taking shared locks.

     C1  the same reader, the same writer: no wait, and it reads 1000, the
         last COMMITTED balance. Not the uncommitted 1100 NOLOCK showed.
     C2  a second WRITER, though, still waits. RCSI removes readers from
         the blocking picture, not writers.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO C: RCSI ---';
GO

ALTER DATABASE CURRENT SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
GO

DECLARE @spid int, @t0 datetime2(7), @b int;
EXEC Demo.usp_Writer_Start N'HOLD_COMMIT:2000', 'holding', @spid OUTPUT;
SET @t0 = SYSDATETIME();
SELECT @b = Balance FROM Demo.Accounts WHERE AccountID = 1;
DECLARE @ms int = DATEDIFF(millisecond, @t0, SYSDATETIME());
EXEC Demo.usp_Writer_WaitDone;

INSERT Demo.Results (Scenario, Item, WaitedMs, ValueRead, Detail, Expected, Verdict)
VALUES ('C. RCSI', 'C1: reader while the writer holds', @ms, @b, NULL,
        'no wait; reads 1000 (the last committed value)',
        CASE WHEN @ms < 500 AND @b = 1000 THEN 'NOT BLOCKED' ELSE 'unexpected' END);
EXEC Demo.usp_ResetAccounts;
GO

DECLARE @spid int, @t0 datetime2(7);
EXEC Demo.usp_Writer_Start N'HOLD_COMMIT:2000', 'holding', @spid OUTPUT;
SET @t0 = SYSDATETIME();
UPDATE Demo.Accounts SET Balance = Balance - 50 WHERE AccountID = 1;
DECLARE @ms int = DATEDIFF(millisecond, @t0, SYSDATETIME());
EXEC Demo.usp_Writer_WaitDone;
DECLARE @b int = (SELECT Balance FROM Demo.Accounts WHERE AccountID = 1);

INSERT Demo.Results (Scenario, Item, WaitedMs, ValueRead, Detail, Expected, Verdict)
VALUES ('C. RCSI', 'C2: a second writer, same row', @ms, @b, N'final balance: +100 from the writer, -50 from this one',
        'waits about 2 s; both updates apply (1050)',
        CASE WHEN @ms >= 1500 AND @b = 1050 THEN 'WRITERS STILL BLOCK' ELSE 'unexpected' END);
EXEC Demo.usp_ResetAccounts;
GO


/*==============================================================================
  SCENARIO D -- RCSI vs SNAPSHOT

  RCSI gives each STATEMENT a consistent view as of when that statement
  started. SNAPSHOT isolation gives the whole TRANSACTION a view as of its
  first read.

  The same experiment under each: begin a transaction, read the balance, let
  the writer add 100 and commit, read again.

     RCSI       the second read sees 1100: non-repeatable, by design
     SNAPSHOT   the second read still sees 1000: the transaction's view
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO D: RCSI vs SNAPSHOT ---';
GO

ALTER DATABASE CURRENT SET ALLOW_SNAPSHOT_ISOLATION ON;
GO

-- RCSI: plain READ COMMITTED, now versioned.
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
DECLARE @r1 int, @r2 int, @spid int, @since datetime2(3);
EXEC Demo.usp_Writer_Start N'DELAY_COMMIT:1000', 'none', @spid OUTPUT, @since OUTPUT;
BEGIN TRANSACTION;
    SELECT @r1 = Balance FROM Demo.Accounts WHERE AccountID = 1;
    EXEC Demo.usp_Writer_WaitDone @since;          -- the writer commits now
    SELECT @r2 = Balance FROM Demo.Accounts WHERE AccountID = 1;
COMMIT;

DECLARE @d nvarchar(300) = N'first read ' + CAST(@r1 AS nvarchar(10)) + N', second read ' + CAST(@r2 AS nvarchar(10));
INSERT Demo.Results (Scenario, Item, ValueRead, Detail, Expected, Verdict)
VALUES ('D. RCSI vs SNAPSHOT', 'RCSI: read, writer commits, read again', @r2, @d,
        'second read sees the new value (1100)',
        CASE WHEN @r1 = 1000 AND @r2 = 1100 THEN 'STATEMENT-LEVEL' ELSE 'unexpected' END);
EXEC Demo.usp_ResetAccounts;
GO

SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
DECLARE @r1 int, @r2 int, @spid int, @since datetime2(3);
EXEC Demo.usp_Writer_Start N'DELAY_COMMIT:1000', 'none', @spid OUTPUT, @since OUTPUT;
BEGIN TRANSACTION;
    SELECT @r1 = Balance FROM Demo.Accounts WHERE AccountID = 1;
    EXEC Demo.usp_Writer_WaitDone @since;          -- the writer commits now
    SELECT @r2 = Balance FROM Demo.Accounts WHERE AccountID = 1;
COMMIT;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

DECLARE @now int = (SELECT Balance FROM Demo.Accounts WHERE AccountID = 1);
DECLARE @d nvarchar(300) = N'first read ' + CAST(@r1 AS nvarchar(10)) + N', second read ' + CAST(@r2 AS nvarchar(10))
    + N'; committed balance afterwards ' + CAST(@now AS nvarchar(10));
INSERT Demo.Results (Scenario, Item, ValueRead, Detail, Expected, Verdict)
VALUES ('D. RCSI vs SNAPSHOT', 'SNAPSHOT: read, writer commits, read again', @r2, @d,
        'second read still sees 1000',
        CASE WHEN @r1 = 1000 AND @r2 = 1000 AND @now = 1100 THEN 'TRANSACTION-LEVEL' ELSE 'unexpected' END);
EXEC Demo.usp_ResetAccounts;
GO


/*==============================================================================
  SCENARIO E -- the update conflict

  A SNAPSHOT transaction reads account 1, the writer changes it and commits,
  and then the snapshot transaction tries to update it. It cannot: it would
  overwrite a change it never saw. SQL Server refuses with Msg 3960 and rolls
  the transaction back. Code that uses SNAPSHOT for writes has to expect
  this and retry.

  (RCSI has no such check: an UPDATE under RCSI waits for the lock and then
  applies to the latest committed row, as scenario C2 showed.)
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO E: the update conflict ---';
GO

SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
DECLARE @r1 int, @spid int, @err nvarchar(300), @since datetime2(3);
EXEC Demo.usp_Writer_Start N'DELAY_COMMIT:1000', 'none', @spid OUTPUT, @since OUTPUT;
BEGIN TRY
    BEGIN TRANSACTION;
        SELECT @r1 = Balance FROM Demo.Accounts WHERE AccountID = 1;
        EXEC Demo.usp_Writer_WaitDone @since;      -- the writer commits now
        UPDATE Demo.Accounts SET Balance = @r1 - 50 WHERE AccountID = 1;
    COMMIT;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SET @err = N'Msg ' + CAST(ERROR_NUMBER() AS nvarchar(10)) + N': ' + LEFT(ERROR_MESSAGE(), 240);
END CATCH
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

DECLARE @now int = (SELECT Balance FROM Demo.Accounts WHERE AccountID = 1);
INSERT Demo.Results (Scenario, Item, ValueRead, Detail, Expected, Verdict)
VALUES ('E. Update conflict', 'SNAPSHOT: read, writer commits, update the same row',
        @now, ISNULL(@err, N'the update succeeded'),
        'Msg 3960; the writer''s change survives (1100)',
        CASE WHEN @err LIKE N'Msg 3960%' AND @now = 1100 THEN 'CONFLICT DETECTED' ELSE 'unexpected' END);
EXEC Demo.usp_ResetAccounts;
GO


/*==============================================================================
  SCENARIO F -- the cost

  Row versioning is not free:

     - every row modified while RCSI or SNAPSHOT is on gets a 14-byte
       versioning tag. On full pages, growing every row splits them.
       (A row INSERTED while versioning is on carries the tag from birth --
       which is why the tables below are loaded with versioning off.)
     - every UPDATE and DELETE copies the old row into the version store in
       TEMPDB -- shared by every database on the instance -- until no
       transaction can need it

  The same 200,000-row update, run against two identical fresh tables:
  F1 with versioning off, F2 with it on. Row size and page fullness come
  from sys.dm_db_index_physical_stats in DETAILED mode.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO F: the cost ---';
GO

-- Versioning OFF before the tables are loaded: a row inserted while RCSI or
-- SNAPSHOT is on is born with the 14-byte tag already.
ALTER DATABASE CURRENT SET READ_COMMITTED_SNAPSHOT OFF WITH ROLLBACK IMMEDIATE;
ALTER DATABASE CURRENT SET ALLOW_SNAPSHOT_ISOLATION OFF;
GO
DROP TABLE IF EXISTS Demo.LedgerOff, Demo.LedgerOn;
CREATE TABLE Demo.LedgerOff (ID int NOT NULL PRIMARY KEY, Amount int NOT NULL, Memo char(20) NOT NULL);
CREATE TABLE Demo.LedgerOn  (ID int NOT NULL PRIMARY KEY, Amount int NOT NULL, Memo char(20) NOT NULL);
;WITH n AS (SELECT TOP (200000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
            FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b)
INSERT Demo.LedgerOff WITH (TABLOCK) (ID, Amount, Memo) SELECT rn, 1, 'x' FROM n;
INSERT Demo.LedgerOn  WITH (TABLOCK) (ID, Amount, Memo) SELECT ID, Amount, Memo FROM Demo.LedgerOff;
GO

-- F1: versioning OFF (already, from above).
DECLARE @r0 decimal(8,1), @f0 decimal(6,1), @r1 decimal(8,1), @f1 decimal(6,1);
SELECT @r0 = avg_record_size_in_bytes, @f0 = avg_page_space_used_in_percent
FROM   sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('Demo.LedgerOff'), 1, NULL, 'DETAILED') WHERE index_level = 0;
UPDATE Demo.LedgerOff SET Amount = Amount + 1;
SELECT @r1 = avg_record_size_in_bytes, @f1 = avg_page_space_used_in_percent
FROM   sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('Demo.LedgerOff'), 1, NULL, 'DETAILED') WHERE index_level = 0;
DECLARE @vs bigint = (SELECT ISNULL(SUM(reserved_space_kb), 0) FROM sys.dm_tran_version_store_space_usage WHERE database_id = DB_ID());
DECLARE @d nvarchar(300) = N'row ' + CAST(@r0 AS nvarchar(10)) + N' -> ' + CAST(@r1 AS nvarchar(10)) + N' bytes; pages '
    + CAST(@f0 AS nvarchar(10)) + N'% -> ' + CAST(@f1 AS nvarchar(10)) + N'% full; version store for this database '
    + CAST(@vs AS nvarchar(20)) + N' KB';
INSERT Demo.Results (Scenario, Item, Detail, Expected, Verdict)
VALUES ('F. The cost', 'F1: update 200,000 rows, versioning OFF', @d, 'rows unchanged; nothing in the version store',
        CASE WHEN @r1 = @r0 AND @vs = 0 THEN 'NO COST' ELSE 'unexpected' END);
GO

-- F2: versioning ON.
ALTER DATABASE CURRENT SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
GO
DECLARE @r0 decimal(8,1), @f0 decimal(6,1), @r1 decimal(8,1), @f1 decimal(6,1);
SELECT @r0 = avg_record_size_in_bytes, @f0 = avg_page_space_used_in_percent
FROM   sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('Demo.LedgerOn'), 1, NULL, 'DETAILED') WHERE index_level = 0;
UPDATE Demo.LedgerOn SET Amount = Amount + 1;
SELECT @r1 = avg_record_size_in_bytes, @f1 = avg_page_space_used_in_percent
FROM   sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('Demo.LedgerOn'), 1, NULL, 'DETAILED') WHERE index_level = 0;
DECLARE @vs bigint = (SELECT ISNULL(SUM(reserved_space_kb), 0) FROM sys.dm_tran_version_store_space_usage WHERE database_id = DB_ID());
DECLARE @d nvarchar(300) = N'row ' + CAST(@r0 AS nvarchar(10)) + N' -> ' + CAST(@r1 AS nvarchar(10)) + N' bytes; pages '
    + CAST(@f0 AS nvarchar(10)) + N'% -> ' + CAST(@f1 AS nvarchar(10)) + N'% full; version store for this database '
    + CAST(@vs AS nvarchar(20)) + N' KB';
INSERT Demo.Results (Scenario, Item, Detail, Expected, Verdict)
VALUES ('F. The cost', 'F2: the same update, RCSI ON', @d, 'each row 14 bytes bigger, full pages split; old versions in tempdb',
        CASE WHEN @r1 - @r0 = 14 AND @vs > 0 THEN 'VERSIONS COST' ELSE 'unexpected' END);
GO


-- Back to setup's state.
ALTER DATABASE CURRENT SET READ_COMMITTED_SNAPSHOT OFF WITH ROLLBACK IMMEDIATE;
ALTER DATABASE CURRENT SET ALLOW_SNAPSHOT_ISOLATION OFF;
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. WHAT EACH READER WAITED FOR, AND SAW ===';
GO
SELECT Scenario, Item, WaitedMs, ValueRead, Detail, Expected, Verdict FROM Demo.Results ORDER BY ResultID;
GO

PRINT '';
PRINT '=== 2. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, WaitedMs, ValueRead, Detail, Verdict FROM Demo.Results WHERE Verdict = 'unexpected';
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 2 should be EMPTY. Anything in it is either';
PRINT ' a genuine difference on your build, or another session';
PRINT ' working in IsolationDemo -- read it before the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
