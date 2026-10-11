/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  Four restores people need and rarely practise, each run for real against
  BackupDemo, and each checked by counting what came back. Evidence lands in
  Demo.Results and Demo.Verdicts; the summary at the bottom is the payoff.

  Scenarios
    A  someone deletes every order; restore to       -> the deleted rows come
       the moment before, into a copy, and put           back; nothing done
       the rows back                                     since is lost
    B  the last log backup was a while ago           -> without a tail-log
                                                         backup that work is
                                                         gone; with it, nothing
    C  an ad hoc full backup without COPY_ONLY       -> the next differential
                                                         can't be restored on
                                                         the scheduled full
    D  compression and checksums                     -> a smaller backup, and
                                                         one you've verified

  WHAT THIS FILE TOUCHES -- read before running

     - It writes backup files into this instance's default backup folder
       (SERVERPROPERTY('InstanceDefaultBackupPath')), all named
       BackupDemo_*.bak, overwriting them on every run.
     - It restores them as a second database, BackupDemo_Copy.
     - Scenario B takes a tail-log backup of BackupDemo WITH NORECOVERY,
       which takes BackupDemo offline into RESTORING, and then brings it
       back online.
     - Every backup and restore adds history rows to msdb.
     - It deletes and reloads BackupDemo's own rows.

     03-cleanup.sql deletes the files (by name, one by one), both databases,
     and their msdb history.

  Expected runtime: about 30 seconds.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

IF DB_ID('BackupDemo') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- An interrupted earlier run can leave BackupDemo RESTORING (scenario B).
IF DATABASEPROPERTYEX('BackupDemo', 'Status') = 'RESTORING'
    RESTORE DATABASE BackupDemo WITH RECOVERY;
GO

USE BackupDemo;
GO
SET NOCOUNT ON;
EXEC Demo.usp_Reload;
DELETE Demo.Results;
IF OBJECT_ID('Demo.Verdicts') IS NOT NULL DROP TABLE Demo.Verdicts;
CREATE TABLE Demo.Verdicts
(
    Scenario  char(1)       NOT NULL,
    Item      varchar(70)   NOT NULL,
    Detail    varchar(400)  NOT NULL,
    Expected  varchar(100)  NOT NULL,
    Verdict   varchar(30)   NOT NULL
);
GO


/*==============================================================================
  A -- point in time. The morning's work, a log backup, more work -- then
  someone runs DELETE without a WHERE clause. Work carries on (500 more
  orders) until the next log backup. Restoring the database itself to the
  moment before the DELETE would throw those 500 away, so restore a COPY to
  that moment and put the deleted rows back from it.
==============================================================================*/
PRINT '=== A: point-in-time restore ===';
EXEC Demo.usp_Backup 'a_full', 'FULL';
INSERT Demo.Orders (CustomerID, Amount, Batch)
SELECT TOP (1000) 1, 10, 'morning' FROM sys.all_columns;
EXEC Demo.usp_Backup 'a_log1', 'LOG';
INSERT Demo.Orders (CustomerID, Amount, Batch)
SELECT TOP (1000) 2, 20, 'midday' FROM sys.all_columns;

-- The moment to go back to: after every good transaction so far, a second
-- before the accident. (In real life: the time someone remembers, or the
-- time the DELETE shows in the log.)
DECLARE @wait datetime = '00:00:01';
WAITFOR DELAY @wait;
DECLARE @before datetime = GETDATE();
WAITFOR DELAY @wait;
INSERT Demo.Results (Scenario, Label, Value) SELECT 'A', 'rows before the accident', COUNT(*) FROM Demo.Orders;

DELETE Demo.Orders;                                          -- the accident
INSERT Demo.Results (Scenario, Label, Value) SELECT 'A', 'rows after the accident', COUNT(*) FROM Demo.Orders;
WAITFOR DELAY @wait;

INSERT Demo.Orders (CustomerID, Amount, Batch)               -- work carries on
SELECT TOP (500) 3, 30, 'afternoon' FROM sys.all_columns;
EXEC Demo.usp_Backup 'a_log2', 'LOG';

DECLARE @err int, @msg nvarchar(400);
EXEC Demo.usp_RestoreCopy 'D:a_full|L:a_log1|L:a_log2', @before, @err OUTPUT, @msg OUTPUT;
INSERT Demo.Results (Scenario, Label, Value, Note) VALUES ('A', 'restore error', @err, @msg);
INSERT Demo.Results (Scenario, Label, Value) SELECT 'A', 'rows in the copy', COUNT(*) FROM BackupDemo_Copy.Demo.Orders;
INSERT Demo.Results (Scenario, Label, Value)
SELECT 'A', 'afternoon rows in the copy', COUNT(*) FROM BackupDemo_Copy.Demo.Orders WHERE Batch = 'afternoon';

