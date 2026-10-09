/*==============================================================================
  01-setup.sql          RUN ONCE. Takes under a minute.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, ImplicitConversionDemo, and puts everything
     inside it. Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no existing database is touched
        - no instance-wide plan cache flush

     The database is created with an explicit collation,
     SQL_Latin1_General_CP1_CI_AS -- the default for a US-English install,
     and the collation under which the classic implicit-conversion scan
     happens. The two columns scenario A compares carry their OWN explicit
     collations, so the result does not depend on your instance default.

  Creates, all inside ImplicitConversionDemo:
     Demo.Customers       - 1,000,000 rows; the same customer code stored three
                            ways (varchar under a SQL collation, varchar under a
                            Windows collation, nvarchar), each indexed
     Demo.Orders          - 2,000 orders whose customer code is nvarchar
     Demo.Cases           - every query the demo runs, with its prediction
     Demo.CaseResults     - where 02-demo.sql records what each one did
     Demo.DemoResults     - verdict rows for scenario F
     Demo.usp_RunCase     - runs one case and records its evidence
     Demo.usp_Record      - the verdict collector

  COST: about 400 MB of data plus transaction log, all inside
  ImplicitConversionDemo.

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
        Edition         = CAST(SERVERPROPERTY('Edition') AS sysname),
        ServerCollation = CAST(SERVERPROPERTY('Collation') AS sysname);
GO


PRINT '=== STEP 1: create ImplicitConversionDemo ===';
GO

IF DB_ID('ImplicitConversionDemo') IS NOT NULL
BEGIN
    RAISERROR('ImplicitConversionDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE ImplicitConversionDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE ImplicitConversionDemo;
END
GO

CREATE DATABASE ImplicitConversionDemo COLLATE SQL_Latin1_General_CP1_CI_AS;
GO

ALTER DATABASE ImplicitConversionDemo SET RECOVERY SIMPLE;
GO

USE ImplicitConversionDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: Demo.Customers and Demo.Orders ===';
GO

/*------------------------------------------------------------------------------
  The same customer code, stored three ways, each with its own index:

     CodeSql  varchar(20)  COLLATE SQL_Latin1_General_CP1_CI_AS
     CodeWin  varchar(20)  COLLATE Latin1_General_CI_AS
     CodeN    nvarchar(20)

  Codes are 'C0000001' .. 'C1000000', except the first 50,000 rows, which all
  share the code 'HOT' -- so scenario A can check an estimate on a value with
  plenty of rows, not just a one-row lookup.

  Num, SignupDate: plain int and date columns, indexed, for the other type
  pairs in scenario C. Num is unique except for the same 50,000 rows, which
  share Num = 7.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.Orders, Demo.Customers;
GO

CREATE TABLE Demo.Customers
(
    CustomerID int           NOT NULL,
    CodeSql    varchar(20)   COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    CodeWin    varchar(20)   COLLATE Latin1_General_CI_AS         NOT NULL,
    CodeN      nvarchar(20)  NOT NULL,
    Num        int           NOT NULL,
    SignupDate date          NOT NULL,
    pad        char(100)     NOT NULL CONSTRAINT DF_Customers_pad DEFAULT ('x'),
    CONSTRAINT PK_Customers PRIMARY KEY CLUSTERED (CustomerID)
);
GO

;WITH n AS
(
    SELECT TOP (1000000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b CROSS JOIN sys.all_columns AS c
),
coded AS
(
    SELECT rn,
           code = CASE WHEN rn <= 50000 THEN 'HOT'
                       ELSE 'C' + RIGHT('0000000' + CAST(rn AS varchar(10)), 7) END
    FROM   n
)
INSERT Demo.Customers WITH (TABLOCK) (CustomerID, CodeSql, CodeWin, CodeN, Num, SignupDate)
SELECT rn, code, code, code,
       CASE WHEN rn <= 50000 THEN 7 ELSE rn END,
       DATEADD(day, rn % 3650, CAST('20160101' AS date))
FROM   coded;
GO

CREATE INDEX IX_Customers_CodeSql    ON Demo.Customers (CodeSql);
CREATE INDEX IX_Customers_CodeWin    ON Demo.Customers (CodeWin);
CREATE INDEX IX_Customers_CodeN      ON Demo.Customers (CodeN);
CREATE INDEX IX_Customers_Num        ON Demo.Customers (Num);
CREATE INDEX IX_Customers_SignupDate ON Demo.Customers (SignupDate);
GO

/*------------------------------------------------------------------------------
  Demo.Orders -- the join partner for scenario E. Its CustCode is nvarchar,
  as it would be if a different team, an ORM, or an import had created it.
------------------------------------------------------------------------------*/
CREATE TABLE Demo.Orders
(
    OrderID  int          IDENTITY(1,1) NOT NULL,
    CustCode nvarchar(20) NOT NULL,
    Amount   int          NOT NULL,
    CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderID)
);
GO

