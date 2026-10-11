/*==============================================================================
  02-demo.sql           RUN THE WHOLE FILE (F5). Do not step through it.
  ----------------------------------------------------------------------------
  Requires 01-setup.sql to have completed.

  OFFSET ... FETCH against keyset ("seek") paging: what each page costs, and
  whether a reader walking the pages sees every row exactly once. Every page
  is recorded in Demo.Pages with its logical reads and the IDs it returned;
  the summary at the bottom is the payoff.

  Scenarios
    A  page 1, 10, 100, 1,000, 10,000          -> OFFSET's cost grows with
                                                  the page number; keyset's
                                                  doesn't
    B  OFFSET over the keys, then the rows     -> no lookups for skipped
       ("deferred join")                          rows; still grows
    C  a row is added, then one removed,        -> OFFSET repeats a row, then
       between page 1 and page 2                   skips one; keyset neither
    D  ORDER BY a column with ties              -> rows shown twice and rows
                                                  never shown; a tiebreaker
                                                  fixes it
    E  COUNT(*) OVER () for "page 1 of N"      -> the count costs more than
                                                  the page

  This file inserts and deletes a few rows of Demo.Orders in C and puts
  them back.

  Expected runtime: about 30 seconds.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE PagingDemo;
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('Demo.usp_Page_Keyset') IS NULL
BEGIN
    RAISERROR('Run 01-setup.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- Undo anything an interrupted earlier run left behind in scenario C: rows
-- it added, and rows it removed (rebuilt from setup's formula).
DELETE Demo.Orders WHERE OrderID > 1000000;
;WITH n AS (SELECT rn = 999900 + v.n FROM (SELECT TOP (100) n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns) AS v (n))
INSERT Demo.Orders (OrderID, OrderDate, CustomerID, Amount)
SELECT rn, DATEADD(second, -((1000000 - rn) / 2) * 61, '2026-01-01'), rn % 50000 + 1, (rn % 10000) / 100.0
FROM   n
WHERE  NOT EXISTS (SELECT 1 FROM Demo.Orders AS o WHERE o.OrderID = n.rn);
DELETE Demo.Pages;
GO

IF OBJECT_ID('Demo.Verdicts') IS NOT NULL DROP TABLE Demo.Verdicts;
CREATE TABLE Demo.Verdicts
(
    Scenario  char(1)       NOT NULL,
    Item      varchar(70)   NOT NULL,
    Detail    varchar(300)  NOT NULL,
    Expected  varchar(100)  NOT NULL,
    Verdict   varchar(30)   NOT NULL
);
GO


/*==============================================================================
  A -- the same five pages, two ways. OFFSET reads and throws away every row
  before the page it returns. Keyset starts where the previous page ended;
  for the deep pages its starting point -- "the last row of the page
  before" -- is looked up first, outside the measurement, the way an
  application would have it from the page it just showed.
==============================================================================*/
PRINT '=== A: OFFSET vs keyset, by page number ===';
DECLARE @pages TABLE (PageNo int);
INSERT @pages VALUES (1), (10), (100), (1000), (10000);
DECLARE @p int, @skip int, @d datetime2(0), @id int;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT PageNo FROM @pages ORDER BY PageNo;
OPEN c;
FETCH NEXT FROM c INTO @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC Demo.usp_Page_Offset 'A', @p;
    IF @p = 1
        EXEC Demo.usp_Page_Keyset 'A', 1;
    ELSE
    BEGIN
        SET @skip = (@p - 1) * 50 - 1;
        SELECT @d = OrderDate, @id = OrderID FROM Demo.Orders
        ORDER BY OrderDate DESC, OrderID DESC OFFSET @skip ROWS FETCH NEXT 1 ROWS ONLY;
        EXEC Demo.usp_Page_Keyset 'A', @p, @d, @id;
    END
    FETCH NEXT FROM c INTO @p;
END
CLOSE c; DEALLOCATE c;
GO

/*==============================================================================
  B -- the "deferred join": OFFSET over IX_Orders_Date alone, which holds
  the keys it orders by, then the full rows for just the 50 that survive.
  Skipped rows no longer cost a lookup each.
==============================================================================*/
PRINT '=== B: deferred join ===';
EXEC Demo.usp_Page_Deferred 'B', 1;
EXEC Demo.usp_Page_Deferred 'B', 1000;
EXEC Demo.usp_Page_Deferred 'B', 10000;
GO

