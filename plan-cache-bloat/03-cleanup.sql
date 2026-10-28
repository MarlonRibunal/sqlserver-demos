/*==============================================================================
  03-cleanup.sql        RUN LAST. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Puts back the two instance settings 01-setup.sql recorded ('show advanced
  options' and 'optimize for ad hoc workloads'), in case 02-demo.sql was
  stopped before it did, removes the demo's plans from the cache, and drops
  the PlanCacheDemo database.

  The verification below confirms the settings, and that the database and
  its files are gone.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: restore the instance settings ===';
GO

IF DB_ID('PlanCacheDemo') IS NOT NULL
   AND OBJECT_ID('PlanCacheDemo.Demo.usp_RestoreConfig') IS NOT NULL
BEGIN
    EXEC PlanCacheDemo.Demo.usp_RestoreConfig;
    SELECT  c.name, RecordedAtSetup = o.ValueInUse, NowInUse = c.value_in_use,
            Status = CASE WHEN CAST(c.value_in_use AS int) = o.ValueInUse THEN 'restored' ELSE 'DIFFERENT' END
    FROM    PlanCacheDemo.Demo.OriginalConfig AS o
    JOIN    sys.configurations AS c ON c.name = o.Name;

    EXEC PlanCacheDemo.Demo.usp_Evict N'adhoc_a';
    EXEC PlanCacheDemo.Demo.usp_Evict N'simple_b';
    EXEC PlanCacheDemo.Demo.usp_Evict N'stub_c';
    EXEC PlanCacheDemo.Demo.usp_Evict N'forced_d';
    EXEC PlanCacheDemo.Demo.usp_Evict N'param_e';
END
ELSE
    RAISERROR('  PlanCacheDemo is gone, so there are no recorded settings to restore.', 0, 1) WITH NOWAIT;
GO


PRINT '=== STEP 2: drop PlanCacheDemo ===';
GO

IF DB_ID('PlanCacheDemo') IS NOT NULL
BEGIN
    -- SINGLE_USER first: 02-demo.sql may have left a session connected, and a
    -- plain DROP would fail on it.
    ALTER DATABASE PlanCacheDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE PlanCacheDemo;
    RAISERROR('  dropped database PlanCacheDemo', 0, 1) WITH NOWAIT;
END
ELSE
    RAISERROR('  PlanCacheDemo does not exist. Nothing to drop.', 0, 1) WITH NOWAIT;
GO


PRINT '=== STEP 3: verify ===';
GO

SELECT  DemoDatabase = CASE WHEN DB_ID('PlanCacheDemo') IS NULL
                            THEN 'gone' ELSE 'STILL PRESENT' END;

-- An empty result set is the expected outcome and the point of printing it.
SELECT  LeftoverFile = physical_name
FROM    sys.master_files
WHERE   physical_name LIKE N'%PlanCacheDemo%';
GO

PRINT '';
PRINT '=== CLEANUP COMPLETE. ===';
GO
