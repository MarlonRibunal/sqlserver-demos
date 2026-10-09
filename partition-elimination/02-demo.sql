/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  Every query reads one month of a table partitioned by month -- or tries to.
  Demo.usp_Touch counts the partitions each one actually opened. Evidence
  lands in Demo.Touches and Demo.Verdicts; the summary is the payoff.

  Scenarios
    A  the control            -> a date range: one month, one partition
    B  a function on the key  -> YEAR() and MONTH(): every partition
    C  the parameter's type   -> date and varchar eliminate; datetime2 and
                                 datetimeoffset open every partition
    D  MIN / MAX              -> on an aligned index, every partition is
                                 read; a non-aligned index fixes it...
    E  ... and breaks SWITCH  -> a non-aligned index blocks partition
                                 switching

  Scenario E switches inside a transaction and rolls it back, so no data
  moves. The non-aligned index is created and dropped by this file.

  Expected runtime: about half a minute.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers.
==============================================================================*/

USE PartitionDemo;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('Demo.usp_Touch') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

TRUNCATE TABLE Demo.Touches;
DROP INDEX IF EXISTS IX_Sales_SaleID_NonAligned ON Demo.Sales;
DROP INDEX IF EXISTS IX_SwitchTest_SaleID_NonAligned ON Demo.SwitchTest;
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
  SCENARIO A -- the control

  March 2025, as a half-open range on the partitioning column. The optimizer
  knows from the literals which partition holds March, and opens only that
  one. The same range passed as date parameters is eliminated at run time
  instead ("dynamic" elimination); on the tested build it opened March and
  the next partition, and read the same.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO A: the control ---';
GO

EXEC Demo.usp_Touch 'A. Control', 'literal range, March 2025',
     N'DECLARE @c bigint; SELECT @c = SUM(Amount) FROM Demo.Sales WITH (INDEX(1))
       WHERE SaleDate >= ''20250301'' AND SaleDate < ''20250401'';',
     'one partition', 1;

EXEC Demo.usp_Touch 'A. Control', 'date parameters, March 2025',
     N'EXEC sys.sp_executesql N''DECLARE @c bigint; SELECT @c = SUM(Amount) FROM Demo.Sales WITH (INDEX(1))
       WHERE SaleDate >= @f AND SaleDate < @t;'', N''@f date, @t date'', @f = ''20250301'', @t = ''20250401'';',
     'one or two partitions', 2;
GO