/*==============================================================================
  C -- a reader on page 1 while the table changes under them. Five new
  orders arrive (newest, so at the top), then the reader asks for page 2.
  Then the same with five orders from page 1 removed.
==============================================================================*/
PRINT '=== C: rows added or removed between pages ===';
DECLARE @d datetime2(0), @id int, @last varchar(40);

-- C1: added, OFFSET
EXEC Demo.usp_Page_Offset 'C1', 1;
INSERT Demo.Orders (OrderID, OrderDate, CustomerID, Amount)
SELECT 1000000 + n, DATEADD(second, n, '2026-01-01'), 1, 1 FROM (VALUES (1), (2), (3), (4), (5)) AS v (n);
EXEC Demo.usp_Page_Offset 'C1', 2;
DELETE Demo.Orders WHERE OrderID > 1000000;

-- C1: added, keyset
EXEC Demo.usp_Page_Keyset 'C1', 1;
SELECT @last = LastKey FROM Demo.Pages WHERE Run = 'C1' AND Method = 'KEYSET' AND PageNo = 1;
SELECT @d = CAST(LEFT(@last, 19) AS datetime2(0)), @id = CAST(SUBSTRING(@last, 21, 10) AS int);
INSERT Demo.Orders (OrderID, OrderDate, CustomerID, Amount)
SELECT 1000000 + n, DATEADD(second, n, '2026-01-01'), 1, 1 FROM (VALUES (1), (2), (3), (4), (5)) AS v (n);
EXEC Demo.usp_Page_Keyset 'C1', 2, @d, @id;
DELETE Demo.Orders WHERE OrderID > 1000000;

-- C2: removed. The five newest orders (all on page 1) go away after page 1
-- is shown; they come back afterwards.
IF OBJECT_ID('tempdb..#gone') IS NOT NULL DROP TABLE #gone;
SELECT * INTO #gone FROM Demo.Orders WHERE OrderID > 999995;

EXEC Demo.usp_Page_Offset 'C2', 1;
DELETE Demo.Orders WHERE OrderID > 999995;
EXEC Demo.usp_Page_Offset 'C2', 2;
INSERT Demo.Orders SELECT * FROM #gone;

EXEC Demo.usp_Page_Keyset 'C2', 1;
SELECT @last = LastKey FROM Demo.Pages WHERE Run = 'C2' AND Method = 'KEYSET' AND PageNo = 1;
SELECT @d = CAST(LEFT(@last, 19) AS datetime2(0)), @id = CAST(SUBSTRING(@last, 21, 10) AS int);
DELETE Demo.Orders WHERE OrderID > 999995;
EXEC Demo.usp_Page_Keyset 'C2', 2, @d, @id;
INSERT Demo.Orders SELECT * FROM #gone;
GO

/*==============================================================================
  D -- every page of Demo.Tickets, 20 at a time, ORDER BY Priority: three
  values for 20,000 rows, so the order WITHIN a priority is whatever the
  plan happens to produce. A shallow page reads IX_Tickets_Priority
  (ties in CreatedAt order); a deep one scans and sorts (ties in whatever
  order the sort leaves them). Then the same walk with ORDER BY Priority,
  TicketID.
==============================================================================*/
PRINT '=== D: ties in the ORDER BY ===';
DECLARE @p int = 1;
WHILE @p <= 1000
BEGIN
    EXEC Demo.usp_Ticket_Offset 'D', @p, 20, 0;
    EXEC Demo.usp_Ticket_Offset 'D', @p, 20, 1;
    SET @p += 1;
END
GO

/*==============================================================================
  E -- "page 1 of 20,000". COUNT(*) OVER () gives every row of the page the
  total, which means counting all of them, every time a page is shown.
==============================================================================*/
PRINT '=== E: the total row count ===';
EXEC Demo.usp_Page_Counted 'E', 1;
GO


/*==============================================================================
  Verdicts
==============================================================================*/
DECLARE @d varchar(300);
DECLARE @o1 bigint, @o10 bigint, @o100 bigint, @o1000 bigint, @o10000 bigint, @k1 bigint, @k10000 bigint, @kMax bigint;
SELECT @o1 = MAX(CASE WHEN PageNo = 1 THEN Reads END), @o10 = MAX(CASE WHEN PageNo = 10 THEN Reads END),
       @o100 = MAX(CASE WHEN PageNo = 100 THEN Reads END), @o1000 = MAX(CASE WHEN PageNo = 1000 THEN Reads END),
       @o10000 = MAX(CASE WHEN PageNo = 10000 THEN Reads END)