INSERT Demo.Orders (CustCode, Amount)
SELECT TOP (2000) CodeN, 1 FROM Demo.Customers WHERE CustomerID > 50000 ORDER BY CustomerID;
GO

CREATE INDEX IX_Orders_CustCode ON Demo.Orders (CustCode);
GO

SELECT  Customers = (SELECT COUNT_BIG(*) FROM Demo.Customers),
        HotRows   = (SELECT COUNT_BIG(*) FROM Demo.Customers WHERE CodeSql = 'HOT'),
        Orders    = (SELECT COUNT_BIG(*) FROM Demo.Orders);

SELECT  ColumnName = c.name, TypeName = t.name, c.max_length, c.collation_name
FROM    sys.columns AS c
JOIN    sys.types   AS t ON t.user_type_id = c.user_type_id
WHERE   c.object_id = OBJECT_ID('Demo.Customers') AND c.name LIKE 'Code%'
ORDER BY c.column_id;
GO


PRINT '=== STEP 3: the cases ===';
GO

/*------------------------------------------------------------------------------
  Every query the demo runs, as data. Each is a complete batch -- almost all
  of them an sp_executesql call with an explicitly typed parameter, because
  that is exactly what a client driver sends. Hand AddWithValue in .NET a
  string, for instance, and the parameter goes out as nvarchar whatever the
  column is.

  Each statement carries a marker comment (A1, A2 and so on, between comment
  delimiters) that Demo.usp_RunCase uses to find it again in
  sys.dm_exec_query_stats. The marker is not spelled with its delimiters
  here: sqlcmd does not nest comments, and a nested one inside this block
  would end it early.

  Every query (bar D1) returns a COUNT, not the rows themselves. Returning
  50,000 rows into the sink in Demo.usp_RunCase would add the writes to the
  sink to the logical reads of the query; a single count row does not. The "actual" each
  estimate is compared with is TrueRows, counted once below with the types
  matching.

  ExpectedOp is what this README predicts for the operator that reads
  Demo.Customers: 'Index Seek', 'Index Scan', or 'error'.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.Cases;
CREATE TABLE Demo.Cases
(
    Marker     varchar(4)     NOT NULL PRIMARY KEY,
    Scenario   varchar(60)    NOT NULL,
    StepNo     int            NOT NULL,
    Label      varchar(90)    NOT NULL,
    Batch      nvarchar(max)  NOT NULL,
    ExpectedOp varchar(20)    NOT NULL,
    TrueRows   bigint         NULL,      -- filled in below, by a correctly typed query
    CheckEstimate bit         NOT NULL CONSTRAINT DF_Cases_CheckEstimate DEFAULT (0)
);
GO

INSERT Demo.Cases (Marker, Scenario, StepNo, Label, Batch, ExpectedOp) VALUES

-- A. varchar column, nvarchar parameter. The classic.
('A0', 'A. varchar column, nvarchar value', 0, 'CONTROL  varchar col = varchar param',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*A0*/ FROM Demo.Customers WHERE CodeSql = @p'', N''@p varchar(20)'', @p = ''C0123456'';',
 'Index Seek'),
('A1', 'A. varchar column, nvarchar value', 1, 'SQL collation      varchar col = nvarchar param',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*A1*/ FROM Demo.Customers WHERE CodeSql = @p'', N''@p nvarchar(20)'', @p = N''C0123456'';',
 'Index Scan'),
('A2', 'A. varchar column, nvarchar value', 2, 'SQL collation      varchar col = N''...'' literal',
 N'SELECT n = COUNT_BIG(*) /*A2*/ FROM Demo.Customers WHERE CodeSql = N''C0123456'';',
 'Index Scan'),
('A3', 'A. varchar column, nvarchar value', 3, 'Windows collation  varchar col = nvarchar param',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*A3*/ FROM Demo.Customers WHERE CodeWin = @p'', N''@p nvarchar(20)'', @p = N''C0123456'';',
 'Index Seek'),
('A4', 'A. varchar column, nvarchar value', 4, 'Windows collation  same, 50,000-row value',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*A4*/ FROM Demo.Customers WHERE CodeWin = @p'', N''@p nvarchar(20)'', @p = N''HOT'';',
 'Index Seek'),

-- B. The direction that costs nothing.
('B1', 'B. nvarchar column, varchar value', 1, 'nvarchar col = varchar param',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*B1*/ FROM Demo.Customers WHERE CodeN = @p'', N''@p varchar(20)'', @p = ''C0123456'';',
 'Index Seek'),
