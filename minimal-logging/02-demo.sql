/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  The same 200,000 rows (about 50 MB) are loaded seven ways, under each of
  the three recovery models, and the log each load writes is measured from
  its own transaction. Evidence lands in Demo.LogResults and Demo.Verdicts;
  the summary at the bottom is the payoff.

  Scenarios
    A  SIMPLE        -> which load shapes are minimally logged
    B  BULK_LOGGED   -> the same shapes, the same answers
    C  FULL          -> nothing minimal; TABLOCK loads log page images,
                        everything else logs every row

  This file switches MinimalLoggingDemo's recovery model and backs it up to
  the null device -- its own database only. See 01-setup.sql.

  Expected runtime: about a minute.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE MinimalLoggingDemo;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('Demo.usp_Load') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

TRUNCATE TABLE Demo.LogResults;
DROP TABLE IF EXISTS Demo.Verdicts;
CREATE TABLE Demo.Verdicts
(
    Scenario  varchar(60)   NOT NULL,
    Item      varchar(90)   NOT NULL,
    Detail    nvarchar(300) NULL,
    Expected  nvarchar(140) NULL,
    Verdict   varchar(24)   NULL
);
GO


/*==============================================================================
  SCENARIO A -- SIMPLE recovery

  "Minimally logged" means the log records page allocations rather than
  every row: a fraction of the data size. "Fully logged" means every row
  goes to the log -- the data size, and then some.

  What to look for (the tiers are defined in the VERDICTS section):
    - heap:            row by row without TABLOCK, minimal with it
    - heap + a nonclustered index, even WITH (TABLOCK): row by row
    - empty clustered: minimal with TABLOCK -- and REDUCED even without it,
                       because rows that go to brand-new pages are minimally
                       logged by default since SQL Server 2016
    - non-empty clustered WITH (TABLOCK), new keys above the old ones:
                       reduced, like the empty one without TABLOCK
    - SELECT ... INTO: minimal
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO A: SIMPLE ---';
GO

USE master;
ALTER DATABASE MinimalLoggingDemo SET RECOVERY SIMPLE;
GO
USE MinimalLoggingDemo;
GO

DECLARE @c varchar(4);
DECLARE cases CURSOR LOCAL FAST_FORWARD FOR
    SELECT c FROM (VALUES ('H1'),('H2'),('H3'),('C1'),('C2'),('C3'),('S1')) AS x(c);
OPEN cases; FETCH NEXT FROM cases INTO @c;
WHILE @@FETCH_STATUS = 0 BEGIN EXEC Demo.usp_Load @c; FETCH NEXT FROM cases INTO @c; END
CLOSE cases; DEALLOCATE cases;
GO


/*==============================================================================
  SCENARIO B -- BULK_LOGGED recovery

  BULK_LOGGED exists so that bulk operations can be minimally logged while
  the database keeps a log chain. The same seven loads; the prediction is
  the same answers as SIMPLE.

  The price, not measured here: a log backup that contains minimally logged
  work also has to copy the changed data pages, and you cannot restore that
  log backup to a point in time inside it.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO B: BULK_LOGGED ---';
GO

USE master;
ALTER DATABASE MinimalLoggingDemo SET RECOVERY BULK_LOGGED;
GO
USE MinimalLoggingDemo;
EXEC Demo.usp_NullBackup 'DATABASE';
GO

DECLARE @c varchar(4);
DECLARE cases CURSOR LOCAL FAST_FORWARD FOR
    SELECT c FROM (VALUES ('H1'),('H2'),('H3'),('C1'),('C2'),('C3'),('S1')) AS x(c);
OPEN cases; FETCH NEXT FROM cases INTO @c;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC Demo.usp_Load @c;
    EXEC Demo.usp_NullBackup 'LOG';      -- keep the log from accumulating
    FETCH NEXT FROM cases INTO @c;
END
CLOSE cases; DEALLOCATE cases;
GO


/*==============================================================================
  SCENARIO C -- FULL recovery

  Under FULL recovery nothing is minimally logged: that would make
  point-in-time restore impossible. But "fully logged" comes in two kinds.
  The loads that WOULD have been minimal (heap WITH TABLOCK, empty clustered
  WITH TABLOCK, SELECT INTO) log whole page images -- about the data size,
  in a few thousand records. Everything else logs every row, at more than
  the data size. TABLOCK still pays under FULL, just much less.

  "FULL" here is real FULL. A database switched to FULL behaves like SIMPLE
  until its first full backup starts a log chain ("pseudo-simple"), and a
  test that skips the backup measures the wrong thing. Demo.LogResults
  records RealFull for every FULL row, read from
  sys.database_recovery_status.last_log_backup_lsn.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO C: FULL ---';
GO

USE master;
ALTER DATABASE MinimalLoggingDemo SET RECOVERY FULL;
GO
USE MinimalLoggingDemo;
EXEC Demo.usp_NullBackup 'DATABASE';
EXEC Demo.usp_NullBackup 'LOG';
GO

DECLARE @c varchar(4);
DECLARE cases CURSOR LOCAL FAST_FORWARD FOR
    SELECT c FROM (VALUES ('H1'),('H2'),('H3'),('C1'),('C2'),('C3'),('S1')) AS x(c);
OPEN cases; FETCH NEXT FROM cases INTO @c;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC Demo.usp_Load @c;
    EXEC Demo.usp_NullBackup 'LOG';
    FETCH NEXT FROM cases INTO @c;
END
CLOSE cases; DEALLOCATE cases;
GO

-- Back to SIMPLE, as setup left it.
USE master;
ALTER DATABASE MinimalLoggingDemo SET RECOVERY SIMPLE;
GO
USE MinimalLoggingDemo;
GO


/*==============================================================================
  VERDICTS

  The log of a load falls into one of four tiers, told apart by its size
  against the data (~43 MB) and by its number of log records against the
  rows (200,000):

     minimal       under 3% of the data: allocations only
     reduced       3% to 25%: new pages minimally logged, the rest not
     page images   about the data size, but far fewer records than rows:
                   whole pages written to the log, not individual rows
     row by row    at least one log record per row, more than the data size

  The prediction for each load shape and recovery model is below. They were
  confirmed on the tested build; the README explains each.
==============================================================================*/
DECLARE @dataMB decimal(10,2) =
    (SELECT SUM(used_page_count) * 8 / 1024.0 FROM sys.dm_db_partition_stats WHERE object_id = OBJECT_ID('Demo.Source'));
