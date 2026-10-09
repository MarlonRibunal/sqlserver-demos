/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, HeapDemo, and puts everything inside it.
     Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched

  Creates, all inside HeapDemo:
     Demo.Snapshots        - one row per measurement
     Demo.DemoResults      - verdict rows
     Demo.usp_Record       - the verdict collector
     Demo.usp_Build        - (re)builds a test table as a HEAP or CLUSTERED
     Demo.usp_Widen        - the update that makes rows grow
     Demo.usp_Snapshot     - measures a table and records a snapshot
     Demo.usp_WaitForGhosts - waits for ghost cleanup after a delete

  The test tables themselves are built by 02-demo.sql, through usp_Build,
  so that every scenario starts fresh and the demo can be re-run.

  COST: about 400 MB of data plus transaction log by the end of 02-demo.sql,
  all inside HeapDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create HeapDemo ===';
GO

IF DB_ID('HeapDemo') IS NOT NULL
BEGIN
    RAISERROR('HeapDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE HeapDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE HeapDemo;
END
GO

CREATE DATABASE HeapDemo;
GO

ALTER DATABASE HeapDemo SET RECOVERY SIMPLE;
GO

USE HeapDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: evidence tables ===';
GO

DROP TABLE IF EXISTS Demo.Snapshots;
CREATE TABLE Demo.Snapshots
(
    SnapshotID     int           IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Label          varchar(60)   NOT NULL,
    TableName      sysname       NOT NULL,
    Structure      varchar(20)   NULL,     -- HEAP or CLUSTERED
    RowCnt         bigint        NULL,
    DataPages      bigint        NULL,     -- leaf / data pages
    Forwarded      bigint        NULL,     -- forwarded_record_count
    DensityPct     decimal(6,2)  NULL,
    ScanReads      bigint        NULL,     -- one warm full scan, MAXDOP 1
    LookupReads    bigint        NULL,     -- 2,000 rows fetched through IX_Status
    CapturedAt     datetime2(3)  NOT NULL CONSTRAINT DF_HDSnap_CapturedAt DEFAULT SYSDATETIME()
);
GO

DROP TABLE IF EXISTS Demo.DemoResults;
CREATE TABLE Demo.DemoResults
(
    ResultID     int            IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Scenario     varchar(60)    NOT NULL,
    StepNo       int            NOT NULL,
    Item         varchar(90)    NOT NULL,
    Measure      varchar(40)    NULL,
    NumericValue decimal(18,3)  NULL,
    TextValue    nvarchar(200)  NULL,
    Expected     nvarchar(140)  NULL,
    Verdict      varchar(24)    NULL,
    CapturedAt   datetime2(3)   NOT NULL CONSTRAINT DF_HDResults_CapturedAt DEFAULT SYSDATETIME()
);
GO

CREATE OR ALTER PROCEDURE Demo.usp_Record
    @Scenario     varchar(60),
    @StepNo       int,
    @Item         varchar(90),
    @Measure      varchar(40)   = NULL,
    @NumericValue decimal(18,3) = NULL,
    @TextValue    nvarchar(200) = NULL,
    @Expected     nvarchar(140) = NULL,
    @Verdict      varchar(24)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT Demo.DemoResults
           (Scenario, StepNo, Item, Measure, NumericValue, TextValue, Expected, Verdict)
    VALUES (@Scenario, @StepNo, @Item, @Measure, @NumericValue, @TextValue, @Expected, @Verdict);
END
GO


PRINT '=== STEP 3: the procedures ===';
GO

/*------------------------------------------------------------------------------
  Demo.usp_Build -- (re)create @Table as a HEAP or with a CLUSTERED primary
  key, and load the same 100,000 rows into it.

  The row is a typical staging or log row: an id, a status, and a Notes
  column that starts SHORT (10 characters). Short rows pack about 290 to a
  page. Scenario A then lengthens Notes on a third of the rows, which is
  where a heap and a clustered index part ways.

  Status is 'X' on every 50th row -- 2,000 rows -- and has a nonclustered
  index, so scenario B can fetch those rows through it.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Build
    @Table     sysname,
    @Structure varchar(20)        -- 'HEAP' or 'CLUSTERED'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @tbl nvarchar(300) = QUOTENAME(PARSENAME(@Table, 2)) + N'.' + QUOTENAME(PARSENAME(@Table, 1));
    DECLARE @name sysname = PARSENAME(@Table, 1);
    DECLARE @sql nvarchar(max);

    SET @sql = N'DROP TABLE IF EXISTS ' + @tbl + N';
        CREATE TABLE ' + @tbl + N'
        (
            ID     int           NOT NULL,
            Status char(1)       NOT NULL,
            Notes  varchar(1000) NOT NULL
        );';
    EXEC sys.sp_executesql @sql;

    IF @Structure = 'CLUSTERED'
    BEGIN
        SET @sql = N'ALTER TABLE ' + @tbl + N' ADD CONSTRAINT ' + QUOTENAME(N'PK_' + @name)
                 + N' PRIMARY KEY CLUSTERED (ID);';
        EXEC sys.sp_executesql @sql;
    END

    SET @sql = N';WITH n AS
        (
            SELECT TOP (100000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
            FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
        )
        INSERT ' + @tbl + N' WITH (TABLOCK) (ID, Status, Notes)
        SELECT rn, CASE WHEN rn % 50 = 0 THEN ''X'' ELSE ''A'' END, REPLICATE(''n'', 10)
        FROM   n
        ORDER BY rn;

        CREATE INDEX ' + QUOTENAME(N'IX_' + @name + N'_Status') + N' ON ' + @tbl + N' (Status);';
    EXEC sys.sp_executesql @sql;
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_Widen -- the update that makes rows grow: Notes goes from 10
  characters to 400 on every third row. Rows that no longer fit on their page
  have to move.

     In a CLUSTERED index a row's position is fixed by its key, so the page
     SPLITS: half its rows move to a new page, and every row is still found
     where the index says it is.

     In a HEAP there is no key to keep in order. The row moves to any page
     with room, and leaves a FORWARDING POINTER in its old slot -- because
     every nonclustered index on the heap still points to the old slot.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Widen
    @Table sysname
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tbl nvarchar(300) = QUOTENAME(PARSENAME(@Table, 2)) + N'.' + QUOTENAME(PARSENAME(@Table, 1));
    DECLARE @sql nvarchar(400) = N'UPDATE ' + @tbl + N' SET Notes = REPLICATE(''w'', 400) WHERE ID % 3 = 0;';
    EXEC sys.sp_executesql @sql;
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_Snapshot -- measure @Table and record it.

  Structure, pages, forwarded records and density come from
  sys.dm_db_index_physical_stats in DETAILED mode (LIMITED returns NULL for
  forwarded_record_count and for density) on index 0 or 1 -- the heap or the
  clustered index itself, never the nonclustered index.

  Reads are deltas of sys.dm_exec_requests.logical_reads for this session,
  around:
     - a full scan:           COUNT of LEN(Notes), so every row is visited
     - a 2,000-row lookup:    SUM(LEN(Notes)) for Status = X, forced through
                              IX_..._Status so each row is fetched by lookup
  Each runs twice; the second, warm run is the one recorded.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Snapshot
    @Label varchar(60),
    @Table sysname
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @tbl  nvarchar(300) = QUOTENAME(PARSENAME(@Table, 2)) + N'.' + QUOTENAME(PARSENAME(@Table, 1));
    DECLARE @ix   nvarchar(300) = QUOTENAME(N'IX_' + PARSENAME(@Table, 1) + N'_Status');
    DECLARE @scan nvarchar(max) =
        N'DECLARE @c bigint; SELECT @c = SUM(CAST(LEN(Notes) AS bigint)) FROM ' + @tbl + N' WITH (INDEX(0)) OPTION (MAXDOP 1);';
    DECLARE @look nvarchar(max) =
        N'DECLARE @c bigint; SELECT @c = SUM(CAST(LEN(Notes) AS bigint)) FROM ' + @tbl
      + N' WITH (INDEX(' + @ix + N')) WHERE Status = ''X'' OPTION (MAXDOP 1);';
    DECLARE @r0 bigint, @scanReads bigint, @lookReads bigint;

    EXEC sys.sp_executesql @scan;
    SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    EXEC sys.sp_executesql @scan;
    SELECT @scanReads = logical_reads - @r0 FROM sys.dm_exec_requests WHERE session_id = @@SPID;

    EXEC sys.sp_executesql @look;
    SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    EXEC sys.sp_executesql @look;
    SELECT @lookReads = logical_reads - @r0 FROM sys.dm_exec_requests WHERE session_id = @@SPID;

    INSERT Demo.Snapshots
           (Label, TableName, Structure, RowCnt, DataPages, Forwarded, DensityPct, ScanReads, LookupReads)
    SELECT  @Label, @Table,
            CASE ps.index_id WHEN 0 THEN 'HEAP' ELSE 'CLUSTERED' END,
            ps.record_count - ISNULL(ps.forwarded_record_count, 0),
            ps.page_count,
            ISNULL(ps.forwarded_record_count, 0),
            ps.avg_page_space_used_in_percent,
            @scanReads, @lookReads
    FROM    sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(@Table), NULL, NULL, 'DETAILED') AS ps
    WHERE   ps.index_id IN (0, 1)
      AND   ps.index_level = 0
      AND   ps.alloc_unit_type_desc = 'IN_ROW_DATA';
END
GO


/*------------------------------------------------------------------------------
  Demo.usp_WaitForGhosts -- deleted rows in an index become ghost records,
  removed by a background task a few seconds later. Page counts read before
  then are wrong, so scenario C waits for this table to have none (bounded
  at 60 seconds).
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_WaitForGhosts
    @Table sysname
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @g bigint = 1, @waited int = 0;
    WHILE @g > 0 AND @waited < 60
    BEGIN
        SELECT @g = ISNULL(SUM(ghost_record_count), 0)
        FROM   sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(@Table), NULL, NULL, 'DETAILED')
        WHERE  index_id IN (0, 1);
        IF @g > 0
        BEGIN
            WAITFOR DELAY '00:00:02';
            SET @waited += 2;
        END
    END
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the HeapDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