('B2', 'B. nvarchar column, varchar value', 2, 'nvarchar col = varchar param, 50,000-row value',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*B2*/ FROM Demo.Customers WHERE CodeN = @p'', N''@p varchar(20)'', @p = ''HOT'';',
 'Index Seek'),

-- C. Other type pairs.
('C1', 'C. Other type pairs', 1, 'int col = bigint param',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*C1*/ FROM Demo.Customers WHERE Num = @p'', N''@p bigint'', @p = 123456;',
 'Index Seek'),
('C2', 'C. Other type pairs', 2, 'int col = decimal(10,0) param',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*C2*/ FROM Demo.Customers WHERE Num = @p'', N''@p decimal(10,0)'', @p = 123456;',
 'Index Seek'),
('C3', 'C. Other type pairs', 3, 'int col = varchar param',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*C3*/ FROM Demo.Customers WHERE Num = @p'', N''@p varchar(20)'', @p = ''123456'';',
 'Index Seek'),
('C4', 'C. Other type pairs', 4, 'date col = datetime param',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*C4*/ FROM Demo.Customers WHERE SignupDate = @p'', N''@p datetime'', @p = ''20200101'';',
 'Index Seek'),
('C5', 'C. Other type pairs', 5, 'varchar col = int param',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*C5*/ FROM Demo.Customers WHERE CodeSql = @p'', N''@p int'', @p = 123456;',
 'error'),

-- D. Warnings. The text of the warning is not the cost.
('D1', 'D. Warnings', 1, 'CONVERT in the SELECT list, 10-row seek',
 N'EXEC sys.sp_executesql N''SELECT TOP (10) x = CONVERT(varchar(10), Num) /*D1*/ FROM Demo.Customers WHERE CustomerID <= @k'', N''@k int'', @k = 10;',
 'Clustered Index Seek'),

-- E. Joins: the mismatch is between two COLUMNS.
('E0', 'E. Joins', 0, 'CONTROL  Orders.CustCode (nvarchar) = Customers.CodeN (nvarchar)',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*E0*/ FROM Demo.Orders AS o JOIN Demo.Customers AS c ON c.CodeN = o.CustCode WHERE o.OrderID <= @k'', N''@k int'', @k = 20;',
 'Index Seek'),
('E1', 'E. Joins', 1, 'Orders.CustCode (nvarchar) = Customers.CodeSql (varchar, SQL coll.)',
 N'EXEC sys.sp_executesql N''SELECT n = COUNT_BIG(*) /*E1*/ FROM Demo.Orders AS o JOIN Demo.Customers AS c ON c.CodeSql = o.CustCode WHERE o.OrderID <= @k'', N''@k int'', @k = 20;',
 'Index Scan');
GO

/*------------------------------------------------------------------------------
  The true number of rows the predicate of each case matches, counted with the
  types matching -- so no conversion is involved in the answer key.
------------------------------------------------------------------------------*/
UPDATE Demo.Cases SET TrueRows = (SELECT COUNT_BIG(*) FROM Demo.Customers WHERE CodeSql = 'C0123456') WHERE Marker IN ('A0','A1','A2','A3','B1');
UPDATE Demo.Cases SET TrueRows = (SELECT COUNT_BIG(*) FROM Demo.Customers WHERE CodeSql = 'HOT')      WHERE Marker IN ('A4','B2');
UPDATE Demo.Cases SET TrueRows = (SELECT COUNT_BIG(*) FROM Demo.Customers WHERE Num = 123456)        WHERE Marker IN ('C1','C2','C3');
UPDATE Demo.Cases SET TrueRows = (SELECT COUNT_BIG(*) FROM Demo.Customers WHERE SignupDate = '20200101') WHERE Marker = 'C4';
UPDATE Demo.Cases SET TrueRows = 10 WHERE Marker = 'D1';
UPDATE Demo.Cases SET TrueRows = (SELECT COUNT_BIG(*) FROM Demo.Orders WHERE OrderID <= 20) WHERE Marker IN ('E0','E1');

-- The cases whose ESTIMATE is part of the claim, not just their operator: a
-- seek through a conversion that still estimates the multi-row value
-- correctly. Their verdict also requires the estimate to be within 10% of
-- TrueRows. (One-row lookups would pass trivially; join and TOP estimates are
-- per execution and are not compared.)
UPDATE Demo.Cases SET CheckEstimate = 1 WHERE Marker IN ('A4','B2','C4');
GO

SELECT Marker, Label, ExpectedOp, TrueRows FROM Demo.Cases ORDER BY Marker;
GO


PRINT '=== STEP 4: evidence tables and procedures ===';
GO

