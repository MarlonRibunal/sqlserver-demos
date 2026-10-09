/*==============================================================================
  03-cleanup.sql        RUN LAST. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Drops the UdfInliningDemo database. That is the whole cleanup.

  It is this short because 01-setup.sql deliberately changed nothing outside
  the database it created: no compatibility level, no database scoped
  configuration, no trace flag, no instance-wide cache flush. The WITH
  INLINE settings belong to functions in the demo database, and go with it.

  The plans 02-demo.sql compiled stay in the plan cache until the instance
  evicts them; dropping the database releases them. The verification below
  confirms the database and its files are gone.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: drop UdfInliningDemo ===';
GO

IF DB_ID('UdfInliningDemo') IS NOT NULL
BEGIN
    -- SINGLE_USER first: 02-demo.sql may have left a session connected, and a
    -- plain DROP would fail on it.
    ALTER DATABASE UdfInliningDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE UdfInliningDemo;
    RAISERROR('  dropped database UdfInliningDemo', 0, 1) WITH NOWAIT;
END
ELSE
    RAISERROR('  UdfInliningDemo does not exist. Nothing to drop.', 0, 1) WITH NOWAIT;
GO


PRINT '=== STEP 2: verify ===';
GO

SELECT  DemoDatabase = CASE WHEN DB_ID('UdfInliningDemo') IS NULL
                            THEN 'gone' ELSE 'STILL PRESENT' END;

-- An empty result set is the expected outcome and the point of printing it.
SELECT  LeftoverFile = physical_name
FROM    sys.master_files
WHERE   physical_name LIKE N'%UdfInliningDemo%';
GO

PRINT '';
PRINT '=== CLEANUP COMPLETE. ===';
GO
