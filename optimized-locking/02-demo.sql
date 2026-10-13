/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Optimized locking (SQL Server 2025) has two parts:

     TID locking                 an updated row is protected by the
                                 transaction's ID, not by a row lock held to
                                 the end; row and page locks are let go as
                                 the statement moves on
     lock after qualification    under READ_COMMITTED_SNAPSHOT, an UPDATE or
     (LAQ)                       DELETE checks its WHERE clause against the
                                 last committed version first, and only
                                 locks the rows that qualify

  Every scenario runs in three configurations of LockDemo:

     1  OPTIMIZED_LOCKING OFF, READ_COMMITTED_SNAPSHOT ON
     2  OPTIMIZED_LOCKING ON,  READ_COMMITTED_SNAPSHOT ON
     3  OPTIMIZED_LOCKING ON,  READ_COMMITTED_SNAPSHOT OFF

     A  the locks an open UPDATE holds, for 1,000 and 20,000 rows
     B  lock escalation: another session updates an unrelated row
     C  another session's UPDATE reads past a row this one holds, without
        changing it
     D  another session updates the same row: that still waits, on a
        different kind of lock

  On SQL Server 2022 and earlier every scenario reports SKIPPED.

  WHAT THIS CHANGES: only LockDemo. It switches LockDemo's
  OPTIMIZED_LOCKING and READ_COMMITTED_SNAPSHOT between the configurations
  (WITH ROLLBACK IMMEDIATE: anyone else connected to LockDemo is
  disconnected), and leaves both ON.

  TESTED end to end on SQL Server 2025 RTM-CU8 (17.0.4075.5), Linux
  container.
==============================================================================*/

USE LockDemo;
GO
SET NOCOUNT ON;
GO

TRUNCATE TABLE Demo.Results;
TRUNCATE TABLE Demo.Verdicts;
TRUNCATE TABLE Demo.WorkerStatus;
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) < 17
    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'optimized locking: locks held',          'needs SQL Server 2025 or later', 'SKIPPED'),
    ('B', 'optimized locking: lock escalation',     'needs SQL Server 2025 or later', 'SKIPPED'),
    ('C', 'lock after qualification',               'needs SQL Server 2025 or later', 'SKIPPED'),
    ('D', 'optimized locking: the same row',        'needs SQL Server 2025 or later', 'SKIPPED');
GO


/*==============================================================================
  Configuration 1: OPTIMIZED_LOCKING OFF, READ_COMMITTED_SNAPSHOT ON.
==============================================================================*/
PRINT '=== configuration 1: optimized locking OFF ===';
GO
USE master;
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    EXEC (N'ALTER DATABASE LockDemo SET OPTIMIZED_LOCKING = OFF WITH ROLLBACK IMMEDIATE;');
    EXEC (N'ALTER DATABASE LockDemo SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;');
END
GO
USE LockDemo;
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    EXEC Demo.usp_Locks 1000,  '1 (OFF, RCSI)';
    EXEC Demo.usp_Locks 20000, '1 (OFF, RCSI)';
    EXEC Demo.usp_Contend 'B', '1 (OFF, RCSI): order 90000, while 20,000 others are updated', 'w_OtherRow', 20000;
    EXEC Demo.usp_Contend 'C', '1 (OFF, RCSI): the s2 orders among the first 1,000, while order 1 is updated', 'w_ScanUpdate', 1;
    EXEC Demo.usp_Contend 'D', '1 (OFF, RCSI): order 1, while order 1 is updated', 'w_SameRow', 1;
END
GO


/*==============================================================================
  Configuration 2: OPTIMIZED_LOCKING ON, READ_COMMITTED_SNAPSHOT ON.
==============================================================================*/
PRINT '=== configuration 2: optimized locking ON, RCSI ON ===';
GO
USE master;
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    EXEC (N'ALTER DATABASE LockDemo SET OPTIMIZED_LOCKING = ON WITH ROLLBACK IMMEDIATE;');
    EXEC (N'ALTER DATABASE LockDemo SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;');
END
GO
USE LockDemo;
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    EXEC Demo.usp_Locks 1000,  '2 (ON, RCSI)';
    EXEC Demo.usp_Locks 20000, '2 (ON, RCSI)';
    EXEC Demo.usp_Contend 'B', '2 (ON, RCSI): order 90000, while 20,000 others are updated', 'w_OtherRow', 20000;
    EXEC Demo.usp_Contend 'C', '2 (ON, RCSI): the s2 orders among the first 1,000, while order 1 is updated', 'w_ScanUpdate', 1;
    EXEC Demo.usp_Contend 'D', '2 (ON, RCSI): order 1, while order 1 is updated', 'w_SameRow', 1;
END
GO


/*==============================================================================
  Configuration 3: OPTIMIZED_LOCKING ON, READ_COMMITTED_SNAPSHOT OFF. TID
  locking without lock after qualification.
==============================================================================*/
PRINT '=== configuration 3: optimized locking ON, RCSI OFF ===';
GO
USE master;
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    EXEC (N'ALTER DATABASE LockDemo SET OPTIMIZED_LOCKING = ON WITH ROLLBACK IMMEDIATE;');
    EXEC (N'ALTER DATABASE LockDemo SET READ_COMMITTED_SNAPSHOT OFF WITH ROLLBACK IMMEDIATE;');
END
GO
USE LockDemo;
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    EXEC Demo.usp_Locks 20000, '3 (ON, no RCSI)';
    EXEC Demo.usp_Contend 'B', '3 (ON, no RCSI): order 90000, while 20,000 others are updated', 'w_OtherRow', 20000;
    EXEC Demo.usp_Contend 'C', '3 (ON, no RCSI): the s2 orders among the first 1,000, while order 1 is updated', 'w_ScanUpdate', 1;