-- Put back what the DELETE removed, keeping the original IDs.
SET IDENTITY_INSERT Demo.Orders ON;
INSERT Demo.Orders (OrderID, CustomerID, Amount, Batch, pad)
SELECT c.OrderID, c.CustomerID, c.Amount, c.Batch, c.pad
FROM   BackupDemo_Copy.Demo.Orders AS c
WHERE  NOT EXISTS (SELECT 1 FROM Demo.Orders AS o WHERE o.OrderID = c.OrderID);
SET IDENTITY_INSERT Demo.Orders OFF;
INSERT Demo.Results (Scenario, Label, Value) SELECT 'A', 'rows after the repair', COUNT(*) FROM Demo.Orders;
GO


/*==============================================================================
  B -- the tail of the log. A full backup, work, a log backup -- then 300
  more orders before disaster strikes. Restoring the backups you have
  brings back everything up to the last log backup. The rest is still in
  the database's log, and a TAIL-LOG BACKUP (taken WITH NORECOVERY, which
  leaves the database RESTORING so nothing more can change) saves it.

  The tail-log backup needs BackupDemo to itself, so this runs from master.
  Here BackupDemo is brought straight back online afterwards and the chain
  is restored as the copy; in a real recovery you'd restore it over the
  damaged database.
==============================================================================*/
PRINT '=== B: the tail of the log ===';
EXEC Demo.usp_Backup 'b_full', 'FULL';
INSERT Demo.Orders (CustomerID, Amount, Batch) SELECT TOP (1000) 4, 40, 'before log backup' FROM sys.all_columns;
EXEC Demo.usp_Backup 'b_log1', 'LOG';
INSERT Demo.Orders (CustomerID, Amount, Batch) SELECT TOP (300) 5, 50, 'last minutes' FROM sys.all_columns;
INSERT Demo.Results (Scenario, Label, Value) SELECT 'B', 'rows in BackupDemo', COUNT(*) FROM Demo.Orders;

-- B1: the backups there are.
DECLARE @err int, @msg nvarchar(400);
EXEC Demo.usp_RestoreCopy 'D:b_full|L:b_log1', NULL, @err OUTPUT, @msg OUTPUT;
INSERT Demo.Results (Scenario, Label, Value, Note) VALUES ('B', 'restore error, without tail', @err, @msg);
INSERT Demo.Results (Scenario, Label, Value) SELECT 'B', 'rows restored without the tail', COUNT(*) FROM BackupDemo_Copy.Demo.Orders;
GO

