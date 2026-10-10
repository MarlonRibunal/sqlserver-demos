/*==============================================================================
  03-cleanup.sql        RUN LAST. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Drops the LogFullDemo database. That is the whole cleanup.

  It is this short because 01-setup.sql deliberately changed nothing outside
  the database it created: no compatibility level, no database scoped
  configuration, no trace flag. The recovery model, log size and Service
  Broker belong to LogFullDemo and go with it. Its null-device backups leave
  ordinary history rows in msdb, pointing at NUL.

  The verification below confirms the database and its files are gone.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: drop LogFullDemo ===';
GO

IF DB_ID('LogFullDemo') IS NOT NULL
BEGIN
    -- SINGLE_USER first: 02-demo.sql may have left a session connected, and a
    -- plain DROP would fail on it.
    ALTER DATABASE LogFullDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE LogFullDemo;
    RAISERROR('  dropped database LogFullDemo', 0, 1) WITH NOWAIT;
END
ELSE
    RAISERROR('  LogFullDemo does not exist. Nothing to drop.', 0, 1) WITH NOWAIT;
GO


-- Scenario D's scratch database, in case a run was interrupted mid-way.
IF DB_ID('LogFullDemo_VLF') IS NOT NULL
BEGIN
    ALTER DATABASE LogFullDemo_VLF SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE LogFullDemo_VLF;
    RAISERROR('  dropped database LogFullDemo_VLF', 0, 1) WITH NOWAIT;
END
GO

PRINT '=== STEP 2: verify ===';
GO

SELECT  DemoDatabase = CASE WHEN DB_ID('LogFullDemo') IS NULL
                            THEN 'gone' ELSE 'STILL PRESENT' END;

-- An empty result set is the expected outcome and the point of printing it.
SELECT  LeftoverFile = physical_name
FROM    sys.master_files
WHERE   physical_name LIKE N'%LogFullDemo%';   -- both databases
GO

PRINT '';
PRINT '=== CLEANUP COMPLETE. ===';
GO
