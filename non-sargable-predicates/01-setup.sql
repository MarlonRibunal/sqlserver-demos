/*==============================================================================
  01-setup.sql          RUN ONCE. Takes under a minute.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, SargabilityDemo, and puts everything inside
     it. Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched
        - no plan cache flush of any kind

  Creates, all inside SargabilityDemo:
     Demo.Events          - 1,000,000 events over ten years, five indexes
     Demo.EventsCC        - the same rows, plus an indexed computed column
     Demo.Cases           - every query the demo runs, paired with its
                            rewrite, and the operator predicted for each
     Demo.CaseResults     - where 02-demo.sql records what each one did
     Demo.usp_RunCase     - runs one case and records its evidence

  COST: about 450 MB of data plus transaction log, all inside
  SargabilityDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers,
  MAXDOP 0, cost threshold for parallelism 5.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
-- Demo.usp_RunCase uses XML methods, which fail with Msg 1934 unless the
-- procedure was CREATED under QUOTED_IDENTIFIER ON. SSMS defaults it ON;
-- sqlcmd does not (pass -I). Setting it here makes the file safe either way.
SET QUOTED_IDENTIFIER ON;
GO

PRINT '=== STEP 0: environment ===';
GO

SELECT  ProductVersion  = CAST(SERVERPROPERTY('ProductVersion') AS sysname),
        Edition         = CAST(SERVERPROPERTY('Edition') AS sysname);
GO


PRINT '=== STEP 1: create SargabilityDemo ===';
GO

IF DB_ID('SargabilityDemo') IS NOT NULL
BEGIN
    RAISERROR('SargabilityDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE SargabilityDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE SargabilityDemo;
END
GO

-- A case-insensitive collation, stated rather than inherited, because case
-- C4x depends on it: under a CI collation UPPER() changes nothing about which
-- rows match, so wrapping a column in it is pure cost.
CREATE DATABASE SargabilityDemo COLLATE Latin1_General_CI_AS;
GO

ALTER DATABASE SargabilityDemo SET RECOVERY SIMPLE;
GO

USE SargabilityDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: Demo.Events ===';
GO

/*------------------------------------------------------------------------------
  One million events, about 274 a day from 2016-01-01 to 2025-12-31.

     EventTime  datetime2(0)  the column most predicates here wrap in a function
     Name       varchar(20)   N0000001 .. N1000000
     Discount   int NULL      NULL for 70% of rows, 0 for 1%, else 1..50
     Amount     int           unique, equal to EventID

  Every searched column has its own nonclustered index, so each query has an
  index to seek on IF its predicate allows one. Every query counts rows, so
  the index covers it and the only question is seek or scan.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.Events, Demo.EventsCC;
GO

CREATE TABLE Demo.Events
(
    EventID   int           NOT NULL,
    EventTime datetime2(0)  NOT NULL,
    Name      varchar(20)   NOT NULL,
    Discount  int           NULL,
    Amount    int           NOT NULL,
    pad       char(100)     NOT NULL CONSTRAINT DF_Events_pad DEFAULT ('x'),
    CONSTRAINT PK_Events PRIMARY KEY CLUSTERED (EventID)
);
GO

;WITH n AS
(
    SELECT TOP (1000000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b CROSS JOIN sys.all_columns AS c
)
INSERT Demo.Events WITH (TABLOCK) (EventID, EventTime, Name, Discount, Amount)
SELECT rn,
       DATEADD(second, CAST((rn - 1) * 315.5 AS int), CAST('20160101' AS datetime2(0))),
       'N' + RIGHT('0000000' + CAST(rn AS varchar(10)), 7),
       CASE WHEN rn % 100 < 70 THEN NULL
            WHEN rn % 100 = 70 THEN 0
            ELSE rn % 50 + 1 END,
       rn
FROM   n;
GO

CREATE INDEX IX_Events_EventTime ON Demo.Events (EventTime);
CREATE INDEX IX_Events_Name      ON Demo.Events (Name);
CREATE INDEX IX_Events_Discount  ON Demo.Events (Discount);
CREATE INDEX IX_Events_Amount    ON Demo.Events (Amount);
GO

/*------------------------------------------------------------------------------
  Demo.EventsCC -- scenario E. The same rows, plus a computed column holding
  YEAR(EventTime), with an index on it. Not PERSISTED: an index on a
  deterministic computed column materializes the value in the index anyway.

  The point is that a query written against Demo.EventsCC as
  WHERE YEAR(EventTime) = 2025 -- not mentioning EventYear at all -- is
  matched to the computed column by the optimizer and can seek.
------------------------------------------------------------------------------*/
CREATE TABLE Demo.EventsCC
(
    EventID   int           NOT NULL,
    EventTime datetime2(0)  NOT NULL,
    EventYear AS YEAR(EventTime),
    pad       char(100)     NOT NULL CONSTRAINT DF_EventsCC_pad DEFAULT ('x'),
    CONSTRAINT PK_EventsCC PRIMARY KEY CLUSTERED (EventID)
);
GO