USE master;
GO
DECLARE @dir nvarchar(300) = CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(300));
DECLARE @sep nchar(1) = CASE WHEN CHARINDEX(N'\', @dir) > 0 THEN N'\' ELSE N'/' END;
IF RIGHT(@dir, 1) IN (N'\', N'/') SET @dir = LEFT(@dir, LEN(@dir) - 1);
DECLARE @tail nvarchar(400) = @dir + @sep + N'BackupDemo_b_tail.bak';

BACKUP LOG BackupDemo TO DISK = @tail WITH INIT, FORMAT, CHECKSUM, NORECOVERY;
DECLARE @state nvarchar(60) = CAST(DATABASEPROPERTYEX('BackupDemo', 'Status') AS nvarchar(60));
RESTORE DATABASE BackupDemo WITH RECOVERY;      -- back online, for the rest of the demo
INSERT BackupDemo.Demo.Results (Scenario, Label, Note) VALUES ('B', 'BackupDemo after the tail-log backup', @state);
GO

USE BackupDemo;
GO
-- B2: the same backups plus the tail.
DECLARE @err int, @msg nvarchar(400);
EXEC Demo.usp_RestoreCopy 'D:b_full|L:b_log1|L:b_tail', NULL, @err OUTPUT, @msg OUTPUT;
INSERT Demo.Results (Scenario, Label, Value, Note) VALUES ('B', 'restore error, with tail', @err, @msg);
INSERT Demo.Results (Scenario, Label, Value) SELECT 'B', 'rows restored with the tail', COUNT(*) FROM BackupDemo_Copy.Demo.Orders;
GO


/*==============================================================================
  C -- the differential base. A differential backup holds every page changed
  since the most recent FULL backup -- any full backup, including one taken
  by someone else "just to have a copy". If that copy wasn't COPY_ONLY, the
  next differential is based on it, and restoring the scheduled full plus
  that differential fails. Then the same with COPY_ONLY.
==============================================================================*/
PRINT '=== C: COPY_ONLY ===';
DECLARE @err int, @msg nvarchar(400);

EXEC Demo.usp_Backup 'c_full', 'FULL';                         -- the scheduled full
INSERT Demo.Orders (CustomerID, Amount, Batch) SELECT TOP (100) 6, 60, 'c' FROM sys.all_columns;
EXEC Demo.usp_Backup 'c_adhoc', 'FULL';                        -- "just a copy", NOT copy-only
INSERT Demo.Orders (CustomerID, Amount, Batch) SELECT TOP (100) 6, 60, 'c' FROM sys.all_columns;
EXEC Demo.usp_Backup 'c_diff', 'DIFF';                         -- the scheduled differential
EXEC Demo.usp_RestoreCopy 'D:c_full|D:c_diff', NULL, @err OUTPUT, @msg OUTPUT;
INSERT Demo.Results (Scenario, Label, Value, Note) VALUES ('C', 'full + differential, ad hoc full in between', @err, @msg);

EXEC Demo.usp_Backup 'c2_full', 'FULL';
INSERT Demo.Orders (CustomerID, Amount, Batch) SELECT TOP (100) 7, 70, 'c2' FROM sys.all_columns;
EXEC Demo.usp_Backup 'c2_adhoc', 'FULL', @CopyOnly = 1;        -- the same copy, COPY_ONLY
INSERT Demo.Orders (CustomerID, Amount, Batch) SELECT TOP (100) 7, 70, 'c2' FROM sys.all_columns;
EXEC Demo.usp_Backup 'c2_diff', 'DIFF';
EXEC Demo.usp_RestoreCopy 'D:c2_full|D:c2_diff', NULL, @err OUTPUT, @msg OUTPUT;
INSERT Demo.Results (Scenario, Label, Value, Note) VALUES ('C', 'full + differential, COPY_ONLY in between', @err, @msg);
INSERT Demo.Results (Scenario, Label, Value) SELECT 'C', 'rows in BackupDemo', COUNT(*) FROM Demo.Orders;
INSERT Demo.Results (Scenario, Label, Value) SELECT 'C', 'rows in the copy', COUNT(*) FROM BackupDemo_Copy.Demo.Orders;

-- What msdb recorded: which full each differential is based on.
INSERT Demo.Results (Scenario, Label, Note)
SELECT 'C', CONCAT('msdb: ', RIGHT(mf.physical_device_name, CHARINDEX(N'/', REVERSE(REPLACE(mf.physical_device_name, N'\', N'/'))) - 1)),
       CONCAT('type ', bs.type, CASE WHEN bs.is_copy_only = 1 THEN ', copy-only' ELSE '' END,
              ', differential base = ', CASE WHEN bs.type = 'I' THEN
                  (SELECT TOP (1) RIGHT(f2.physical_device_name, CHARINDEX(N'/', REVERSE(REPLACE(f2.physical_device_name, N'\', N'/'))) - 1)
                   FROM msdb.dbo.backupset AS b2 JOIN msdb.dbo.backupmediafamily AS f2 ON f2.media_set_id = b2.media_set_id
                   WHERE b2.backup_set_uuid = bs.differential_base_guid) ELSE '-' END)
FROM   msdb.dbo.backupset AS bs
JOIN   msdb.dbo.backupmediafamily AS mf ON mf.media_set_id = bs.media_set_id
WHERE  bs.database_name = N'BackupDemo'
  AND  bs.backup_start_date >= (SELECT MIN(CapturedAt) FROM Demo.Results)
  AND  mf.physical_device_name LIKE N'%BackupDemo[_]c%';
GO


/*==============================================================================
  D -- compression and checksums. The same full backup, uncompressed and
  compressed; then RESTORE VERIFYONLY ... WITH CHECKSUM, which reads the
  whole backup and checks every page checksum without restoring it. (It
  proves the file is readable. Only a real restore, like A-C's, proves the
  database comes back.)
==============================================================================*/
PRINT '=== D: compression and checksums ===';
IF CAST(SERVERPROPERTY('EngineEdition') AS int) = 4
    INSERT Demo.Results (Scenario, Label, Note) VALUES ('D', 'skipped', 'Express edition: no backup compression');
ELSE
BEGIN
    DECLARE @t0 datetime2(3) = SYSDATETIME();
    EXEC Demo.usp_Backup 'd_plain', 'FULL', @CopyOnly = 1, @Compress = 0;
    INSERT Demo.Results (Scenario, Label, Value) VALUES ('D', 'plain: ms', DATEDIFF(millisecond, @t0, SYSDATETIME()));
    SET @t0 = SYSDATETIME();
    EXEC Demo.usp_Backup 'd_compressed', 'FULL', @CopyOnly = 1, @Compress = 1;
    INSERT Demo.Results (Scenario, Label, Value) VALUES ('D', 'compressed: ms', DATEDIFF(millisecond, @t0, SYSDATETIME()));

    INSERT Demo.Results (Scenario, Label, Value)
    SELECT 'D', CASE WHEN mf.physical_device_name LIKE N'%d[_]plain%' THEN 'plain: bytes' ELSE 'compressed: bytes' END,
           bs.compressed_backup_size
    FROM   msdb.dbo.backupset AS bs
    JOIN   msdb.dbo.backupmediafamily AS mf ON mf.media_set_id = bs.media_set_id
    WHERE  bs.database_name = N'BackupDemo'
      AND  bs.backup_set_id IN (SELECT MAX(b.backup_set_id) FROM msdb.dbo.backupset AS b
                                JOIN msdb.dbo.backupmediafamily AS m ON m.media_set_id = b.media_set_id
                                WHERE b.database_name = N'BackupDemo' AND (m.physical_device_name LIKE N'%d[_]plain%'
                                                                       OR  m.physical_device_name LIKE N'%d[_]compressed%')
                                GROUP BY m.physical_device_name);

    DECLARE @path nvarchar(400), @verr int = 0, @vmsg nvarchar(400);
    EXEC Demo.usp_File 'd_compressed', @path OUTPUT;
    BEGIN TRY
        RESTORE VERIFYONLY FROM DISK = @path WITH CHECKSUM;
    END TRY
    BEGIN CATCH
        SELECT @verr = ERROR_NUMBER(), @vmsg = ERROR_MESSAGE();
    END CATCH
    INSERT Demo.Results (Scenario, Label, Value, Note) VALUES ('D', 'RESTORE VERIFYONLY WITH CHECKSUM: error', @verr, @vmsg);
    INSERT Demo.Results (Scenario, Label, Value)
    SELECT 'D', 'has_backup_checksums', MAX(CAST(bs.has_backup_checksums AS int))
    FROM   msdb.dbo.backupset AS bs JOIN msdb.dbo.backupmediafamily AS mf ON mf.media_set_id = bs.media_set_id
    WHERE  mf.physical_device_name = @path;
END
GO


/*==============================================================================
  Verdicts
==============================================================================*/
DECLARE @d varchar(400);
DECLARE @r TABLE (Scenario char(1), Label varchar(80), Value bigint, Note varchar(300));
INSERT @r SELECT Scenario, Label, Value, Note FROM Demo.Results;

-- A
DECLARE @aBefore bigint = (SELECT Value FROM @r WHERE Label = 'rows before the accident'),
        @aAfter bigint = (SELECT Value FROM @r WHERE Label = 'rows after the accident'),
        @aErr bigint = (SELECT Value FROM @r WHERE Scenario = 'A' AND Label = 'restore error'),
        @aCopy bigint = (SELECT Value FROM @r WHERE Scenario = 'A' AND Label = 'rows in the copy'),
        @aAft bigint = (SELECT Value FROM @r WHERE Label = 'afternoon rows in the copy'),
        @aRep bigint = (SELECT Value FROM @r WHERE Label = 'rows after the repair');
SET @d = CONCAT(@aBefore, ' rows; DELETE left ', @aAfter, '; copy restored to the moment before: ', @aCopy,
                ' rows (', @aAft, ' of the 500 later ones); BackupDemo after putting them back: ', @aRep);
INSERT Demo.Verdicts VALUES ('A', 'STOPAT brings back exactly the deleted rows', @d, 'copy = before; repaired = before + 500',
    CASE WHEN @aErr = 0 AND @aAfter = 0 AND @aCopy = @aBefore AND @aAft = 0 AND @aRep = @aBefore + 500 THEN 'RECOVERED' ELSE 'unexpected' END);

-- B
DECLARE @bLive bigint = (SELECT Value FROM @r WHERE Label = 'rows in BackupDemo' AND Scenario = 'B'),
        @bNo bigint = (SELECT Value FROM @r WHERE Label = 'rows restored without the tail'),
        @bYes bigint = (SELECT Value FROM @r WHERE Label = 'rows restored with the tail'),
        @bState varchar(300) = (SELECT Note FROM @r WHERE Label = 'BackupDemo after the tail-log backup'),
        @bErr bigint = (SELECT SUM(Value) FROM @r WHERE Scenario = 'B' AND Label LIKE 'restore error%');
SET @d = CONCAT('BackupDemo had ', @bLive, ' rows; restored without the tail: ', @bNo, '; with it: ', @bYes);
INSERT Demo.Verdicts VALUES ('B', 'the tail-log backup saves the last minutes', @d, 'without: 300 short; with: all',
    CASE WHEN @bErr = 0 AND @bNo = @bLive - 300 AND @bYes = @bLive THEN 'SAVED' ELSE 'unexpected' END);
SET @d = CONCAT('BackupDemo after BACKUP LOG ... WITH NORECOVERY: ', @bState);
INSERT Demo.Verdicts VALUES ('B', 'NORECOVERY freezes the database', @d, 'RESTORING',
    CASE WHEN @bState = 'RESTORING' THEN 'FROZEN' ELSE 'unexpected' END);

-- C
DECLARE @cBad bigint = (SELECT Value FROM @r WHERE Label = 'full + differential, ad hoc full in between'),
        @cBadMsg varchar(300) = (SELECT Note FROM @r WHERE Label = 'full + differential, ad hoc full in between'),
        @cGood bigint = (SELECT Value FROM @r WHERE Label = 'full + differential, COPY_ONLY in between'),
        @cLive bigint = (SELECT Value FROM @r WHERE Scenario = 'C' AND Label = 'rows in BackupDemo'),
        @cCopy bigint = (SELECT Value FROM @r WHERE Scenario = 'C' AND Label = 'rows in the copy');
SET @d = CONCAT('error ', @cBad, ': ', LEFT(@cBadMsg, 200));
INSERT Demo.Verdicts VALUES ('C', 'ad hoc full in between: the differential won''t restore', @d, 'an error',
    CASE WHEN @cBad <> 0 THEN 'BROKEN CHAIN' ELSE 'unexpected' END);
SET @d = CONCAT('error ', @cGood, '; copy has ', @cCopy, ' rows, BackupDemo ', @cLive);
INSERT Demo.Verdicts VALUES ('C', 'COPY_ONLY in between: it restores', @d, 'no error; every row',
    CASE WHEN @cGood = 0 AND @cCopy = @cLive THEN 'RESTORED' ELSE 'unexpected' END);

-- D
IF EXISTS (SELECT 1 FROM @r WHERE Scenario = 'D' AND Label = 'skipped')
    INSERT Demo.Verdicts VALUES ('D', 'compression and checksums', 'Express edition', 'n/a', 'SKIPPED');
ELSE
BEGIN
    DECLARE @dPlain bigint = (SELECT Value FROM @r WHERE Label = 'plain: bytes'),
            @dComp bigint = (SELECT Value FROM @r WHERE Label = 'compressed: bytes'),
            @dPms bigint = (SELECT Value FROM @r WHERE Label = 'plain: ms'),
            @dCms bigint = (SELECT Value FROM @r WHERE Label = 'compressed: ms'),
            @dVer bigint = (SELECT Value FROM @r WHERE Label LIKE 'RESTORE VERIFYONLY%'),
            @dChk bigint = (SELECT Value FROM @r WHERE Label = 'has_backup_checksums');
    SET @d = CONCAT('full backup: ', @dPlain / 1048576, ' MB in ', @dPms, ' ms plain; ', @dComp / 1048576, ' MB in ', @dCms, ' ms compressed');
    INSERT Demo.Verdicts VALUES ('D', 'compression shrinks the backup', @d, 'compressed under half',
        CASE WHEN @dComp * 2 < @dPlain THEN 'SMALLER' ELSE 'unexpected' END);
    SET @d = CONCAT('has_backup_checksums ', @dChk, '; RESTORE VERIFYONLY WITH CHECKSUM error ', @dVer);
    INSERT Demo.Verdicts VALUES ('D', 'checksummed and verified', @d, 'checksums; verify clean',
        CASE WHEN @dChk = 1 AND @dVer = 0 THEN 'VERIFIED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. EVERY MEASUREMENT ===';
GO
SELECT Scenario, Label, Value, Note FROM Demo.Results ORDER BY CapturedAt;
GO

PRINT '';
PRINT '=== 2. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario, Item;
GO

PRINT '';
PRINT '=== 3. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Detail, Verdict FROM Demo.Verdicts WHERE Verdict IN ('unexpected', 'INCONCLUSIVE', 'SKIPPED');
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 3 should be EMPTY. Anything in it is a';
PRINT ' genuine difference on your build, worth reading before';
PRINT ' you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql: it removes the backup files too.';
PRINT '========================================================';
GO
