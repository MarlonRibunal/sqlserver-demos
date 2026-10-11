/*==============================================================================
  01-setup.sql          RUN ONCE. Takes under a minute.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, PagingDemo, and puts everything inside it.
     Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched

  Creates, all inside PagingDemo:
     Demo.Orders              - 1,000,000 orders, paged newest first
     Demo.Tickets             - 20,000 tickets, paged by Priority (3 values)
     Demo.Pages               - every page fetched: method, page, reads,
                                and the IDs it returned
     Demo.usp_Page_Offset     - OFFSET ... FETCH
     Demo.usp_Page_Deferred   - OFFSET over the index keys, then the rows
     Demo.usp_Page_Keyset     - "the 50 after the last one I showed you"
     Demo.usp_Page_Counted    - OFFSET plus COUNT(*) OVER () for page totals
     Demo.usp_Ticket_Offset   - OFFSET over Tickets, ordered by Priority only

  COST: about 300 MB of data plus transaction log, all inside PagingDemo.

  REQUIRES SQL Server 2017 or later (STRING_AGG).

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create PagingDemo ===';
GO

IF DB_ID('PagingDemo') IS NOT NULL
BEGIN
    RAISERROR('PagingDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE PagingDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE PagingDemo;
END
GO

CREATE DATABASE PagingDemo;
GO

ALTER DATABASE PagingDemo SET RECOVERY SIMPLE;
GO

USE PagingDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: Demo.Orders and Demo.Tickets ===';
GO

/*------------------------------------------------------------------------------
  Demo.Orders is paged newest first: ORDER BY OrderDate DESC, OrderID DESC.
  OrderID is in the ORDER BY so that the order is unique (scenario D is
  what happens when it isn't). IX_Orders_Date supports that order but does
  not include CustomerID, Amount or Note, so every row shown needs a key
  lookup into the clustered index.
------------------------------------------------------------------------------*/
CREATE TABLE Demo.Orders
(
    OrderID    int            NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    OrderDate  datetime2(0)   NOT NULL,
    CustomerID int            NOT NULL,
    Amount     decimal(12,2)  NOT NULL,
    Note       char(150)      NOT NULL CONSTRAINT DF_Orders_Note DEFAULT ('x')
);
GO