INSERT Demo.EventsCC WITH (TABLOCK) (EventID, EventTime)
SELECT EventID, EventTime FROM Demo.Events;
GO

CREATE INDEX IX_EventsCC_EventYear ON Demo.EventsCC (EventYear);
GO

SELECT  Events    = COUNT_BIG(*),
        FirstTime = MIN(EventTime),
        LastTime  = MAX(EventTime),
        NullDisc  = SUM(CASE WHEN Discount IS NULL THEN 1 ELSE 0 END),
        ZeroDisc  = SUM(CASE WHEN Discount = 0 THEN 1 ELSE 0 END)
FROM    Demo.Events;
GO


PRINT '=== STEP 3: the cases ===';
GO

/*------------------------------------------------------------------------------
  Every query the demo runs, as data. Cases come in PAIRS: a predicate with
  the column wrapped in a function or expression (suffix x), and its rewrite
  with the column left bare (suffix o). Both must return the same count --
  the demo checks that, because a rewrite that changes the answer is not a
  rewrite.

  Each statement carries a marker comment (the case id, between comment
  delimiters) that Demo.usp_RunCase uses to find it in the plan cache. The
  marker is not spelled with its delimiters here: sqlcmd does not nest
  comments, and a nested one inside this block would end it early.

  Every case is an sp_executesql call with parameters typed to match their
  columns exactly, so no implicit conversion is involved (that is a separate
  topic in this repo). Literals are avoided on purpose: SQL Server rewrites a
  simple literal query into a parameterized form whose cached text has lost
  its comments, and with them the marker the demo finds it by.

  ExpectedOp is the operator predicted for the index access. Note C2x: a
  leading-wildcard LIKE built from a parameter is predicted as a SEEK, because
  that is what the plan says. Scenario C in 02-demo.sql shows what it reads.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.Cases;
CREATE TABLE Demo.Cases
(
    CaseID     varchar(4)     NOT NULL PRIMARY KEY,
    Scenario   varchar(60)    NOT NULL,
    Label      varchar(90)    NOT NULL,
    Batch      nvarchar(max)  NOT NULL,
    ExpectedOp varchar(20)    NOT NULL,
    PairWith   varchar(4)     NULL      -- the case that must return the same count
);
GO

INSERT Demo.Cases (CaseID, Scenario, Label, Batch, ExpectedOp, PairWith) VALUES

-- A. Dates
('A1x', 'A. Dates', 'YEAR(EventTime) = @y',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*A1x*/ FROM Demo.Events WHERE YEAR(EventTime) = @y;'', N''@y int'', @y = 2025;',
 'Index Scan', 'A1o'),
('A1o', 'A. Dates', 'EventTime >= @from AND EventTime < @to',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*A1o*/ FROM Demo.Events WHERE EventTime >= @from AND EventTime < @to;'', N''@from datetime2(0), @to datetime2(0)'', @from = ''20250101'', @to = ''20260101'';',
 'Index Seek', NULL),
('A2x', 'A. Dates', 'CONVERT(char(8), EventTime, 112) = @s',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*A2x*/ FROM Demo.Events WHERE CONVERT(char(8), EventTime, 112) = @s;'', N''@s char(8)'', @s = ''20250315'';',
 'Index Scan', 'A2o'),
('A2o', 'A. Dates', 'EventTime >= @from AND EventTime < @to  (one day)',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*A2o*/ FROM Demo.Events WHERE EventTime >= @from AND EventTime < @to;'', N''@from datetime2(0), @to datetime2(0)'', @from = ''20250315'', @to = ''20250316'';',
 'Index Seek', NULL),
