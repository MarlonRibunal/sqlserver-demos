/*==============================================================================
  03-cleanup.sql        RUN LAST. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Puts Resource Governor back as 01-setup.sql found it, then drops the
  TempGovDemo database.

  02-demo.sql already restores Resource Governor at the end. This does it
  again, in case the demo stopped halfway and left the 20 MB limit on the
  default workload group. The settings come from Demo.OriginalRG, so this
  must run BEFORE the database is dropped. If TempGovDemo is already gone,
  nothing is changed and the current settings are printed for you to check.

  The verification below confirms the settings, and that the database and
  its files are gone.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: put Resource Governor back ===';
GO

IF DB_ID('TempGovDemo') IS NOT NULL
   AND CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    EXEC TempGovDemo.Demo.usp_RestoreRG;
    RAISERROR('  restored the settings recorded by 01-setup.sql', 0, 1) WITH NOWAIT;
END
GO

PRINT '=== STEP 2: drop TempGovDemo ===';
GO

IF DB_ID('TempGovDemo') IS NOT NULL
BEGIN
    -- SINGLE_USER first: 02-demo.sql may have left a session connected, and a
    -- plain DROP would fail on it.
    ALTER DATABASE TempGovDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE TempGovDemo;
    RAISERROR('  dropped database TempGovDemo', 0, 1) WITH NOWAIT;
END
ELSE
    RAISERROR('  TempGovDemo does not exist. Nothing to drop.', 0, 1) WITH NOWAIT;
GO


PRINT '=== STEP 3: verify ===';
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
    EXEC (N'
    SELECT c.is_enabled                    AS ResourceGovernorEnabled,
           g.group_max_tempdb_data_mb      AS DefaultGroupTempdbMB,
           g.group_max_tempdb_data_percent AS DefaultGroupTempdbPercent
    FROM   sys.resource_governor_configuration AS c
    CROSS JOIN sys.resource_governor_workload_groups AS g
    WHERE  g.name = N''default'';');


SELECT  DemoDatabase = CASE WHEN DB_ID('TempGovDemo') IS NULL
                            THEN 'gone' ELSE 'STILL PRESENT' END;

-- An empty result set is the expected outcome and the point of printing it.
SELECT  LeftoverFile = physical_name
FROM    sys.master_files
WHERE   physical_name LIKE N'%TempGovDemo%';
GO

PRINT '';
PRINT '=== CLEANUP COMPLETE. ===';
GO