/*==============================================================================
  SCENARIO B -- a function on the partitioning column

  WHERE YEAR(SaleDate) = 2025 AND MONTH(SaleDate) = 3 asks the same question.
  But partition elimination works on the partitioning column's VALUES, and a
  function of the column has none -- so every partition is opened and every
  row is tested. The same rule as an index seek (see the
  non-sargable-predicates topic), at partition scale.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO B: a function on the key ---';
GO

EXEC Demo.usp_Touch 'B. Function on the key', 'YEAR(SaleDate) = 2025 AND MONTH(SaleDate) = 3',
     N'DECLARE @c bigint; SELECT @c = SUM(Amount) FROM Demo.Sales WITH (INDEX(1))
       WHERE YEAR(SaleDate) = 2025 AND MONTH(SaleDate) = 3;',
     'every partition', 25;
GO


/*==============================================================================
  SCENARIO C -- the parameter's type

  The same March range, passed as parameters of four types:

     date            matches the column                  eliminated
     varchar(20)     converted to date, once             eliminated
     datetime2(7)    outranks date: the COLUMN would     every partition
                     have to be converted                opened
     datetimeoffset  likewise                            every partition
                                                         opened

  With the higher-precedence types the optimizer still seeks -- it reads
  little more than the control -- but it cannot rule partitions out, so it
  opens all 25 to look. An ORM that sends every date as datetime2 does
  this to every query on a date-partitioned table.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO C: the parameter''s type ---';
GO

EXEC Demo.usp_Touch 'C. Parameter type', '@f, @t as varchar(20)',
     N'EXEC sys.sp_executesql N''DECLARE @c bigint; SELECT @c = SUM(Amount) FROM Demo.Sales WITH (INDEX(1))
       WHERE SaleDate >= @f AND SaleDate < @t;'', N''@f varchar(20), @t varchar(20)'', @f = ''20250301'', @t = ''20250401'';',
     'eliminated, like date', 2;

EXEC Demo.usp_Touch 'C. Parameter type', '@f, @t as datetime2(7)',
     N'EXEC sys.sp_executesql N''DECLARE @c bigint; SELECT @c = SUM(Amount) FROM Demo.Sales WITH (INDEX(1))
       WHERE SaleDate >= @f AND SaleDate < @t;'', N''@f datetime2(7), @t datetime2(7)'', @f = ''20250301'', @t = ''20250401'';',
     'every partition opened', 25;

EXEC Demo.usp_Touch 'C. Parameter type', '@f, @t as datetimeoffset',
     N'EXEC sys.sp_executesql N''DECLARE @c bigint; SELECT @c = SUM(Amount) FROM Demo.Sales WITH (INDEX(1))
       WHERE SaleDate >= @f AND SaleDate < @t;'', N''@f datetimeoffset, @t datetimeoffset'', @f = ''20250301'', @t = ''20250401'';',
     'every partition opened', 25;
GO


/*==============================================================================
  SCENARIO D -- MIN / MAX on a partitioned index

  MAX(SaleID) on a non-partitioned index on SaleID is one seek to the end of
  the index. On an ALIGNED index there is no single end: each partition has
  its own slice, ordered on its own. So the engine has to look in every
  partition -- and on the tested build it read far more than one seek per
  partition would cost: 3,918 pages, against 3 for the non-aligned index.

  MAX(SaleDate) -- the partitioning column itself -- is fine: the last
  non-empty partition holds it.

  A non-aligned index (one not built on the partition scheme) gives MAX back
  its single seek. Scenario E is the bill for that.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO D: MIN / MAX ---';
GO

EXEC Demo.usp_Touch 'D. MIN / MAX', 'MAX(SaleID), aligned index',
     N'DECLARE @c int; SELECT @c = MAX(SaleID) FROM Demo.Sales WITH (INDEX(IX_Sales_SaleID));',
     'every partition', 25;

EXEC Demo.usp_Touch 'D. MIN / MAX', 'MAX(SaleDate), the partitioning column',
     N'DECLARE @c date; SELECT @c = MAX(SaleDate) FROM Demo.Sales WITH (INDEX(1));',
     'one partition', 1;
GO

CREATE INDEX IX_Sales_SaleID_NonAligned ON Demo.Sales (SaleID) ON [PRIMARY];
GO

EXEC Demo.usp_Touch 'D. MIN / MAX', 'MAX(SaleID), NON-aligned index',
     N'DECLARE @c int; SELECT @c = MAX(SaleID) FROM Demo.Sales WITH (INDEX(IX_Sales_SaleID_NonAligned));',
     'one seek', 1;
GO


/*==============================================================================
  SCENARIO E -- the non-aligned index breaks SWITCH

  The reason to partition a table is usually partition SWITCHING: moving a
  whole month in or out as a metadata operation, instantly. That needs every
  index on the table to be aligned.

  Tested on Demo.SwitchTest, a small copy partitioned the same way (see
  01-setup.sql for why not on Demo.Sales itself):

  E1  with a non-aligned index in place, switch January 2024 out to
      Demo.SalesStage: refused.
  E2  drop the non-aligned index and try again: it works, instantly. Done
      inside a transaction that is then rolled back, so no data moves.
==============================================================================*/
PRINT '';
PRINT '--- SCENARIO E: SWITCH ---';
GO

DROP INDEX IX_Sales_SaleID_NonAligned ON Demo.Sales;      -- scenario D's; done with it
CREATE INDEX IX_SwitchTest_SaleID_NonAligned ON Demo.SwitchTest (SaleID) ON [PRIMARY];
GO