FROM   Demo.Pages WHERE Run = 'A' AND Method = 'OFFSET';
SELECT @k1 = MAX(CASE WHEN PageNo = 1 THEN Reads END), @k10000 = MAX(CASE WHEN PageNo = 10000 THEN Reads END), @kMax = MAX(Reads)
FROM   Demo.Pages WHERE Run = 'A' AND Method = 'KEYSET';

-- Both methods must return the same rows for the same page.
DECLARE @same int = (SELECT COUNT(*) FROM Demo.Pages AS o JOIN Demo.Pages AS k
                     ON k.Run = 'A' AND k.Method = 'KEYSET' AND k.PageNo = o.PageNo AND k.Ids = o.Ids
                     WHERE o.Run = 'A' AND o.Method = 'OFFSET');
SET @d = CONCAT(@same, ' of 5 pages identical');
INSERT Demo.Verdicts VALUES ('A', 'OFFSET and keyset return the same pages', @d, '5 of 5',
    CASE WHEN @same = 5 THEN 'SAME ROWS' ELSE 'unexpected' END);

SET @d = CONCAT('reads, pages 1/10/100/1,000/10,000: ', @o1, ' / ', @o10, ' / ', @o100, ' / ', @o1000, ' / ', @o10000);
INSERT Demo.Verdicts VALUES ('A', 'OFFSET: cost grows with the page number', @d, 'page 1,000 > 100x page 1',
    CASE WHEN @o1000 > 100 * @o1 AND @o100 > 10 * @o1 THEN 'GROWS' ELSE 'unexpected' END);
SET @d = CONCAT('reads, page 1: ', @k1, '; page 10,000: ', @k10000, '; most for any page: ', @kMax);
INSERT Demo.Verdicts VALUES ('A', 'keyset: every page costs the same', @d, 'every page within 2x of page 1',
    CASE WHEN @kMax <= 2 * @k1 THEN 'FLAT' ELSE 'unexpected' END);

-- B
DECLARE @b1000 bigint, @b10000 bigint;
SELECT @b1000 = MAX(CASE WHEN PageNo = 1000 THEN Reads END), @b10000 = MAX(CASE WHEN PageNo = 10000 THEN Reads END)
FROM   Demo.Pages WHERE Run = 'B';
SET @d = CONCAT('reads, page 1,000: ', @b1000, ' (OFFSET ', @o1000, '); page 10,000: ', @b10000, ' (OFFSET ', @o10000,
                ', keyset ', @k10000, ')');
INSERT Demo.Verdicts VALUES ('B', 'deferred join: no lookups for skipped rows', @d, 'far below OFFSET; still above keyset when deep',
    CASE WHEN @b1000 * 10 < @o1000 AND @b10000 < @o10000 AND @b10000 > @k10000 THEN 'CHEAPER' ELSE 'unexpected' END);

-- C. Overlap between page 1 and page 2, and rows that were in the first 100
-- throughout but appeared on neither.
IF OBJECT_ID('tempdb..#ids') IS NOT NULL DROP TABLE #ids;
SELECT p.Run, p.Method, p.PageNo, Id = CAST(s.value AS int)
INTO   #ids
FROM   Demo.Pages AS p CROSS APPLY STRING_SPLIT(p.Ids, ',') AS s
WHERE  p.Run IN ('C1', 'C2');