DECLARE @rows bigint = (SELECT COUNT_BIG(*) FROM Demo.Source);

;WITH p AS
(
    SELECT  l.*,
            Predicted = CASE
                WHEN l.RecoveryModel = 'FULL' AND l.CaseID IN ('H2', 'C2', 'S1') THEN 'page images'
                WHEN l.RecoveryModel = 'FULL'                                    THEN 'row by row'
                WHEN l.CaseID IN ('H2', 'C2', 'S1')                              THEN 'minimal'
                WHEN l.CaseID IN ('C1', 'C3')                                    THEN 'reduced'
                ELSE 'row by row' END,
            Measured = CASE
                WHEN l.LogMB < @dataMB * 0.03                                    THEN 'minimal'
                WHEN l.LogMB < @dataMB * 0.25                                    THEN 'reduced'
                WHEN l.LogRecords < @rows / 5 AND l.LogMB < @dataMB * 1.2         THEN 'page images'
                WHEN l.LogRecords >= @rows                                       THEN 'row by row'
                ELSE 'other' END
    FROM    Demo.LogResults AS l
)
INSERT Demo.Verdicts (Scenario, Item, Detail, Expected, Verdict)
SELECT  p.RecoveryModel,
        p.CaseID + ': ' + p.Label,
        CAST(p.LogMB AS nvarchar(20)) + N' MB, ' + CAST(p.LogRecords AS nvarchar(20)) + N' log records ('
            + CAST(@dataMB AS nvarchar(20)) + N' MB, ' + CAST(@rows AS nvarchar(20)) + N' rows of data)'
            + CASE WHEN p.RealFull = 0 THEN N' -- WARNING: pseudo-simple' ELSE N'' END,
        p.Predicted,
        CASE WHEN p.RealFull = 0           THEN 'INCONCLUSIVE'
             WHEN p.Predicted = p.Measured THEN UPPER(p.Measured)
             ELSE 'unexpected' END
FROM    p;
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. LOG WRITTEN, MB, BY LOAD SHAPE AND RECOVERY MODEL ===';
GO
SELECT  CaseID,
        Label,
        SIMPLE      = MAX(CASE WHEN RecoveryModel = 'SIMPLE'      THEN LogMB END),
        BULK_LOGGED = MAX(CASE WHEN RecoveryModel = 'BULK_LOGGED' THEN LogMB END),
        [FULL]      = MAX(CASE WHEN RecoveryModel = 'FULL'        THEN LogMB END)
FROM    Demo.LogResults
GROUP BY CaseID, Label
ORDER BY CaseID;
GO

PRINT '';
PRINT '=== 2. EVERY LOAD ===';
GO
SELECT RecoveryModel, RealFull, CaseID, Label, LogMB, LogRecords, ElapsedMs FROM Demo.LogResults ORDER BY ResultID;
GO

PRINT '';
PRINT '=== 3. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario, Item;
GO

PRINT '';
PRINT '=== 4. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts WHERE Verdict IN ('unexpected', 'INCONCLUSIVE');
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 4 should be EMPTY. Anything in it is a';
PRINT ' genuine difference on your build, worth reading before';
PRINT ' you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