;WITH n AS
(
    SELECT TOP (1000000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b CROSS JOIN sys.all_columns AS c
)
INSERT Demo.Orders WITH (TABLOCK) (OrderID, OrderDate, CustomerID, Amount)
SELECT rn,
       -- two orders per timestamp, a minute apart, over about a year to
       -- 2026-01-01: OrderDate alone is not unique, OrderID breaks the tie
       DATEADD(second, -((1000000 - rn) / 2) * 61, '2026-01-01'),
       rn % 50000 + 1,
       (rn % 10000) / 100.0
FROM   n;
GO

CREATE INDEX IX_Orders_Date ON Demo.Orders (OrderDate DESC, OrderID DESC);
GO

/*------------------------------------------------------------------------------
  Demo.Tickets: 20,000 tickets with a Priority of 1, 2 or 3 -- a screen
  sorted by a column with only three values and nothing to break the ties.
  IX_Tickets_Priority is on (Priority, CreatedAt) and doesn't cover Title,
  so a shallow page reads the index in order and looks up 20 titles, while a
  deep page is cheaper as a scan and a sort. Within a priority, the index
  orders tickets by CreatedAt; the scan meets them in TicketID order, which
  runs the other way.
------------------------------------------------------------------------------*/
CREATE TABLE Demo.Tickets
(
    TicketID   int           NOT NULL CONSTRAINT PK_Tickets PRIMARY KEY CLUSTERED,
    Priority   tinyint       NOT NULL,
    CreatedAt  datetime2(0)  NOT NULL,
    Title      char(200)     NOT NULL
);

;WITH n AS
(
    SELECT TOP (20000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.Tickets (TicketID, Priority, CreatedAt, Title)
SELECT rn, rn % 3 + 1, DATEADD(minute, -rn, '2026-01-01'), 'Ticket ' + CAST(rn AS varchar(10))
FROM   n;

CREATE INDEX IX_Tickets_Priority ON Demo.Tickets (Priority, CreatedAt);
GO


PRINT '=== STEP 3: the paging procedures ===';
GO

CREATE TABLE Demo.Pages
(
    Run       varchar(40)    NOT NULL,     -- which walk this page belongs to
    Method    varchar(20)    NOT NULL,
    PageNo    int            NOT NULL,
    Reads     bigint         NOT NULL,     -- logical reads of the paging query alone
    RowsBack  int            NOT NULL,
    TotalRows bigint         NULL,         -- usp_Page_Counted only
    Ids       varchar(max)   NOT NULL,     -- the IDs returned, comma-separated, in page order
    LastKey   varchar(40)    NULL,         -- the last row's sort key: 'yyyy-mm-dd hh:mi:ss|OrderID'
    CapturedAt datetime2(3)  NOT NULL CONSTRAINT DF_Pages_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  How each procedure is measured. The paging query returns its rows into
  variables -- the IDs as one string, a checksum of the other columns so
  they really are fetched -- instead of to the client, and logical reads
  are this session's sys.dm_exec_requests.logical_reads just before and just
  after it. Nothing but the paging query sits between the two.

  OPTION (RECOMPILE) on every paging query: one cached plan for page 1 and
  page 10,000 alike would make the comparison about parameter sniffing (see
  the parameter-sniffing topic) instead of about paging.
------------------------------------------------------------------------------*/

-- OFFSET (@PageNo - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY.
CREATE OR ALTER PROCEDURE Demo.usp_Page_Offset
    @Run      varchar(40),
    @PageNo   int,
    @PageSize int = 50
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r0 bigint, @r1 bigint, @ids varchar(8000), @n int, @chk int, @last varchar(40),
            @skip int = (@PageNo - 1) * @PageSize;
    SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;

    SELECT @ids  = STRING_AGG(CAST(OrderID AS varchar(8000)), ',') WITHIN GROUP (ORDER BY OrderDate DESC, OrderID DESC),
           @n    = COUNT(*),
           @chk  = CHECKSUM_AGG(CHECKSUM(CustomerID, Amount, Note)),
           @last = MIN(CONVERT(char(19), OrderDate, 120) + '|' + RIGHT('000000000' + CAST(OrderID AS varchar(10)), 10))
    FROM  (SELECT OrderID, OrderDate, CustomerID, Amount, Note
           FROM   Demo.Orders
           ORDER BY OrderDate DESC, OrderID DESC
           OFFSET @skip ROWS FETCH NEXT @PageSize ROWS ONLY) AS p
    OPTION (RECOMPILE);

    SELECT @r1 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    INSERT Demo.Pages (Run, Method, PageNo, Reads, RowsBack, Ids, LastKey)
    VALUES (@Run, 'OFFSET', @PageNo, @r1 - @r0, @n, ISNULL(@ids, ''), @last);
END
GO

-- The same page, in two steps: OFFSET over IX_Orders_Date's keys only (no
-- lookups for the rows being skipped), then the full rows for just the 50.
CREATE OR ALTER PROCEDURE Demo.usp_Page_Deferred
    @Run      varchar(40),
    @PageNo   int,
    @PageSize int = 50
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r0 bigint, @r1 bigint, @ids varchar(8000), @n int, @chk int, @last varchar(40),
            @skip int = (@PageNo - 1) * @PageSize;
    SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;

    SELECT @ids  = STRING_AGG(CAST(o.OrderID AS varchar(8000)), ',') WITHIN GROUP (ORDER BY o.OrderDate DESC, o.OrderID DESC),
           @n    = COUNT(*),
           @chk  = CHECKSUM_AGG(CHECKSUM(o.CustomerID, o.Amount, o.Note)),
           @last = MIN(CONVERT(char(19), o.OrderDate, 120) + '|' + RIGHT('000000000' + CAST(o.OrderID AS varchar(10)), 10))
    FROM  (SELECT OrderID
           FROM   Demo.Orders
           ORDER BY OrderDate DESC, OrderID DESC
           OFFSET @skip ROWS FETCH NEXT @PageSize ROWS ONLY) AS k
    JOIN   Demo.Orders AS o ON o.OrderID = k.OrderID
    OPTION (RECOMPILE);

    SELECT @r1 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    INSERT Demo.Pages (Run, Method, PageNo, Reads, RowsBack, Ids, LastKey)
    VALUES (@Run, 'DEFERRED', @PageNo, @r1 - @r0, @n, ISNULL(@ids, ''), @last);
END
GO

-- Keyset ("seek") paging: the page after the row with sort key
-- (@AfterDate, @AfterID). NULLs mean the first page. @PageNo is only a
-- label here; keyset paging doesn't know or need it.
CREATE OR ALTER PROCEDURE Demo.usp_Page_Keyset
    @Run       varchar(40),
    @PageNo    int,
    @AfterDate datetime2(0) = NULL,
    @AfterID   int = NULL,
    @PageSize  int = 50
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r0 bigint, @r1 bigint, @ids varchar(8000), @n int, @chk int, @last varchar(40);
    SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;

    -- Two statements, not one with "@AfterDate IS NULL OR ...": with that
    -- in the WHERE clause the tested build scanned the index from the top
    -- for every page (217 reads at page 10, 1,214 at page 10,000) instead
    -- of seeking to where the page starts.
    IF @AfterDate IS NULL
        SELECT @ids  = STRING_AGG(CAST(o.OrderID AS varchar(8000)), ',') WITHIN GROUP (ORDER BY o.OrderDate DESC, o.OrderID DESC),
               @n    = COUNT(*),
               @chk  = CHECKSUM_AGG(CHECKSUM(o.CustomerID, o.Amount, o.Note)),
               @last = MIN(CONVERT(char(19), o.OrderDate, 120) + '|' + RIGHT('000000000' + CAST(o.OrderID AS varchar(10)), 10))
        FROM  (SELECT TOP (@PageSize) OrderID
               FROM   Demo.Orders
               ORDER BY OrderDate DESC, OrderID DESC) AS k
        JOIN   Demo.Orders AS o ON o.OrderID = k.OrderID
        OPTION (RECOMPILE);
    ELSE
        SELECT @ids  = STRING_AGG(CAST(o.OrderID AS varchar(8000)), ',') WITHIN GROUP (ORDER BY o.OrderDate DESC, o.OrderID DESC),
               @n    = COUNT(*),
               @chk  = CHECKSUM_AGG(CHECKSUM(o.CustomerID, o.Amount, o.Note)),
               @last = MIN(CONVERT(char(19), o.OrderDate, 120) + '|' + RIGHT('000000000' + CAST(o.OrderID AS varchar(10)), 10))
        FROM  (SELECT TOP (@PageSize) OrderID
               FROM   Demo.Orders
               -- "after (@AfterDate, @AfterID)" in DESC order: a range on
               -- OrderDate the index can seek to, plus a filter for the rows
               -- that share @AfterDate.
               WHERE  OrderDate <= @AfterDate AND (OrderDate < @AfterDate OR OrderID < @AfterID)
               ORDER BY OrderDate DESC, OrderID DESC) AS k
        -- Keys first, then the 50 rows. With the lookups under the TOP
        -- instead, the lookup's ORDERED PREFETCH read ahead far past row 50:
        -- 1,162 reads for a deep page on the tested build, against 165.
        JOIN   Demo.Orders AS o ON o.OrderID = k.OrderID
        OPTION (RECOMPILE);

    SELECT @r1 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    INSERT Demo.Pages (Run, Method, PageNo, Reads, RowsBack, Ids, LastKey)
    VALUES (@Run, 'KEYSET', @PageNo, @r1 - @r0, @n, ISNULL(@ids, ''), @last);
END
GO

-- OFFSET plus the total, for "page 1 of 20,000": COUNT(*) OVER ().
CREATE OR ALTER PROCEDURE Demo.usp_Page_Counted
    @Run      varchar(40),
    @PageNo   int,
    @PageSize int = 50
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r0 bigint, @r1 bigint, @ids varchar(8000), @n int, @chk int, @total bigint,
            @skip int = (@PageNo - 1) * @PageSize;
    SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;

    SELECT @ids   = STRING_AGG(CAST(OrderID AS varchar(8000)), ',') WITHIN GROUP (ORDER BY OrderDate DESC, OrderID DESC),
           @n     = COUNT(*),
           @chk   = CHECKSUM_AGG(CHECKSUM(CustomerID, Amount, Note)),
           @total = MAX(Total)
    FROM  (SELECT OrderID, OrderDate, CustomerID, Amount, Note, Total = COUNT_BIG(*) OVER ()
           FROM   Demo.Orders
           ORDER BY OrderDate DESC, OrderID DESC
           OFFSET @skip ROWS FETCH NEXT @PageSize ROWS ONLY) AS p
    OPTION (RECOMPILE);

    SELECT @r1 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    INSERT Demo.Pages (Run, Method, PageNo, Reads, RowsBack, TotalRows, Ids)
    VALUES (@Run, 'COUNTED', @PageNo, @r1 - @r0, @n, @total, ISNULL(@ids, ''));
END
GO

-- Tickets, ORDER BY Priority alone: three values, a thousand rows.
CREATE OR ALTER PROCEDURE Demo.usp_Ticket_Offset
    @Run      varchar(40),
    @PageNo   int,
    @PageSize int = 20,
    @TieBreak bit = 0          -- 1: ORDER BY Priority, TicketID
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ids varchar(8000), @n int, @chk int, @skip int = (@PageNo - 1) * @PageSize;

    IF @TieBreak = 0
        SELECT @ids = STRING_AGG(CAST(TicketID AS varchar(8000)), ','), @n = COUNT(*), @chk = CHECKSUM_AGG(CHECKSUM(Title))
        FROM  (SELECT TicketID, Title FROM Demo.Tickets
               ORDER BY Priority
               OFFSET @skip ROWS FETCH NEXT @PageSize ROWS ONLY) AS p
        OPTION (RECOMPILE);
    ELSE
        SELECT @ids = STRING_AGG(CAST(TicketID AS varchar(8000)), ','), @n = COUNT(*), @chk = CHECKSUM_AGG(CHECKSUM(Title))
        FROM  (SELECT TicketID, Title FROM Demo.Tickets
               ORDER BY Priority, TicketID
               OFFSET @skip ROWS FETCH NEXT @PageSize ROWS ONLY) AS p
        OPTION (RECOMPILE);

    INSERT Demo.Pages (Run, Method, PageNo, Reads, RowsBack, Ids)
    VALUES (@Run, CASE WHEN @TieBreak = 1 THEN 'OFFSET+TIEBREAK' ELSE 'OFFSET' END, @PageNo, 0, @n, ISNULL(@ids, ''));
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the PagingDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
