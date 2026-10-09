/*==============================================================================
  03-cleanup.sql        RUN LAST. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Drops the BlockingDemo database. That is the whole cleanup.

  It is this short because 01-setup.sql deliberately changed nothing outside
  the database it created: no compatibility level, no database scoped
  configuration, no trace flag, no instance setting. Service Broker and its
  queues belong to BlockingDemo and go with it.

  The plans 02-demo.sql compiled stay in the plan cache until the instance
  evicts them; dropping the database releases them. The verification below
  confirms the database and its files are gone.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: drop BlockingDemo ===';
GO

IF DB_ID('BlockingDemo') IS NOT NULL
BEGIN
    -- SINGLE_USER first: 02-demo.sql may have left a session connected, and a
    -- plain DROP would fail on it.
    ALTER DATABASE BlockingDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE BlockingDemo;
    RAISERROR('  dropped database BlockingDemo', 0, 1) WITH NOWAIT;
END
ELSE
    RAISERROR('  BlockingDemo does not exist. Nothing to drop.', 0, 1) WITH NOWAIT;
GO


PRINT '=== STEP 2: verify ===';
GO

SELECT  DemoDatabase = CASE WHEN DB_ID('BlockingDemo') IS NULL
                            THEN 'gone' ELSE 'STILL PRESENT' END;

-- An empty result set is the expected outcome and the point of printing it.
SELECT  LeftoverFile = physical_name
FROM    sys.master_files
WHERE   physical_name LIKE N'%BlockingDemo%';
GO

PRINT '';
PRINT '=== CLEANUP COMPLETE. ===';
GO