DECLARE @err nvarchar(300);
BEGIN TRY
    BEGIN TRANSACTION;
        ALTER TABLE Demo.SwitchTest SWITCH PARTITION 2 TO Demo.SalesStage;
    ROLLBACK;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SET @err = N'Msg ' + CAST(ERROR_NUMBER() AS nvarchar(10)) + N': ' + LEFT(ERROR_MESSAGE(), 250);
END CATCH

INSERT Demo.Verdicts VALUES ('E. SWITCH', 'E1: SWITCH with a non-aligned index present',
    ISNULL(@err, N'the switch succeeded'), 'refused',
    CASE WHEN @err IS NOT NULL THEN 'SWITCH BLOCKED' ELSE 'unexpected' END);
GO

DROP INDEX IX_SwitchTest_SaleID_NonAligned ON Demo.SwitchTest;
GO

DECLARE @err nvarchar(300), @moved bigint, @ms int, @t0 datetime2(7) = SYSDATETIME();
BEGIN TRY
    BEGIN TRANSACTION;
        ALTER TABLE Demo.SwitchTest SWITCH PARTITION 2 TO Demo.SalesStage;
        SET @ms = DATEDIFF(millisecond, @t0, SYSDATETIME());
        SET @moved = (SELECT COUNT_BIG(*) FROM Demo.SalesStage);
    ROLLBACK;     -- put January back
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SET @err = N'Msg ' + CAST(ERROR_NUMBER() AS nvarchar(10)) + N': ' + LEFT(ERROR_MESSAGE(), 250);
END CATCH

DECLARE @d nvarchar(300) = ISNULL(@err, CAST(@moved AS nvarchar(20)) + N' rows switched out in ' + CAST(@ms AS nvarchar(10))
    + N' ms, then rolled back; January now holds '
    + CAST((SELECT rows FROM sys.partitions WHERE object_id = OBJECT_ID('Demo.SwitchTest') AND index_id = 1 AND partition_number = 2) AS nvarchar(20)) + N' rows');
INSERT Demo.Verdicts VALUES ('E. SWITCH', 'E2: SWITCH with only aligned indexes', @d, 'instant; rolled back',
    CASE WHEN @err IS NULL AND @moved > 0 THEN 'SWITCH WORKS' ELSE 'unexpected' END);
GO


/*==============================================================================
  VERDICTS for A to D
==============================================================================*/
DECLARE @ctrl bigint = (SELECT LogicalReads FROM Demo.Touches WHERE Item = 'literal range, March 2025');

INSERT Demo.Verdicts (Scenario, Item, Detail, Expected, Verdict)
SELECT  t.Scenario, t.Item,
        CAST(t.PartitionsRead AS nvarchar(10)) + N' of 25 partitions; ' + CAST(t.LogicalReads AS nvarchar(20))
            + N' reads (control ' + CAST(@ctrl AS nvarchar(20)) + N')',
        t.Expected,
        CASE WHEN t.ExpectedParts = 25 AND t.PartitionsRead = 25                THEN 'EVERY PARTITION'
             WHEN t.ExpectedParts IN (1, 2) AND t.PartitionsRead <= t.ExpectedParts THEN 'ELIMINATED'
             ELSE 'unexpected' END
FROM    Demo.Touches AS t;
GO


/*==============================================================================
  THE SUMMARY
==============================================================================*/
PRINT '';
PRINT '=== 1. PARTITIONS OPENED AND READS, PER QUERY ===';
GO
SELECT Scenario, Item, PartitionsRead, LogicalReads, Expected FROM Demo.Touches ORDER BY TouchID;
GO

PRINT '';
PRINT '=== 2. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario, Item;
GO

PRINT '';
PRINT '=== 3. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Detail, Verdict FROM Demo.Verdicts WHERE Verdict = 'unexpected';
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 3 should be EMPTY. Anything in it is a';
PRINT ' genuine difference on your build, worth reading before';
PRINT ' you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