DECLARE @c1o int, @c1k int, @c2o int, @c2k int;
SELECT @c1o = COUNT(*) FROM #ids AS a JOIN #ids AS b ON b.Id = a.Id AND b.Run = a.Run AND b.Method = a.Method AND b.PageNo = 2
WHERE  a.Run = 'C1' AND a.Method = 'OFFSET' AND a.PageNo = 1;
SELECT @c1k = COUNT(*) FROM #ids AS a JOIN #ids AS b ON b.Id = a.Id AND b.Run = a.Run AND b.Method = a.Method AND b.PageNo = 2
WHERE  a.Run = 'C1' AND a.Method = 'KEYSET' AND a.PageNo = 1;
-- The original first 100 orders are 999901-1000000; 999996-1000000 were removed.
SELECT @c2o = COUNT(*) FROM (SELECT TOP (95) Id = 999995 - v.n + 1 FROM (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns) AS v (n)) AS w
WHERE  NOT EXISTS (SELECT 1 FROM #ids AS i WHERE i.Run = 'C2' AND i.Method = 'OFFSET' AND i.Id = w.Id);
SELECT @c2k = COUNT(*) FROM (SELECT TOP (95) Id = 999995 - v.n + 1 FROM (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns) AS v (n)) AS w
WHERE  NOT EXISTS (SELECT 1 FROM #ids AS i WHERE i.Run = 'C2' AND i.Method = 'KEYSET' AND i.Id = w.Id);

SET @d = CONCAT('5 rows added before page 2: OFFSET page 2 repeated ', @c1o, ' row(s) from page 1; keyset ', @c1k);
INSERT Demo.Verdicts VALUES ('C', 'rows added between pages', @d, 'OFFSET repeats 5; keyset 0',
    CASE WHEN @c1o = 5 AND @c1k = 0 THEN 'OFFSET REPEATS' ELSE 'unexpected' END);
SET @d = CONCAT('5 rows removed before page 2: rows never shown, OFFSET ', @c2o, '; keyset ', @c2k);
INSERT Demo.Verdicts VALUES ('C', 'rows removed between pages', @d, 'OFFSET skips 5; keyset 0',
    CASE WHEN @c2o = 5 AND @c2k = 0 THEN 'OFFSET SKIPS' ELSE 'unexpected' END);

-- D
DECLARE @tShown int, @tDistinct int, @tbShown int, @tbDistinct int;
SELECT @tShown = COUNT(*), @tDistinct = COUNT(DISTINCT s.value)
FROM   Demo.Pages AS p CROSS APPLY STRING_SPLIT(p.Ids, ',') AS s WHERE p.Run = 'D' AND p.Method = 'OFFSET';
SELECT @tbShown = COUNT(*), @tbDistinct = COUNT(DISTINCT s.value)
FROM   Demo.Pages AS p CROSS APPLY STRING_SPLIT(p.Ids, ',') AS s WHERE p.Run = 'D' AND p.Method = 'OFFSET+TIEBREAK';
SET @d = CONCAT('ORDER BY Priority: ', @tShown, ' rows shown, ', @tDistinct, ' distinct tickets of 20,000 -- ',
                @tShown - @tDistinct, ' shown twice, ', 20000 - @tDistinct, ' never shown');
INSERT Demo.Verdicts VALUES ('D', 'ties: pages overlap and leave gaps', @d, 'fewer than 20,000 distinct',
    CASE WHEN @tShown = 20000 AND @tDistinct < 20000 THEN 'ROWS LOST'
         WHEN @tShown = 20000 AND @tDistinct = 20000 THEN 'INCONCLUSIVE'   -- the plans happened to agree on tie order
         ELSE 'unexpected' END);
SET @d = CONCAT('ORDER BY Priority, TicketID: ', @tbShown, ' rows shown, ', @tbDistinct, ' distinct');
INSERT Demo.Verdicts VALUES ('D', 'a unique tiebreaker: every row once', @d, '20,000 of 20,000',
    CASE WHEN @tbShown = 20000 AND @tbDistinct = 20000 THEN 'EVERY ROW ONCE' ELSE 'unexpected' END);

-- E
DECLARE @e bigint, @eTotal bigint;
SELECT @e = Reads, @eTotal = TotalRows FROM Demo.Pages WHERE Run = 'E';
SET @d = CONCAT('page 1 with COUNT(*) OVER (): ', @e, ' reads (total ', @eTotal, '); without: ', @o1);
INSERT Demo.Verdicts VALUES ('E', 'the total costs more than the page', @d, 'more than 100x the page alone',
    CASE WHEN @e > 100 * @o1 AND @eTotal = 1000000 THEN 'COUNT DOMINATES' ELSE 'unexpected' END);
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. LOGICAL READS PER PAGE ===';
GO
SELECT PageNo,
       [OFFSET]   = MAX(CASE WHEN Run = 'A' AND Method = 'OFFSET' THEN Reads END),
       [DEFERRED] = MAX(CASE WHEN Run = 'B' THEN Reads END),
       [KEYSET]   = MAX(CASE WHEN Run = 'A' AND Method = 'KEYSET' THEN Reads END),
       [OFFSET + COUNT(*) OVER ()] = MAX(CASE WHEN Run = 'E' THEN Reads END)
FROM   Demo.Pages
WHERE  Run IN ('A', 'B', 'E')
GROUP BY PageNo
ORDER BY PageNo;
GO

PRINT '';
PRINT '=== 2. THE VERDICTS ===';
GO
SELECT Scenario, Item, Detail, Expected, Verdict FROM Demo.Verdicts ORDER BY Scenario;
GO

PRINT '';
PRINT '=== 3. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Item, Detail, Verdict FROM Demo.Verdicts WHERE Verdict IN ('unexpected', 'INCONCLUSIVE');
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
