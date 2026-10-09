/*==============================================================================
  01-setup.sql          RUN ONCE. Takes under a minute.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, FragmentationDemo, and puts everything inside
     it. Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched
        - no instance-wide buffer or plan cache flush

     It DOES run DBCC SHRINKFILE -- but only on a file of FragmentationDemo,
     and only to manufacture the fragmentation scenario A needs. See STEP 4.

  Creates, all inside FragmentationDemo:
     five filegroups, one file each   - so every table's I/O can be measured
                                        on its own file (scenario D)
     Demo.DemoState          - environment facts recorded at setup time
     Demo.DemoResults        - where 02-demo.sql records its verdicts
     Demo.IndexSnapshots     - fragmentation, density and reads, per table
     Demo.usp_Record         - the verdict collector used by 02
     Demo.usp_BuildTable     - builds a table in one of four shapes
     Demo.usp_Snapshot       - measures a table and records a snapshot
     Demo.fn_RuleSays        - the "5% / 30%" rule, as a function
     Demo.Dense              - the control: in order, full pages
     Demo.Scattered          - out of order, full pages      (scenario A)
     Demo.Sparse             - in order, half-empty pages    (scenario B)
     Demo.Random             - random GUID key, page splits  (scenario C)

  COST: setup itself needs about 200 MB. By the end of 02-demo.sql the
  database has grown to roughly 900 MB: about 600 MB of data files and 260 MB
  of log. All of it is inside FragmentationDemo, and 03-cleanup.sql releases
  it.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers,
  Linux container on NVMe storage.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 0: environment ===';
GO

SELECT  ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS sysname),
        EngineMajor    = CAST(SERVERPROPERTY('ProductMajorVersion') AS int),
        Edition        = CAST(SERVERPROPERTY('Edition') AS sysname);

SELECT  Schedulers = cpu_count FROM sys.dm_os_sys_info;
GO


PRINT '=== STEP 1: create FragmentationDemo ===';
GO

/*------------------------------------------------------------------------------
  One filegroup per table, each with a single file. Two reasons:

    1. Scenario D reads sys.dm_io_virtual_file_stats to count the physical
       I/Os a cold scan issues. That DMV is per FILE, so a table that owns its
       file is a table whose I/O can be measured exactly, with nothing else
       mixed in.

    2. The shrink in STEP 4 must move Demo.Scattered's pages and nobody
       else's. Shrinking a file that holds only that table guarantees it.

  The files are created in the instance's default data directory, so this
  works unchanged on Windows and Linux.
------------------------------------------------------------------------------*/
IF DB_ID('FragmentationDemo') IS NOT NULL
BEGIN
    RAISERROR('FragmentationDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE FragmentationDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE FragmentationDemo;
END
GO

CREATE DATABASE FragmentationDemo;
GO

ALTER DATABASE FragmentationDemo SET RECOVERY SIMPLE;
GO

DECLARE @dir nvarchar(512) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(512));
DECLARE @fg sysname, @sql nvarchar(max);

DECLARE fgs CURSOR LOCAL FAST_FORWARD FOR
    SELECT fg FROM (VALUES ('FG_Dense'), ('FG_Scattered'), ('FG_Sparse'),
                           ('FG_Random'), ('FG_Work')) AS x(fg);
OPEN fgs;
FETCH NEXT FROM fgs INTO @fg;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'ALTER DATABASE FragmentationDemo ADD FILEGROUP ' + QUOTENAME(@fg) + N';'
             + N'ALTER DATABASE FragmentationDemo ADD FILE (NAME = N''' + @fg + N''', '
             + N'FILENAME = N''' + @dir + N'FragmentationDemo_' + @fg + N'.ndf'', '
             + N'SIZE = 16MB, FILEGROWTH = 64MB) TO FILEGROUP ' + QUOTENAME(@fg) + N';';
    EXEC sys.sp_executesql @sql;
    RAISERROR('  added filegroup %s', 0, 1, @fg) WITH NOWAIT;
    FETCH NEXT FROM fgs INTO @fg;
END
CLOSE fgs;
DEALLOCATE fgs;
GO

USE FragmentationDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: state, evidence, and the procedures ===';
GO

