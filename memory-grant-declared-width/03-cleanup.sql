/*==============================================================================
  03-cleanup.sql        RUN LAST. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Drops the GrantWidthDemo database. That is the whole cleanup.

  It is this short because 01-setup.sql deliberately changed nothing outside
  the database it created: no compatibility level, no database scoped
  configuration, no trace flag, no instance-wide cache flush. The Query
  Store that 02-demo.sql clears belongs to GrantWidthDemo and goes with it.

  The plans 02-demo.sql compiled stay in the plan cache until the instance
  evicts them; dropping the database releases them. The verification below
  confirms the database and its files are gone.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: drop GrantWidthDemo ===';
GO

IF DB_ID('GrantWidthDemo') IS NOT NULL
BEGIN
    -- SINGLE_USER first: 02-demo.sql may have left a session connected, and a
    -- plain DROP would fail on it.
    ALTER DATABASE GrantWidthDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE GrantWidthDemo;
    RAISERROR('  dropped database GrantWidthDemo', 0, 1) WITH NOWAIT;
END
ELSE
    RAISERROR('  GrantWidthDemo does not exist. Nothing to drop.', 0, 1) WITH NOWAIT;
GO


PRINT '=== STEP 2: verify ===';
GO

SELECT  DemoDatabase = CASE WHEN DB_ID('GrantWidthDemo') IS NULL
                            THEN 'gone' ELSE 'STILL PRESENT' END;

-- An empty result set is the expected outcome and the point of printing it.
SELECT  LeftoverFile = physical_name
FROM    sys.master_files
WHERE   physical_name LIKE N'%GrantWidthDemo%';
GO

PRINT '';
PRINT '=== CLEANUP COMPLETE. ===';
GO
