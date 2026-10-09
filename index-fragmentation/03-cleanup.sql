/*==============================================================================
  03-cleanup.sql        RUN LAST. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Drops the FragmentationDemo database, and its five extra data files with it.
  That is the whole cleanup.

  It is this short because 01-setup.sql deliberately changed nothing outside
  the database it created: no compatibility level, no database scoped
  configuration, no trace flag, no instance-wide cache flush. The shrink in
  setup and the offline/online cycle in 02-demo.sql both acted on
  FragmentationDemo alone.

  So there is no saved state to restore here. The verification at the bottom
  confirms the database and its files are gone.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: drop FragmentationDemo ===';
GO

IF DB_ID('FragmentationDemo') IS NOT NULL
BEGIN
    -- SINGLE_USER first: 02-demo.sql may have left a session connected, and a
    -- plain DROP would fail on it.
    ALTER DATABASE FragmentationDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE FragmentationDemo;
    RAISERROR('  dropped database FragmentationDemo', 0, 1) WITH NOWAIT;
END
ELSE
    RAISERROR('  FragmentationDemo does not exist. Nothing to drop.', 0, 1) WITH NOWAIT;
GO


PRINT '=== STEP 2: verify ===';
GO

SELECT  DemoDatabase = CASE WHEN DB_ID('FragmentationDemo') IS NULL
                            THEN 'gone' ELSE 'STILL PRESENT' END;

-- Any file the instance still knows about under the demo's name. An empty
-- result set is the expected outcome and the point of printing it.
SELECT  LeftoverFile = physical_name
FROM    sys.master_files
WHERE   physical_name LIKE N'%FragmentationDemo%';
GO

PRINT '';
PRINT '=== CLEANUP COMPLETE. ===';
GO