DROP TABLE IF EXISTS Demo.DemoState;
CREATE TABLE Demo.DemoState
(
    SettingName  sysname       NOT NULL PRIMARY KEY,
    SettingValue nvarchar(256) NULL,
    CapturedAt   datetime2(0)  NOT NULL CONSTRAINT DF_FDState_CapturedAt DEFAULT SYSDATETIME()
);
GO

INSERT Demo.DemoState (SettingName, SettingValue)
VALUES ('ProductVersion', CAST(SERVERPROPERTY('ProductVersion')           AS nvarchar(256))),
       ('Schedulers',     CAST((SELECT cpu_count FROM sys.dm_os_sys_info) AS nvarchar(256))),
       ('RowsPerTable',   N'100000');
GO

DROP TABLE IF EXISTS Demo.DemoResults;
CREATE TABLE Demo.DemoResults
(
    ResultID     int            IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Scenario     varchar(60)    NOT NULL,
    StepNo       int            NOT NULL,
    Item         varchar(90)    NOT NULL,   -- what was measured
    Measure      varchar(40)    NULL,       -- the unit / metric name
    NumericValue decimal(18,3)  NULL,
    TextValue    nvarchar(200)  NULL,
    Expected     nvarchar(140)  NULL,       -- what the scenario predicts
    Verdict      varchar(24)    NULL,       -- filled in by the scenario itself
    CapturedAt   datetime2(3)   NOT NULL CONSTRAINT DF_FDResults_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  One row per "measure this table now". The two columns the whole topic is
  about sit side by side on purpose:

     FragPct     avg_fragmentation_in_percent    -- what maintenance jobs read
     DensityPct  avg_page_space_used_in_percent  -- what your queries pay for
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.IndexSnapshots;
CREATE TABLE Demo.IndexSnapshots
(
    SnapshotID     int           IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Label          varchar(60)   NOT NULL,
    TableName      sysname       NOT NULL,
    RowCnt         bigint        NULL,
    LeafPages      bigint        NULL,
    FragPct        decimal(6,2)  NULL,
    DensityPct     decimal(6,2)  NULL,
    Fragments      bigint        NULL,
    LogicalReads   bigint        NULL,     -- one warm full scan, MAXDOP 1
    BufferPoolMB   decimal(10,2) NULL,     -- the table's pages in memory after it
    CapturedAt     datetime2(3)  NOT NULL CONSTRAINT DF_FDSnap_CapturedAt DEFAULT SYSDATETIME()
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

/*------------------------------------------------------------------------------
  Demo.usp_BuildTable -- (re)builds @Table in @FileGroup in one of four shapes.

  Every shape ends with the SAME 100,000 rows of the SAME width, so that any
  difference in reads between two tables is caused by how the pages are laid
  out, not by what is on them. The row is (id int, g uniqueidentifier,
  pad char(200)); only the clustering key changes.

     dense      clustered on id, loaded in order, rebuilt.
                In order, full pages. The control.

     scattered  as dense, then DBCC SHRINKFILE reverses its page order.
                Out of order, full pages. Nothing else.

     sparse     200,000 rows in order, then every even id deleted.
                In order, half-empty pages. Nothing else.

     random     clustered on g = NEWID(), loaded in 100 batches.
                Page splits everywhere -- out of order AND part-empty.

  02-demo.sql calls this too, to build fresh victims for scenario E, which is
  why it is a procedure and not inline setup code: the demo has to be
  re-runnable without re-running setup.

  Every shape is verified after it is built. A "scattered" table that came out
  of the shrink in order would make scenario A prove nothing, so the procedure
  raises an error instead of returning a table that only looks right.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_BuildTable
    @Shape     varchar(10),
    @Table     sysname,          -- schema-qualified, e.g. 'Demo.Dense'
    @FileGroup sysname
AS
BEGIN
    SET NOCOUNT ON;

    IF @Shape NOT IN ('dense', 'scattered', 'sparse', 'random')
    BEGIN
        RAISERROR('usp_BuildTable: unknown shape %s', 16, 1, @Shape);
        RETURN;
    END

    DECLARE @rows int = 100000;
    DECLARE @tbl  nvarchar(300) = QUOTENAME(PARSENAME(@Table, 2)) + N'.' + QUOTENAME(PARSENAME(@Table, 1));
    DECLARE @pk   nvarchar(300) = QUOTENAME(N'PK_' + PARSENAME(@Table, 1));
    DECLARE @fg   nvarchar(300) = QUOTENAME(@FileGroup);
    DECLARE @file sysname =
        (SELECT TOP (1) df.name
         FROM   sys.database_files AS df
         JOIN   sys.filegroups     AS fg ON fg.data_space_id = df.data_space_id
         WHERE  fg.name = @FileGroup);
    DECLARE @sql  nvarchar(max);

    -- Numbers come from a cross join rather than a numbers table so that the
    -- procedure has no dependencies beyond the system catalog.
    DECLARE @nums nvarchar(400) =
        N'SELECT TOP (@n) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
          FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b';

    SET @sql = N'DROP TABLE IF EXISTS ' + @tbl + N';';
    EXEC sys.sp_executesql @sql;

    IF @Shape = 'scattered'
    BEGIN
        /*----------------------------------------------------------------------
          The classic way to fragment an index without touching its density:
          shrink the file it lives in.

          A filler table goes into the file FIRST, the real table AFTER it.
          Dropping the filler leaves a hole at the front of the file. SHRINKFILE
          then fills that hole by moving pages from the END of the file, one at
          a time, working backwards -- so the table's last page becomes its
          first, and its page order comes out almost perfectly reversed.

          Pages are moved whole. Not one row changes page, which is precisely
          why density is untouched.

          This is also the lesson about shrink itself: run it in production and
          this is what it does to every index in the file.
        ----------------------------------------------------------------------*/
        SET @sql = N'DROP TABLE IF EXISTS Demo.ShrinkFiller;
            CREATE TABLE Demo.ShrinkFiller (id int NOT NULL, pad char(4000) NOT NULL) ON ' + @fg + N';
            INSERT Demo.ShrinkFiller WITH (TABLOCK) (id, pad)
            SELECT rn, ''x'' FROM (' + @nums + N') AS n;';
        -- Filler sized to roughly match the table: 2 rows per page.
        EXEC sys.sp_executesql @sql, N'@n int', @n = 6000;
    END

    IF @Shape = 'random'
        SET @sql = N'CREATE TABLE ' + @tbl + N'
            (id int NOT NULL, g uniqueidentifier NOT NULL, pad char(200) NOT NULL,
             CONSTRAINT ' + @pk + N' PRIMARY KEY CLUSTERED (g)) ON ' + @fg + N';';
    ELSE
        SET @sql = N'CREATE TABLE ' + @tbl + N'
            (id int NOT NULL, g uniqueidentifier NOT NULL, pad char(200) NOT NULL,
             CONSTRAINT ' + @pk + N' PRIMARY KEY CLUSTERED (id)) ON ' + @fg + N';';
    EXEC sys.sp_executesql @sql;

    IF @Shape IN ('dense', 'scattered')
    BEGIN
        SET @sql = N'INSERT ' + @tbl + N' WITH (TABLOCK) (id, g, pad)
            SELECT rn, NEWID(), ''x'' FROM (' + @nums + N') AS n;
            ALTER INDEX ' + @pk + N' ON ' + @tbl + N' REBUILD;';
        EXEC sys.sp_executesql @sql, N'@n int', @n = @rows;
    END

    IF @Shape = 'scattered'
    BEGIN
        DROP TABLE Demo.ShrinkFiller;
        DBCC SHRINKFILE (@file, 1) WITH NO_INFOMSGS;
    END

    IF @Shape = 'sparse'
    BEGIN
        /*----------------------------------------------------------------------
          A purge job, in miniature: load twice the rows, delete every other
          one. Each page keeps half its rows, so the pages stay exactly where
          they were and in exactly the same order -- 0% fragmentation -- while
          half of every page is now empty.

          Deleted rows are not removed immediately. They become GHOST records,
          and a background task reclaims the space a few seconds later. Until it
          does, the density figure is wrong, so this waits for ghost_record_count
          to reach zero (bounded at two minutes) rather than measuring too early.
        ----------------------------------------------------------------------*/
        SET @sql = N'INSERT ' + @tbl + N' WITH (TABLOCK) (id, g, pad)
            SELECT rn, NEWID(), ''x'' FROM (' + @nums + N') AS n;
            ALTER INDEX ' + @pk + N' ON ' + @tbl + N' REBUILD;
            DELETE ' + @tbl + N' WHERE id % 2 = 0;';
        -- Into a variable first: an EXEC argument cannot be an expression.
        DECLARE @doubled int = @rows * 2;
        EXEC sys.sp_executesql @sql, N'@n int', @n = @doubled;

        DECLARE @ghosts bigint = 1, @waited int = 0;
        WHILE @ghosts > 0 AND @waited < 120
        BEGIN
            SELECT @ghosts = SUM(ghost_record_count)
            FROM   sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(@Table), 1, NULL, 'DETAILED')
            WHERE  index_level = 0;

            IF @ghosts > 0
            BEGIN
                WAITFOR DELAY '00:00:02';
                SET @waited += 2;
            END
        END

        IF @ghosts > 0
            RAISERROR('usp_BuildTable: %I64d ghost records remain in %s after 120 s. Density will read low-but-wrong.', 10, 1, @ghosts, @Table) WITH NOWAIT;
    END

    IF @Shape = 'random'
    BEGIN
        -- 100 separate inserts, not one. A single INSERT ... SELECT would sort
        -- its rows by the key first and fill pages in order; this is the
        -- application-shaped pattern, where rows arrive scattered across the
        -- whole key range, and that is what causes mid-page splits.
        SET @sql = N'DECLARE @b int = 0;
            WHILE @b < 100
            BEGIN
                INSERT ' + @tbl + N' (id, g, pad)
                SELECT @b * (@n / 100) + rn, NEWID(), ''x''
                FROM (SELECT TOP (@n / 100) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
                      FROM sys.all_columns) AS n;
                SET @b += 1;
            END';
        EXEC sys.sp_executesql @sql, N'@n int', @n = @rows;
    END

    -- Verify the shape. These are wide tolerances on purpose: they catch a
    -- build that did not happen, not a few points of drift.
    DECLARE @frag float, @dens float, @cnt bigint;
    SELECT @frag = avg_fragmentation_in_percent,
           @dens = avg_page_space_used_in_percent,
           @cnt  = record_count
    FROM   sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(@Table), 1, NULL, 'DETAILED')
    WHERE  index_level = 0;

    DECLARE @ok bit =
        CASE WHEN @cnt <> @rows                                      THEN 0
             WHEN @Shape = 'dense'     AND (@frag > 5  OR @dens < 95) THEN 0
             WHEN @Shape = 'scattered' AND (@frag < 90 OR @dens < 95) THEN 0
             WHEN @Shape = 'sparse'    AND (@frag > 5  OR @dens > 60) THEN 0
             WHEN @Shape = 'random'    AND (@frag < 90 OR @dens > 85) THEN 0
             ELSE 1 END;

    DECLARE @fragTxt varchar(20) = CAST(CAST(@frag AS decimal(6,2)) AS varchar(20)),
            @densTxt varchar(20) = CAST(CAST(@dens AS decimal(6,2)) AS varchar(20));

    IF @ok = 0
        RAISERROR('usp_BuildTable: %s did not come out %s (rows %I64d, fragmentation %s%%, density %s%%).',
                  16, 1, @Table, @Shape, @cnt, @fragTxt, @densTxt);
    ELSE
        RAISERROR('  built %-18s %-9s  fragmentation %6s%%   density %6s%%', 0, 1,
                  @Table, @Shape, @fragTxt, @densTxt) WITH NOWAIT;
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_Snapshot -- measures one table and records a row in
  Demo.IndexSnapshots.

  Fragmentation and density come from sys.dm_db_index_physical_stats in
  DETAILED mode. Not LIMITED, the default: LIMITED reads only the level above
  the leaf, so it returns NULL for avg_page_space_used_in_percent -- the
  column this whole topic is about -- and nothing errors to tell you.

  Logical reads are a delta of sys.dm_exec_requests.logical_reads for this
  session, taken around a full scan. The scan runs TWICE and only the second
  is counted: the first pays for compilation and for pulling the pages into
  memory, the second is the steady-state cost a workload pays on every scan.

  OPTION (MAXDOP 1) is a query hint, not a setting: it keeps parallel scan
  scheduling out of the read count without touching instance configuration.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Snapshot
    @Label        varchar(60),
    @Table        sysname,
    @LogicalReads bigint = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @tbl nvarchar(300) = QUOTENAME(PARSENAME(@Table, 2)) + N'.' + QUOTENAME(PARSENAME(@Table, 1));
    DECLARE @scan nvarchar(400) =
        N'DECLARE @c bigint; SELECT @c = COUNT_BIG(*) FROM ' + @tbl + N' OPTION (MAXDOP 1);';
    DECLARE @r0 bigint;

    EXEC sys.sp_executesql @scan;                                  -- warm-up

    SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    EXEC sys.sp_executesql @scan;                                  -- measured
    SELECT @LogicalReads = logical_reads - @r0 FROM sys.dm_exec_requests WHERE session_id = @@SPID;

    DECLARE @bufferPages bigint =
    (
        SELECT COUNT_BIG(*)
        FROM   sys.dm_os_buffer_descriptors AS bd
        JOIN   sys.allocation_units         AS au ON au.allocation_unit_id = bd.allocation_unit_id
        JOIN   sys.partitions               AS p  ON p.hobt_id = au.container_id
        WHERE  bd.database_id = DB_ID()
          AND  p.object_id    = OBJECT_ID(@Table)
    );

    INSERT Demo.IndexSnapshots
           (Label, TableName, RowCnt, LeafPages, FragPct, DensityPct, Fragments, LogicalReads, BufferPoolMB)
    SELECT  @Label, @Table, ps.record_count, ps.page_count,
            ps.avg_fragmentation_in_percent, ps.avg_page_space_used_in_percent,
            ps.fragment_count, @LogicalReads, @bufferPages * 8 / 1024.0
    FROM    sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(@Table), 1, NULL, 'DETAILED') AS ps
    WHERE   ps.index_level = 0;
