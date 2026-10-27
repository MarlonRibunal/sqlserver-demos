/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Ordered columnstore indexes: what ORDER buys a range query, and when it
  stops buying it.

     A  unordered against ordered: segments read for one month
     B  an ordered index built in parallel
     C  new rows after the build, and REBUILD
     D  what 2025 added: ORDER on a nonclustered columnstore index, and an
        ordered index built ONLINE

  The measure throughout is how many columnstore segments the query read
  and how many it skipped, for one month out of four years.

  On SQL Server 2019 and earlier every scenario reports SKIPPED. On 2022,
  scenario D shows the errors that 2025 removed.

  WHAT THIS CHANGES: only OrderedCsDemo. Each scenario drops and rebuilds
  Demo.CS; scenario D rebuilds Demo.RS.

  TESTED end to end on SQL Server 2025 RTM-CU10 (17.0.5035.5) and SQL
  Server 2022 RTM-CU25 (16.0.4255.1), Linux containers.
==============================================================================*/

USE OrderedCsDemo;
GO
SET NOCOUNT ON;
GO

TRUNCATE TABLE Demo.Results;
TRUNCATE TABLE Demo.Verdicts;
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) < 16
    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'ordered columnstore: segment elimination', 'needs SQL Server 2022 or later', 'SKIPPED'),
    ('B', 'ordered columnstore: parallel build',      'needs SQL Server 2022 or later', 'SKIPPED'),
    ('C', 'ordered columnstore: new rows',            'needs SQL Server 2022 or later', 'SKIPPED'),
    ('D', 'ordered columnstore: 2025 additions',      'needs SQL Server 2022 or later', 'SKIPPED');
GO


