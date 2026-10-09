/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, MinimalLoggingDemo, and puts everything
     inside it. Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched

     02-demo.sql switches MinimalLoggingDemo between the SIMPLE, BULK_LOGGED
     and FULL recovery models -- its own database only -- and takes backups
     of it to the NULL DEVICE, DISK = N'NUL' (which SQL Server accepts on
     Linux as well as Windows; /dev/null does NOT work there). Those
     backups exist only to start a log chain, so FULL recovery really is
     FULL. They write no file anywhere. Do not copy that trick to a database
     you care about: a backup to the null device is a backup you cannot
     restore, and it breaks the chain your real backups rely on.

  Creates, all inside MinimalLoggingDemo:
     Demo.Source         - 200,000 rows, about 50 MB: what every load copies
     Demo.LogResults     - one row per measured load
     Demo.usp_Load       - builds a target, loads it in a transaction, and
                           records the log that transaction wrote
     Demo.usp_NullBackup - BACKUP DATABASE / LOG to the null device

  COST: up to about 1 GB of data plus transaction log during the FULL
  recovery runs, all inside MinimalLoggingDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create MinimalLoggingDemo ===';
GO

IF DB_ID('MinimalLoggingDemo') IS NOT NULL
BEGIN
    RAISERROR('MinimalLoggingDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE MinimalLoggingDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE MinimalLoggingDemo;
END
GO

CREATE DATABASE MinimalLoggingDemo;
GO

ALTER DATABASE MinimalLoggingDemo SET RECOVERY SIMPLE;
-- Room to work without autogrowth events muddying the timings.
ALTER DATABASE MinimalLoggingDemo MODIFY FILE (NAME = N'MinimalLoggingDemo_log', SIZE = 512MB, FILEGROWTH = 256MB);
GO

USE MinimalLoggingDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: the source rows ===';
GO

DROP TABLE IF EXISTS Demo.Source;
CREATE TABLE Demo.Source
(
    ID     int        NOT NULL,
    D      date       NOT NULL,
    Amount int        NOT NULL,
    pad    char(200)  NOT NULL
);
GO

;WITH n AS
(
    SELECT TOP (200000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.Source WITH (TABLOCK) (ID, D, Amount, pad)
SELECT rn, DATEADD(day, rn % 3650, CAST('20160101' AS date)), rn % 1000, 'x'
FROM   n;
GO

SELECT Rows = COUNT_BIG(*),
       DataMB = (SELECT SUM(used_page_count) * 8 / 1024.0 FROM sys.dm_db_partition_stats
                 WHERE object_id = OBJECT_ID('Demo.Source'))
FROM   Demo.Source;
GO


PRINT '=== STEP 3: evidence table and procedures ===';
GO

DROP TABLE IF EXISTS Demo.LogResults;
CREATE TABLE Demo.LogResults
(
    ResultID      int            IDENTITY(1,1) NOT NULL PRIMARY KEY,
    RecoveryModel varchar(20)    NOT NULL,
    RealFull      bit            NULL,      -- FULL with a log chain, not "pseudo-simple"
    CaseID        varchar(4)     NOT NULL,
    Label         varchar(90)    NOT NULL,
    LogMB         decimal(10,2)  NULL,      -- log written by the load's transaction
    LogRecords    bigint         NULL,
    ElapsedMs     int            NULL,
    CapturedAt    datetime2(3)   NOT NULL CONSTRAINT DF_MLResults_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  Demo.usp_Load -- build one target table shape, then load all 200,000 source
  rows into it inside an explicit transaction, and record what that
  transaction wrote to the log.

  The log figures come from sys.dm_tran_database_transactions for THIS
  transaction (CURRENT_TRANSACTION_ID(), 2016+), read just before COMMIT:
  database_transaction_log_bytes_used and _log_record_count. That is the
  load's own log, exactly, unaffected by checkpoints or anything else
  writing to the log at the same time.

  The cases:
     H1  heap                                 INSERT ... SELECT
     H2  heap                                 INSERT ... WITH (TABLOCK) SELECT
     H3  heap with a nonclustered index       INSERT ... WITH (TABLOCK) SELECT
     C1  empty clustered index                INSERT ... SELECT
     C2  empty clustered index                INSERT ... WITH (TABLOCK) SELECT
     C3  clustered index, already 200,000     INSERT ... WITH (TABLOCK) SELECT,
         rows in it                             new keys above the existing ones
     S1  SELECT ... INTO a new table
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Load
    @CaseID varchar(4)
AS
BEGIN
    SET NOCOUNT ON;

    DROP TABLE IF EXISTS Demo.Target;

    IF @CaseID IN ('H1', 'H2', 'H3')
        CREATE TABLE Demo.Target (ID int NOT NULL, D date NOT NULL, Amount int NOT NULL, pad char(200) NOT NULL);
    IF @CaseID = 'H3'
        CREATE INDEX IX_Target_D ON Demo.Target (D);
    IF @CaseID IN ('C1', 'C2', 'C3')
        CREATE TABLE Demo.Target (ID int NOT NULL PRIMARY KEY CLUSTERED, D date NOT NULL, Amount int NOT NULL, pad char(200) NOT NULL);
    IF @CaseID = 'C3'
        -- Pre-existing rows, loaded and committed before the measured transaction.
        INSERT Demo.Target WITH (TABLOCK) (ID, D, Amount, pad)
        SELECT ID, D, Amount, pad FROM Demo.Source;

    CHECKPOINT;   -- in SIMPLE, clear the log of the setup work before measuring

    DECLARE @t0 datetime2(7) = SYSDATETIME();
    DECLARE @bytes bigint, @recs bigint;

    BEGIN TRANSACTION;

        IF @CaseID IN ('H1', 'C1')
            INSERT Demo.Target (ID, D, Amount, pad) SELECT ID, D, Amount, pad FROM Demo.Source;
        IF @CaseID IN ('H2', 'H3', 'C2')
            INSERT Demo.Target WITH (TABLOCK) (ID, D, Amount, pad) SELECT ID, D, Amount, pad FROM Demo.Source;
        IF @CaseID = 'C3'
            INSERT Demo.Target WITH (TABLOCK) (ID, D, Amount, pad) SELECT ID + 1000000, D, Amount, pad FROM Demo.Source;
        IF @CaseID = 'S1'
            SELECT ID, D, Amount, pad INTO Demo.Target FROM Demo.Source;

        SELECT @bytes = database_transaction_log_bytes_used,
               @recs  = database_transaction_log_record_count
        FROM   sys.dm_tran_database_transactions
        WHERE  transaction_id = CURRENT_TRANSACTION_ID()
          AND  database_id    = DB_ID();

    COMMIT;

    DECLARE @model varchar(20) = (SELECT recovery_model_desc FROM sys.databases WHERE database_id = DB_ID());
    DECLARE @realFull bit =
        CASE WHEN @model <> 'FULL' THEN NULL
             WHEN (SELECT last_log_backup_lsn FROM sys.database_recovery_status WHERE database_id = DB_ID()) IS NOT NULL THEN 1
             ELSE 0 END;

    INSERT Demo.LogResults (RecoveryModel, RealFull, CaseID, Label, LogMB, LogRecords, ElapsedMs)
    VALUES (@model, @realFull, @CaseID,
            CASE @CaseID
                 WHEN 'H1' THEN 'heap, INSERT ... SELECT'
                 WHEN 'H2' THEN 'heap, INSERT WITH (TABLOCK)'
                 WHEN 'H3' THEN 'heap + nonclustered index, WITH (TABLOCK)'
                 WHEN 'C1' THEN 'empty clustered index, INSERT ... SELECT'
                 WHEN 'C2' THEN 'empty clustered index, WITH (TABLOCK)'
                 WHEN 'C3' THEN 'non-empty clustered index, WITH (TABLOCK)'
                 WHEN 'S1' THEN 'SELECT ... INTO' END,
            @bytes / 1048576.0, @recs, DATEDIFF(millisecond, @t0, SYSDATETIME()));

    DROP TABLE IF EXISTS Demo.Target;
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_NullBackup -- BACKUP DATABASE or BACKUP LOG of this database to
  the null device. Used only to give FULL recovery a log chain (DATABASE)
  and to keep the log from growing between FULL-recovery loads (LOG).
  Nothing is written to disk. Never do this to a database you need to
  restore.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_NullBackup
    @Kind varchar(10)          -- 'DATABASE' or 'LOG'
AS
BEGIN
    SET NOCOUNT ON;
    -- N'NUL' on every platform. On Linux, DISK = '/dev/null' fails with
    -- OS error 31 while SQL Server tries to size the file; 'NUL' is accepted
    -- as the null device there too.
    DECLARE @device nvarchar(20) = N'NUL';
    -- Deliberately NOT COPY_ONLY: a copy-only backup does not start a log
    -- chain, which is the only reason for this backup.
    DECLARE @sql nvarchar(400) =
        N'BACKUP ' + CASE @Kind WHEN 'LOG' THEN N'LOG' ELSE N'DATABASE' END
      + N' MinimalLoggingDemo TO DISK = N''' + @device + N''';';
    EXEC sys.sp_executesql @sql;
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the MinimalLoggingDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