('A3x', 'A. Dates', 'CAST(EventTime AS date) = @d',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*A3x*/ FROM Demo.Events WHERE CAST(EventTime AS date) = @d;'', N''@d date'', @d = ''20250315'';',
 'Index Seek', 'A2o'),
('A4x', 'A. Dates', 'DATEADD(day, 30, EventTime) >= @d',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*A4x*/ FROM Demo.Events WHERE DATEADD(day, 30, EventTime) >= @d;'', N''@d datetime2(0)'', @d = ''20251225'';',
 'Index Scan', 'A4o'),
('A4o', 'A. Dates', 'EventTime >= DATEADD(day, -30, @d)',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*A4o*/ FROM Demo.Events WHERE EventTime >= DATEADD(day, -30, @d);'', N''@d datetime2(0)'', @d = ''20251225'';',
 'Index Seek', NULL),
('A5x', 'A. Dates', 'DATEDIFF(day, EventTime, @d) = 0',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*A5x*/ FROM Demo.Events WHERE DATEDIFF(day, EventTime, @d) = 0;'', N''@d datetime2(0)'', @d = ''20250315'';',
 'Index Scan', 'A2o'),

-- B. NULL handling
('B1x', 'B. NULL handling', 'ISNULL(Discount, 0) = @v',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*B1x*/ FROM Demo.Events WHERE ISNULL(Discount, 0) = @v;'', N''@v int'', @v = 0;',
 'Index Scan', 'B1o'),
('B1o', 'B. NULL handling', '(Discount = @v OR Discount IS NULL)',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*B1o*/ FROM Demo.Events WHERE (Discount = @v OR Discount IS NULL);'', N''@v int'', @v = 0;',
 'Index Seek', NULL),
('B2x', 'B. NULL handling', 'ISNULL(Discount, 0) = @v  (@v = 25)',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*B2x*/ FROM Demo.Events WHERE ISNULL(Discount, 0) = @v;'', N''@v int'', @v = 25;',
 'Index Scan', 'B2o'),
('B2o', 'B. NULL handling', 'Discount = @v  (@v = 25)',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*B2o*/ FROM Demo.Events WHERE Discount = @v;'', N''@v int'', @v = 25;',
 'Index Seek', NULL),

-- C. Strings
('C1x', 'C. Strings', 'LEFT(Name, 5) = @p',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*C1x*/ FROM Demo.Events WHERE LEFT(Name, 5) = @p;'', N''@p varchar(20)'', @p = ''N0042'';',
 'Index Scan', 'C1o'),
('C1o', 'C. Strings', 'Name LIKE @p + ''%''',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*C1o*/ FROM Demo.Events WHERE Name LIKE @p + ''''%'''';'', N''@p varchar(20)'', @p = ''N0042'';',
 'Index Seek', NULL),
('C2x', 'C. Strings', 'Name LIKE ''%'' + @p  (leading wildcard)',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*C2x*/ FROM Demo.Events WHERE Name LIKE ''''%'''' + @p;'', N''@p varchar(20)'', @p = ''42123'';',
 'Index Seek', NULL),
('C3x', 'C. Strings', 'LTRIM(RTRIM(Name)) = @p',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*C3x*/ FROM Demo.Events WHERE LTRIM(RTRIM(Name)) = @p;'', N''@p varchar(20)'', @p = ''N0042123'';',
 'Index Scan', 'C3o'),
('C3o', 'C. Strings', 'Name = @p',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*C3o*/ FROM Demo.Events WHERE Name = @p;'', N''@p varchar(20)'', @p = ''N0042123'';',
 'Index Seek', NULL),
('C4x', 'C. Strings', 'UPPER(Name) = @p  (CI collation)',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*C4x*/ FROM Demo.Events WHERE UPPER(Name) = @p;'', N''@p varchar(20)'', @p = ''N0042123'';',
 'Index Scan', 'C3o'),

-- D. Arithmetic
('D1x', 'D. Arithmetic', 'Amount + 1 = @v',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*D1x*/ FROM Demo.Events WHERE Amount + 1 = @v;'', N''@v int'', @v = 500001;',
 'Index Scan', 'D1o'),
