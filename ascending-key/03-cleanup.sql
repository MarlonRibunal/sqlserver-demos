/*==============================================================================
  03-cleanup.sql        RUN LAST. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Drops the AscendingKeyDemo database. That is the whole cleanup.

  It is this short because 01-setup.sql deliberately changed nothing outside
  the database it created: no compatibility level, no database scoped
  configuration, no trace flag, no instance-wide cache flush. The legacy
  cardinality estimator and the histogram amendment were both reached through
  query hints, which live and die with the queries that carry them.

  So there is no saved state to restore here. The verification at the bottom
  confirms the database and its files are gone, and lists any enabled trace
  flags -- 2371, 2389, 2390 and 4139 are the ones this topic talks about, and
  the demo set none of them.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: drop AscendingKeyDemo ===';
GO

IF DB_ID('AscendingKeyDemo') IS NOT NULL
BEGIN
    -- SINGLE_USER first: 02-demo.sql may have left a session connected, and a
    -- plain DROP would fail on it.
    ALTER DATABASE AscendingKeyDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE AscendingKeyDemo;
    RAISERROR('  dropped database AscendingKeyDemo', 0, 1) WITH NOWAIT;
END
ELSE
    RAISERROR('  AscendingKeyDemo does not exist. Nothing to drop.', 0, 1) WITH NOWAIT;
GO


PRINT '=== STEP 2: verify ===';
GO

SELECT  DemoDatabase = CASE WHEN DB_ID('AscendingKeyDemo') IS NULL
                            THEN 'gone' ELSE 'STILL PRESENT' END;

SELECT  LeftoverFile = physical_name
FROM    sys.master_files
WHERE   physical_name LIKE N'%AscendingKeyDemo%';
GO

-- Enabled trace flags, if any. An empty result set is the expected outcome and
-- the point of printing it.
DBCC TRACESTATUS(-1);
GO

PRINT '';
PRINT '=== CLEANUP COMPLETE. ===';
GO
