/*==============================================================================
  03-cleanup.sql        RUN LAST. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Removes everything this topic created:

     - the backup files 02-demo.sql wrote, one by one, by name, from this
       instance's default backup folder (nothing else in that folder is
       touched)
     - the databases BackupDemo and BackupDemo_Copy
     - their backup and restore history in msdb

  The verification at the bottom confirms the databases, their files and
  the backup files are gone.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: delete the backup files ===';
GO

DECLARE @dir nvarchar(300) = CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(300));
DECLARE @sep nchar(1) = CASE WHEN CHARINDEX(N'\', @dir) > 0 THEN N'\' ELSE N'/' END;
IF RIGHT(@dir, 1) IN (N'\', N'/') SET @dir = LEFT(@dir, LEN(@dir) - 1);

IF OBJECT_ID('tempdb..#files') IS NOT NULL DROP TABLE #files;
CREATE TABLE #files (Name sysname NOT NULL, Path nvarchar(400) NULL, StillThere bit NULL);
INSERT #files (Name)
VALUES ('a_full'), ('a_log1'), ('a_log2'), ('b_full'), ('b_log1'), ('b_tail'),
       ('c_full'), ('c_adhoc'), ('c_diff'), ('c2_full'), ('c2_adhoc'), ('c2_diff'),
       ('d_plain'), ('d_compressed');
UPDATE #files SET Path = @dir + @sep + N'BackupDemo_' + Name + N'.bak';

DECLARE @path nvarchar(400);
DECLARE @exists TABLE (file_exists int, is_dir int, parent_exists int);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT Path FROM #files;
OPEN c;
FETCH NEXT FROM c INTO @path;
WHILE @@FETCH_STATUS = 0
BEGIN
    DELETE @exists;
    INSERT @exists EXEC master.sys.xp_fileexist @path;
    IF (SELECT file_exists FROM @exists) = 1
    BEGIN
        -- xp_delete_file 0, <one .bak file>: deletes that file only.
        EXEC master.sys.xp_delete_file 0, @path;
        RAISERROR('  deleted %s', 0, 1, @path) WITH NOWAIT;
    END
    DELETE @exists;
    INSERT @exists EXEC master.sys.xp_fileexist @path;
    UPDATE #files SET StillThere = (SELECT file_exists FROM @exists) WHERE Path = @path;
    FETCH NEXT FROM c INTO @path;
END
CLOSE c; DEALLOCATE c;
GO


PRINT '=== STEP 2: drop the databases and their msdb history ===';
GO

DECLARE @db sysname;
DECLARE d CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM (VALUES (N'BackupDemo_Copy'), (N'BackupDemo')) AS v (name);
OPEN d;
FETCH NEXT FROM d INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF DB_ID(@db) IS NOT NULL
    BEGIN
        IF DATABASEPROPERTYEX(@db, 'Status') = 'ONLINE'
            EXEC (N'ALTER DATABASE ' + @db + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;');
        EXEC (N'DROP DATABASE ' + @db + N';');
        RAISERROR('  dropped database %s', 0, 1, @db) WITH NOWAIT;
    END
    EXEC msdb.dbo.sp_delete_database_backuphistory @database_name = @db;
    FETCH NEXT FROM d INTO @db;
END
CLOSE d; DEALLOCATE d;
GO


PRINT '=== VERIFY ===';
GO
SELECT  Databases    = CASE WHEN DB_ID('BackupDemo') IS NULL AND DB_ID('BackupDemo_Copy') IS NULL
                            THEN 'gone' ELSE 'STILL PRESENT' END,
        DbFilesLeft  = (SELECT COUNT(*) FROM sys.master_files WHERE physical_name LIKE N'%BackupDemo%'),
        BackupFiles  = CASE WHEN EXISTS (SELECT 1 FROM #files WHERE StillThere = 1) THEN 'STILL PRESENT' ELSE 'gone' END,
        MsdbHistory  = CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.backupset WHERE database_name IN (N'BackupDemo', N'BackupDemo_Copy'))
                            THEN 'STILL PRESENT' ELSE 'gone' END;
GO