('D1o', 'D. Arithmetic', 'Amount = @v - 1',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*D1o*/ FROM Demo.Events WHERE Amount = @v - 1;'', N''@v int'', @v = 500001;',
 'Index Seek', NULL),

-- E. Computed column
('E1x', 'E. Computed column', 'YEAR(EventTime) = @y  on Demo.EventsCC',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*E1x*/ FROM Demo.EventsCC WHERE YEAR(EventTime) = @y;'', N''@y int'', @y = 2025;',
 'Index Seek', 'A1o');
GO

SELECT CaseID, Label, ExpectedOp, PairWith FROM Demo.Cases ORDER BY CaseID;
GO


PRINT '=== STEP 4: evidence table and procedure ===';
GO

DROP TABLE IF EXISTS Demo.CaseResults;
CREATE TABLE Demo.CaseResults
(
    CaseID        varchar(4)     NOT NULL PRIMARY KEY,
    AccessOp      varchar(40)    NULL,     -- the first operator that reads an index
    IndexName     sysname        NULL,     -- which index it read
    EstimateRows  decimal(18,1)  NULL,     -- on that operator
    CountReturned bigint         NULL,     -- the answer the query gave
    LogicalReads  bigint         NULL,
    Verdict       varchar(24)    NULL,
    CapturedAt    datetime2(3)   NOT NULL CONSTRAINT DF_SGCase_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  Demo.usp_RunCase -- run one case and record what it did.

  The batch runs inside INSERT ... EXEC. Its single result -- the COUNT -- is
  kept: it is the answer the query gave, and the demo compares it with the
  answer of the paired rewrite.

  The plan is found by marker, scoped by the dbid attribute of the PLAN
  (sys.dm_exec_plan_attributes). Not by sys.dm_exec_sql_text.dbid, which is
  NULL for ad hoc and sp_executesql statements -- every case here.

  Each case reads one table, so the first RelOp that reads an index is the
  access operator. For the OR case, which may seek twice and concatenate,
  that is the first of the seeks.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_RunCase
    @CaseID varchar(4)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @batch    nvarchar(max) = (SELECT Batch      FROM Demo.Cases WHERE CaseID = @CaseID);
    DECLARE @expected varchar(20)   = (SELECT ExpectedOp FROM Demo.Cases WHERE CaseID = @CaseID);
    DECLARE @sink TABLE (n bigint);

    DELETE Demo.CaseResults WHERE CaseID = @CaseID;

    INSERT @sink EXEC sys.sp_executesql @batch;

    DECLARE @pattern nvarchar(20) = N'%/*' + @CaseID + N'*/%';
    DECLARE @plan xml, @reads bigint;

    SELECT TOP (1)
           @plan  = qp.query_plan,
           @reads = qs.last_logical_reads
    FROM   sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
    CROSS APPLY (SELECT dbid = CAST(pa.value AS int)
                 FROM   sys.dm_exec_plan_attributes(qs.plan_handle) AS pa
                 WHERE  pa.attribute = 'dbid') AS pdb
    WHERE  pdb.dbid = DB_ID()
      AND  st.text LIKE @pattern
      AND  st.text NOT LIKE N'%sp_executesql%'
      AND  qp.query_plan IS NOT NULL
    ORDER BY qs.last_execution_time DESC;

    DECLARE @op varchar(40), @ix sysname, @est float;

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT @op  = @plan.value('(//RelOp[IndexScan]/@PhysicalOp)[1]',              'varchar(40)'),
           @ix  = @plan.value('(//RelOp[IndexScan]/IndexScan/Object/@Index)[1]',  'sysname'),
           @est = @plan.value('(//RelOp[IndexScan]/@EstimateRows)[1]',            'float');

    INSERT Demo.CaseResults (CaseID, AccessOp, IndexName, EstimateRows, CountReturned, LogicalReads, Verdict)
    VALUES (@CaseID, @op, REPLACE(REPLACE(@ix, '[', ''), ']', ''), @est,
            (SELECT n FROM @sink), @reads,
            CASE WHEN @plan IS NULL   THEN 'NO PLAN FOUND'
                 WHEN @op = @expected THEN UPPER(@op)
                 ELSE 'unexpected' END);
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the SargabilityDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
