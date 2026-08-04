/*==============================================================================
  03-cleanup.sql        RUN LAST. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Drops the TempdbDemo database. That is the whole cleanup.

  It is this short because 01-setup.sql deliberately changed nothing outside
  the database it created: no compatibility level, no database scoped
  configuration, no trace flag, no instance-wide cache flush. Every scenario in
  02-demo.sql was chosen so that it demonstrates its point without needing any
  of that.

  So there is no saved state to restore here and no chance of this script
  leaving your instance configured differently than it found it. The
  verification at the bottom prints the tempdb settings the demo talked about,
  so you can confirm for yourself that the demo never touched them.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: drop TempdbDemo ===';
GO

IF DB_ID('TempdbDemo') IS NOT NULL
BEGIN
    -- SINGLE_USER first: 02-demo.sql may have left a session connected, and a
    -- plain DROP would fail on it.
    ALTER DATABASE TempdbDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE TempdbDemo;
    RAISERROR('  dropped database TempdbDemo', 0, 1) WITH NOWAIT;
END
ELSE
    RAISERROR('  TempdbDemo does not exist. Nothing to drop.', 0, 1) WITH NOWAIT;
GO


PRINT '=== STEP 2: verify nothing else was touched ===';
GO

/*------------------------------------------------------------------------------
  These are the tempdb settings scenario D and the README discuss. The demo
  never wrote to any of them -- this is here so you do not have to take that
  claim on faith.

  On SQL Server 2016 and later you should see mixed page allocation OFF and
  autogrow all files ON for tempdb, with no trace flags enabled. Those are the
  defaults, which is exactly why TF 1117 and TF 1118 no longer belong in
  anyone's startup parameters.
------------------------------------------------------------------------------*/
SELECT  DatabaseName             = name,
        MixedPageAllocationOn    = is_mixed_page_allocation_on,
        CollationName            = collation_name
FROM    sys.databases
WHERE   name IN ('tempdb', 'master')
ORDER BY name;

SELECT  FilegroupName    = fg.name,
        AutogrowAllFiles = fg.is_autogrow_all_files
FROM    tempdb.sys.filegroups AS fg
WHERE   fg.type = 'FG';

SELECT  TempdbDataFiles = COUNT_BIG(*)
FROM    tempdb.sys.database_files
WHERE   type_desc = 'ROWS';

SELECT  DemoDatabase = CASE WHEN DB_ID('TempdbDemo') IS NULL
                            THEN 'gone' ELSE 'STILL PRESENT' END;
GO

-- Enabled trace flags, if any. An empty result set is the expected outcome and
-- the point of printing it.
DBCC TRACESTATUS(-1);
GO

PRINT '';
PRINT '=== CLEANUP COMPLETE. ===';
GO