END
GO


/*------------------------------------------------------------------------------
  Demo.fn_RuleSays -- the maintenance rule this topic is testing, verbatim:
  ignore indexes under 1,000 pages; below 5% fragmentation leave it alone;
  5-30% REORGANIZE; above 30% REBUILD.

  Note what it takes as input. Fragmentation and page count. Not density.
------------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION Demo.fn_RuleSays (@FragPct decimal(6,2), @LeafPages bigint)
RETURNS varchar(20)
AS
BEGIN
    RETURN CASE WHEN @LeafPages < 1000 THEN 'leave (too small)'
                WHEN @FragPct   <  5   THEN 'leave alone'
                WHEN @FragPct   < 30   THEN 'REORGANIZE'
                ELSE                        'REBUILD' END;
END
GO


PRINT '=== STEP 3: the control, and the two pure shapes ===';
GO

EXEC Demo.usp_BuildTable 'dense',  'Demo.Dense',  'FG_Dense';
GO
EXEC Demo.usp_BuildTable 'sparse', 'Demo.Sparse', 'FG_Sparse';
GO


PRINT '=== STEP 4: logical fragmentation with full pages (the shrink) ===';
GO

EXEC Demo.usp_BuildTable 'scattered', 'Demo.Scattered', 'FG_Scattered';
GO


PRINT '=== STEP 5: a random GUID clustering key ===';
GO

EXEC Demo.usp_BuildTable 'random', 'Demo.Random', 'FG_Random';
GO

SELECT  TableName   = OBJECT_SCHEMA_NAME(ps.object_id) + '.' + OBJECT_NAME(ps.object_id),
        FragPct     = CAST(ps.avg_fragmentation_in_percent   AS decimal(6,2)),
        DensityPct  = CAST(ps.avg_page_space_used_in_percent AS decimal(6,2)),
        LeafPages   = ps.page_count,
        Rows        = ps.record_count
FROM    sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'DETAILED') AS ps
WHERE   ps.index_level = 0
  AND   ps.object_id IN (OBJECT_ID('Demo.Dense'), OBJECT_ID('Demo.Scattered'),
                         OBJECT_ID('Demo.Sparse'), OBJECT_ID('Demo.Random'))
ORDER BY TableName;
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the FragmentationDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
