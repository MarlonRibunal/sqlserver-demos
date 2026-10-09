/*==============================================================================
  03-cleanup.sql        RUN LAST. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Drops the LockEscalationDemo database. That is the whole cleanup.

  It is this short because 01-setup.sql deliberately changed nothing outside
  the database it created: no compatibility level, no database scoped
  configuration, no trace flag. The LOCK_ESCALATION settings and the
  partition function belong to tables in the demo database, and go with it.
  Every probe in 02-demo.sql rolled back, so no locks are left behind.

  The verification below confirms the database and its files are gone.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: drop LockEscalationDemo ===';
GO

IF DB_ID('LockEscalationDemo') IS NOT NULL
BEGIN
    -- SINGLE_USER first: 02-demo.sql may have left a session connected, and a
    -- plain DROP would fail on it.
    ALTER DATABASE LockEscalationDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE LockEscalationDemo;
    RAISERROR('  dropped database LockEscalationDemo', 0, 1) WITH NOWAIT;
END
ELSE
    RAISERROR('  LockEscalationDemo does not exist. Nothing to drop.', 0, 1) WITH NOWAIT;
GO


PRINT '=== STEP 2: verify ===';
GO

SELECT  DemoDatabase = CASE WHEN DB_ID('LockEscalationDemo') IS NULL
                            THEN 'gone' ELSE 'STILL PRESENT' END;

-- An empty result set is the expected outcome and the point of printing it.
SELECT  LeftoverFile = physical_name
FROM    sys.master_files
WHERE   physical_name LIKE N'%LockEscalationDemo%';
GO

PRINT '';
PRINT '=== CLEANUP COMPLETE. ===';
GO