END
GO

-- Leave LockDemo with both on.
USE master;
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    EXEC (N'ALTER DATABASE LockDemo SET OPTIMIZED_LOCKING = ON WITH ROLLBACK IMMEDIATE;');
    EXEC (N'ALTER DATABASE LockDemo SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;');
END
GO
USE LockDemo;
GO


/*==============================================================================
  Verdicts (2025 and later).
==============================================================================*/
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @a1s varchar(400), @a1b varchar(400), @a2s varchar(400), @a2b varchar(400), @a3b varchar(400),
            @b1 varchar(400), @b2 varchar(400), @b3 varchar(400),
            @c1 varchar(400), @c2 varchar(400), @c3 varchar(400),
            @d1 varchar(400), @d2 varchar(400);
    SELECT @a1s = Value FROM Demo.Results WHERE Label = '1 (OFF, RCSI): locks held by an open UPDATE of 1000 rows';
    SELECT @a1b = Value FROM Demo.Results WHERE Label = '1 (OFF, RCSI): locks held by an open UPDATE of 20000 rows';
    SELECT @a2s = Value FROM Demo.Results WHERE Label = '2 (ON, RCSI): locks held by an open UPDATE of 1000 rows';
    SELECT @a2b = Value FROM Demo.Results WHERE Label = '2 (ON, RCSI): locks held by an open UPDATE of 20000 rows';
    SELECT @a3b = Value FROM Demo.Results WHERE Label = '3 (ON, no RCSI): locks held by an open UPDATE of 20000 rows';
    SELECT @b1 = Value FROM Demo.Results WHERE Scenario = 'B' AND Label LIKE '1 %';
    SELECT @b2 = Value FROM Demo.Results WHERE Scenario = 'B' AND Label LIKE '2 %';
    SELECT @b3 = Value FROM Demo.Results WHERE Scenario = 'B' AND Label LIKE '3 %';
    SELECT @c1 = Value FROM Demo.Results WHERE Scenario = 'C' AND Label LIKE '1 %';
    SELECT @c2 = Value FROM Demo.Results WHERE Scenario = 'C' AND Label LIKE '2 %';
    SELECT @c3 = Value FROM Demo.Results WHERE Scenario = 'C' AND Label LIKE '3 %';
    SELECT @d1 = Value FROM Demo.Results WHERE Scenario = 'D' AND Label LIKE '1 %';
    SELECT @d2 = Value FROM Demo.Results WHERE Scenario = 'D' AND Label LIKE '2 %';

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'OFF: an open UPDATE of 1,000 rows holds a lock on every row',
     @a1s, CASE WHEN @a1s LIKE '%KEY X: 1000%' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('A', 'OFF: at 20,000 rows the locks escalate to one table lock',
     @a1b, CASE WHEN @a1b LIKE '%OBJECT X%' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('A', 'ON: no row locks are held, only one lock on the transaction''s ID',
     @a2s, CASE WHEN @a2s NOT LIKE '%KEY%' AND @a2s LIKE '%XACT X: 1%' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('A', 'ON: at 20,000 rows, still no escalation',
     @a2b, CASE WHEN @a2b NOT LIKE '%OBJECT X%' AND @a2b NOT LIKE '%KEY%' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('A', 'ON without RCSI: the same (TID locking doesn''t need RCSI)',
     @a3b, CASE WHEN @a3b NOT LIKE '%OBJECT X%' AND @a3b NOT LIKE '%KEY%' THEN 'CONFIRMED' ELSE 'unexpected' END),

    ('B', 'OFF: after escalation, an update of an unrelated row is blocked',
     @b1, CASE WHEN @b1 LIKE 'BLOCKED%' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('B', 'ON: it goes straight through',
     @b2, CASE WHEN @b2 LIKE 'done%never waited%' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('B', 'ON without RCSI: also straight through',
     @b3, CASE WHEN @b3 LIKE 'done%never waited%' THEN 'CONFIRMED' ELSE 'unexpected' END),

    ('C', 'OFF: an UPDATE that only reads past a locked row is blocked by it',
     @c1, CASE WHEN @c1 LIKE 'BLOCKED%' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('C', 'ON with RCSI (lock after qualification): it isn''t',
     @c2, CASE WHEN @c2 LIKE 'done%10 row(s)%never waited%' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('C', 'ON without RCSI: blocked again; lock after qualification needs RCSI',
     @c3, CASE WHEN @c3 LIKE 'BLOCKED%' THEN 'CONFIRMED' ELSE 'unexpected' END),

    ('D', 'OFF: the same row waits on the row''s key lock',
     @d1, CASE WHEN @d1 LIKE 'BLOCKED%LCK_M_U%keylock%' OR @d1 LIKE 'BLOCKED%LCK_M_X%keylock%' THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('D', 'ON: the same row still waits, now on the other transaction''s ID',
     @d2, CASE WHEN @d2 LIKE 'BLOCKED%XACT%' THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. EVERY MEASUREMENT ===';
GO
SELECT Scenario, Label, Value FROM Demo.Results ORDER BY Scenario, Seq;
GO

PRINT '';
PRINT '=== 2. VERDICTS ===';
GO
SELECT Scenario, Claim, Evidence, Verdict FROM Demo.Verdicts ORDER BY Scenario, Seq;
GO

PRINT '';
PRINT '=== 3. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Claim, Evidence, Verdict FROM Demo.Verdicts
WHERE  Verdict IN ('unexpected', 'INCONCLUSIVE', 'SKIPPED') ORDER BY Scenario, Seq;
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 3 should be EMPTY on SQL Server 2025 and';
PRINT ' later. On 2022 and earlier it lists every scenario as';
PRINT ' SKIPPED. Anything else in it is a genuine difference';
PRINT ' on your build, worth reading before you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