/*==============================================================================
  A. The same 4,000,000 rows, an unordered and an ordered clustered
     columnstore index. MAXDOP 1 for the ordered build: see B.
==============================================================================*/
PRINT '=== A. unordered against ordered ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16
BEGIN
    DECLARE @e int, @rg int, @r bigint, @s bigint;

    EXEC Demo.usp_BuildCS N'CREATE CLUSTERED COLUMNSTORE INDEX CCI_CS ON Demo.CS;', @e OUTPUT, @rg OUTPUT;
    EXEC Demo.usp_Segments N'Demo.q_CS', @r OUTPUT, @s OUTPUT;
    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('A', 'unordered: rowgroups',                     CAST(@rg AS varchar(10))),
    ('A', 'unordered: segments read / skipped',       CAST(@r AS varchar(10)) + ' / ' + CAST(@s AS varchar(10)));

    EXEC Demo.usp_BuildCS N'CREATE CLUSTERED COLUMNSTORE INDEX CCI_CS ON Demo.CS ORDER (OrderDate) WITH (MAXDOP = 1);', @e OUTPUT, @rg OUTPUT;
    EXEC Demo.usp_Segments N'Demo.q_CS', @r OUTPUT, @s OUTPUT;
    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('A', 'ORDER (OrderDate), MAXDOP 1: rowgroups',   CAST(@rg AS varchar(10))),
    ('A', 'ORDER (OrderDate), MAXDOP 1: segments read / skipped', CAST(@r AS varchar(10)) + ' / ' + CAST(@s AS varchar(10)));

    DECLARE @uR bigint = (SELECT CAST(LEFT(Value, CHARINDEX(' ', Value) - 1) AS bigint) FROM Demo.Results WHERE Item = 'unordered: segments read / skipped'),
            @uS bigint = (SELECT CAST(SUBSTRING(Value, CHARINDEX('/', Value) + 2, 10) AS bigint) FROM Demo.Results WHERE Item = 'unordered: segments read / skipped');

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('A', 'unordered: the month is in every rowgroup, so every segment is read',
     CAST(@uR AS varchar(10)) + ' read, ' + CAST(@uS AS varchar(10)) + ' skipped',
     CASE WHEN @uS = 0 AND @uR > 1 THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('A', 'ordered: the month sits in one rowgroup; the rest are skipped',
     CAST(@r AS varchar(10)) + ' read, ' + CAST(@s AS varchar(10)) + ' skipped',
     CASE WHEN @e = 0 AND @r = 1 AND @s >= 3 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  B. The same ordered index, built with MAXDOP 4. Each thread sorts its own
     share of the rows, so the rowgroups' date ranges overlap.
==============================================================================*/
PRINT '=== B. a parallel ordered build ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16
BEGIN
    DECLARE @e int, @rg int, @r bigint, @s bigint, @cpu int = (SELECT cpu_count FROM sys.dm_os_sys_info);

    EXEC Demo.usp_BuildCS N'CREATE CLUSTERED COLUMNSTORE INDEX CCI_CS ON Demo.CS ORDER (OrderDate) WITH (MAXDOP = 4);', @e OUTPUT, @rg OUTPUT;
    EXEC Demo.usp_Segments N'Demo.q_CS', @r OUTPUT, @s OUTPUT;
    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('B', 'CPUs available',                                  CAST(@cpu AS varchar(10))),
    ('B', 'ORDER (OrderDate), MAXDOP 4: rowgroups',          CAST(@rg AS varchar(10))),
    ('B', 'ORDER (OrderDate), MAXDOP 4: segments read / skipped', CAST(@r AS varchar(10)) + ' / ' + CAST(@s AS varchar(10)));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('B', 'built in parallel, the month spans several rowgroups: more segments read than at MAXDOP 1',
     CAST(@r AS varchar(10)) + ' read, ' + CAST(@s AS varchar(10)) + ' skipped, on ' + CAST(@cpu AS varchar(10)) + ' CPUs',
     CASE WHEN @cpu < 2 THEN 'INCONCLUSIVE'
          WHEN @e = 0 AND @r > 1 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  C. New rows after the build. 1,048,576 rows bulk loaded with TABLOCK
     become one compressed rowgroup straight away, holding every date.
==============================================================================*/
PRINT '=== C. new rows, and REBUILD ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16
BEGIN
    DECLARE @e int, @rg int, @r bigint, @s bigint, @r2 bigint, @s2 bigint, @r3 bigint, @s3 bigint;

    EXEC Demo.usp_BuildCS N'CREATE CLUSTERED COLUMNSTORE INDEX CCI_CS ON Demo.CS ORDER (OrderDate) WITH (MAXDOP = 1);', @e OUTPUT, @rg OUTPUT;
    EXEC Demo.usp_Segments N'Demo.q_CS', @r OUTPUT, @s OUTPUT;

    EXEC (N'INSERT Demo.CS WITH (TABLOCK) (ID, OrderDate, Amount) SELECT ID, OrderDate, Amount FROM Demo.Extra;');
    EXEC Demo.usp_Segments N'Demo.q_CS', @r2 OUTPUT, @s2 OUTPUT;
    DECLARE @rg2 int = (SELECT COUNT(*) FROM sys.column_store_row_groups
                        WHERE object_id = OBJECT_ID(N'Demo.CS') AND state_description = N'COMPRESSED');

    EXEC (N'ALTER INDEX CCI_CS ON Demo.CS REBUILD WITH (MAXDOP = 1);');
    EXEC Demo.usp_Segments N'Demo.q_CS', @r3 OUTPUT, @s3 OUTPUT;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('C', 'ordered, as built: segments read / skipped',          CAST(@r AS varchar(10))  + ' / ' + CAST(@s AS varchar(10))),
    ('C', 'ordered, as built: rowgroups',                        CAST(@rg AS varchar(10))),
    ('C', 'after 1,048,576 new rows: rowgroups',                 CAST(@rg2 AS varchar(10))),
    ('C', 'after 1,048,576 new rows: segments read / skipped',   CAST(@r2 AS varchar(10)) + ' / ' + CAST(@s2 AS varchar(10))),
    ('C', 'after ALTER INDEX ... REBUILD: segments read / skipped', CAST(@r3 AS varchar(10)) + ' / ' + CAST(@s3 AS varchar(10)));

    INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
    ('C', 'new rows are not merged into the order: the new rowgroup is read too',
     CAST(@r AS varchar(10)) + ' read before, ' + CAST(@r2 AS varchar(10)) + ' after',
     CASE WHEN @r2 > @r THEN 'CONFIRMED' ELSE 'unexpected' END),
    ('C', 'REBUILD sorts everything again, new rows included',
     CAST(@r3 AS varchar(10)) + ' read, ' + CAST(@s3 AS varchar(10)) + ' skipped',
     CASE WHEN @r3 = 1 AND @s3 > @s THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  D. What SQL Server 2025 added. ORDER on a NONCLUSTERED columnstore index
     (here on a rowstore table with a primary key), and an ordered index
     built with ONLINE = ON. On 2022 both fail.
==============================================================================*/
PRINT '=== D. what 2025 added ===';
GO
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16
BEGIN
    DECLARE @v int = CAST(SERVERPROPERTY('ProductMajorVersion') AS int);
    DECLARE @eN int, @eO int, @rg int, @r bigint, @s bigint, @rO bigint, @sO bigint;

    EXEC (N'DROP TABLE IF EXISTS Demo.RS;');
    EXEC (N'CREATE TABLE Demo.RS (ID bigint NOT NULL CONSTRAINT PK_RS PRIMARY KEY, OrderDate date NOT NULL, Amount int NOT NULL);');
    EXEC (N'INSERT Demo.RS WITH (TABLOCK) (ID, OrderDate, Amount) SELECT ID, OrderDate, Amount FROM Demo.Source WHERE ID <= 2000000;');
    EXEC Demo.usp_Try N'CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_RS ON Demo.RS (OrderDate, Amount) ORDER (OrderDate) WITH (MAXDOP = 1);', @eN OUTPUT;
    IF @eN = 0
        EXEC Demo.usp_Segments N'Demo.q_RS', @r OUTPUT, @s OUTPUT;

    EXEC Demo.usp_BuildCS N'CREATE CLUSTERED COLUMNSTORE INDEX CCI_CS ON Demo.CS ORDER (OrderDate) WITH (ONLINE = ON, MAXDOP = 1);', @eO OUTPUT, @rg OUTPUT;
    IF @eO = 0
        EXEC Demo.usp_Segments N'Demo.q_CS', @rO OUTPUT, @sO OUTPUT;

    INSERT Demo.Results (Scenario, Item, Value) VALUES
    ('D', 'ordered NONCLUSTERED columnstore on Demo.RS (2,000,000 rows)',
     CASE @eN WHEN 0 THEN 'created; segments read / skipped ' + CAST(@r AS varchar(10)) + ' / ' + CAST(@s AS varchar(10))
              ELSE 'error ' + CAST(@eN AS varchar(10)) END),
    ('D', 'ordered clustered columnstore, ONLINE = ON',
     CASE @eO WHEN 0 THEN 'created; segments read / skipped ' + CAST(@rO AS varchar(10)) + ' / ' + CAST(@sO AS varchar(10))
              ELSE 'error ' + CAST(@eO AS varchar(10)) END);

    IF @v >= 17
        INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
        ('D', '2025: ORDER works on a nonclustered columnstore index, and segments are skipped',
         CASE @eN WHEN 0 THEN CAST(@r AS varchar(10)) + ' read, ' + CAST(@s AS varchar(10)) + ' skipped' ELSE 'error ' + CAST(@eN AS varchar(10)) END,
         CASE WHEN @eN = 0 AND @s > 0 THEN 'CONFIRMED' ELSE 'unexpected' END),
        ('D', '2025: an ordered index can be built ONLINE, and is still ordered',
         CASE @eO WHEN 0 THEN CAST(@rO AS varchar(10)) + ' read, ' + CAST(@sO AS varchar(10)) + ' skipped' ELSE 'error ' + CAST(@eO AS varchar(10)) END,
         CASE WHEN @eO = 0 AND @rO = 1 THEN 'CONFIRMED' ELSE 'unexpected' END);
    ELSE
        INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
        ('D', '2022: ORDER on a nonclustered columnstore index fails (35342)',
         'error ' + CAST(@eN AS varchar(10)),
         CASE WHEN @eN = 35342 THEN 'CONFIRMED' ELSE 'unexpected' END),
        ('D', '2022: an ordered index can''t be built ONLINE (10679)',
         'error ' + CAST(@eO AS varchar(10)),
         CASE WHEN @eO = 10679 THEN 'CONFIRMED' ELSE 'unexpected' END);
END
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. EVERY MEASUREMENT ===';
GO
SELECT Scenario, Item, Value FROM Demo.Results ORDER BY Seq;
GO

PRINT '';
PRINT '=== 2. VERDICTS ===';
GO
SELECT Scenario, Claim, Evidence, Verdict FROM Demo.Verdicts ORDER BY Scenario, Seq;
GO

PRINT '';
PRINT '=== 3. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Claim, Evidence, Verdict FROM Demo.Verdicts
WHERE  Verdict IN ('unexpected', 'INCONCLUSIVE', 'SKIPPED') ORDER BY Scenario, Seq;
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 3 should be EMPTY on SQL Server 2022 and';
PRINT ' later. On 2019 and earlier it lists every scenario as';
PRINT ' SKIPPED. Anything else in it is a genuine difference';
PRINT ' on your build, worth reading before you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
