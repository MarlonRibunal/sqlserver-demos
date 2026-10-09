/*==============================================================================
  03-cleanup.sql        RUN LAST. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Drops the TippingPointDemo database. That is the whole cleanup.

  It is this short because 01-setup.sql deliberately changed nothing outside
  the database it created: no compatibility level, no database scoped
  configuration, no trace flag, no instance-wide cache flush. The covering
  index scenario E creates is dropped by the demo itself.

  The plans 02-demo.sql compiled stay in the plan cache until the instance
  evicts them; dropping the database releases them. The verification below
  confirms the database and its files are gone.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: drop TippingPointDemo ===';
GO

IF DB_ID('TippingPointDemo') IS NOT NULL
BEGIN
    -- SINGLE_USER first: 02-demo.sql may have left a session connected, and a
    -- plain DROP would fail on it.
    ALTER DATABASE TippingPointDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE TippingPointDemo;
    RAISERROR('  dropped database TippingPointDemo', 0, 1) WITH NOWAIT;
END
ELSE
    RAISERROR('  TippingPointDemo does not exist. Nothing to drop.', 0, 1) WITH NOWAIT;
GO


PRINT '=== STEP 2: verify ===';
GO

SELECT  DemoDatabase = CASE WHEN DB_ID('TippingPointDemo') IS NULL
                            THEN 'gone' ELSE 'STILL PRESENT' END;

-- An empty result set is the expected outcome and the point of printing it.
SELECT  LeftoverFile = physical_name
FROM    sys.master_files
WHERE   physical_name LIKE N'%TippingPointDemo%';
GO

PRINT '';
PRINT '=== CLEANUP COMPLETE. ===';
GO