DROP TABLE IF EXISTS Demo.CaseResults;
CREATE TABLE Demo.CaseResults
(
    Marker          varchar(4)     NOT NULL PRIMARY KEY,
    AccessOp        varchar(40)    NULL,     -- the operator that reads Demo.Customers
    EstimateRows    decimal(18,1)  NULL,     -- on that operator
    ActualRows      bigint         NULL,     -- rows the predicate truly matches
    LogicalReads    bigint         NULL,
    SeekPlanWarning bit            NULL,     -- PlanAffectingConvert, ConvertIssue="Seek Plan"
    CardEstWarning  bit            NULL,     -- PlanAffectingConvert, ConvertIssue="Cardinality Estimate"
    ThroughConvert  bit            NULL,     -- the seek used GetRangeThroughConvert
    ErrorText       nvarchar(300)  NULL,
    Verdict         varchar(24)    NULL,
    CapturedAt      datetime2(3)   NOT NULL CONSTRAINT DF_ICCase_CapturedAt DEFAULT SYSDATETIME()
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
    CapturedAt   datetime2(3)   NOT NULL CONSTRAINT DF_ICResults_CapturedAt DEFAULT SYSDATETIME()
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
  Demo.usp_RunCase -- run one case and record what it did.

  The batch runs inside INSERT ... EXEC so its one-row result lands in a
  sink rather than on screen.

  The evidence then comes from the plan cache, found by marker:

    - the cached plan is searched for the operator whose IndexScan element
      names [Customers]. In a join plan that matters: the first index
      operator in document order may belong to Demo.Orders.
    - last_logical_reads comes from sys.dm_exec_query_stats.

  The statement we want is the one whose text contains the marker but NOT
  the word sp_executesql -- the outer batch that called sp_executesql also
  contains the marker, inside its string literal, and is not the query.

  A conversion that fails at run time (C5) is caught and recorded as an
  error rather than allowed to stop the demo.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_RunCase
    @Marker varchar(4)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @batch nvarchar(max) = (SELECT Batch FROM Demo.Cases WHERE Marker = @Marker);
    DECLARE @expected varchar(20) = (SELECT ExpectedOp FROM Demo.Cases WHERE Marker = @Marker);
    DECLARE @checkEst bit = (SELECT CheckEstimate FROM Demo.Cases WHERE Marker = @Marker);
    DECLARE @sink TABLE (v sql_variant);
    DECLARE @err nvarchar(300);

    DELETE Demo.CaseResults WHERE Marker = @Marker;

    BEGIN TRY
        INSERT @sink EXEC sys.sp_executesql @batch;
    END TRY
    BEGIN CATCH
        SET @err = N'Msg ' + CAST(ERROR_NUMBER() AS nvarchar(10)) + N': ' + LEFT(ERROR_MESSAGE(), 280);
    END CATCH

    IF @err IS NOT NULL
    BEGIN
        INSERT Demo.CaseResults (Marker, ErrorText, Verdict)
        VALUES (@Marker, @err, CASE WHEN @expected = 'error' THEN 'RUNTIME ERROR' ELSE 'unexpected' END);
        RETURN;
    END

    DECLARE @pattern nvarchar(20) = N'%/*' + @Marker + N'*/%';
    DECLARE @plan xml, @reads bigint;
    DECLARE @rows bigint = (SELECT TrueRows FROM Demo.Cases WHERE Marker = @Marker);

    -- Scoped to this database by the PLAN's dbid attribute, not by
    -- sys.dm_exec_sql_text.dbid: that column is NULL for ad hoc and prepared
    -- statements, which is every case here. See scenario F in 02-demo.sql.
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

    DECLARE @op varchar(40), @est float, @seekWarn bit, @ceWarn bit, @through bit;

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    SELECT @op       = @plan.value('(//RelOp[IndexScan/Object/@Table="[Customers]"]/@PhysicalOp)[1]',   'varchar(40)'),
           @est      = @plan.value('(//RelOp[IndexScan/Object/@Table="[Customers]"]/@EstimateRows)[1]', 'float'),
           @seekWarn = @plan.exist('//PlanAffectingConvert[@ConvertIssue="Seek Plan"]'),
           @ceWarn   = @plan.exist('//PlanAffectingConvert[@ConvertIssue="Cardinality Estimate"]'),
           @through  = @plan.exist('//Intrinsic[@FunctionName="GetRangeThroughConvert"]');

    INSERT Demo.CaseResults
           (Marker, AccessOp, EstimateRows, ActualRows, LogicalReads,
            SeekPlanWarning, CardEstWarning, ThroughConvert, Verdict)
    VALUES (@Marker, @op, @est, @rows, @reads, @seekWarn, @ceWarn, @through,
            CASE WHEN @plan IS NULL                                    THEN 'NO PLAN FOUND'
                 WHEN @op <> @expected                                 THEN 'unexpected'
                 WHEN @checkEst = 1 AND ABS(@est - @rows) > @rows * 0.1 THEN 'unexpected'
                 ELSE UPPER(@op) END);
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the ImplicitConversionDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
