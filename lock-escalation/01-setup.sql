/*==============================================================================
  01-setup.sql          RUN ONCE. Takes under a minute.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, LockEscalationDemo, and puts everything
     inside it. Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set (1211 and 1224, which change escalation
          instance-wide, are discussed in the README and never used)
        - no existing database is touched

     The LOCK_ESCALATION option IS used -- it is a property of a table, and it
     is set only on tables this script creates.

  Creates, all inside LockEscalationDemo:
     Demo.Items             - 100,000 rows, LOCK_ESCALATION = TABLE (default)
     Demo.ItemsDisabled     - same rows,   LOCK_ESCALATION = DISABLE
     Demo.ItemsPartitioned  - same rows, four partitions, LOCK_ESCALATION = AUTO
     Demo.LockSnapshots     - one row per probe: the locks it held
     Demo.usp_Probe         - runs a statement in a transaction, records the
                              locks this session holds, then ROLLS BACK

  COST: about 270 MB of data plus transaction log, all inside
  LockEscalationDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), 8 schedulers.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 0: environment ===';
GO

SELECT  ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS sysname),
        Edition        = CAST(SERVERPROPERTY('Edition') AS sysname);

-- The 'locks' setting changes how escalation is triggered (a fixed lock
-- count instead of a share of lock memory). 0, the default, is assumed.
SELECT  name, value_in_use FROM sys.configurations WHERE name = 'locks';
GO


PRINT '=== STEP 1: create LockEscalationDemo ===';
GO

IF DB_ID('LockEscalationDemo') IS NOT NULL
BEGIN
    RAISERROR('LockEscalationDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE LockEscalationDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE LockEscalationDemo;
END
GO

CREATE DATABASE LockEscalationDemo;
GO

ALTER DATABASE LockEscalationDemo SET RECOVERY SIMPLE;
GO

USE LockEscalationDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: three copies of the same table ===';
GO

/*------------------------------------------------------------------------------
  Three tables, the same 100,000 rows, differing only in how they escalate:

     Demo.Items             LOCK_ESCALATION = TABLE    the default
     Demo.ItemsDisabled     LOCK_ESCALATION = DISABLE  never escalates (almost)
     Demo.ItemsPartitioned  LOCK_ESCALATION = AUTO     escalates to the
                                                       PARTITION, not the table

  Rows are about 230 bytes, so roughly 35 to a page. That matters: page
  locks count toward the escalation threshold too.
------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Demo.Items, Demo.ItemsDisabled, Demo.ItemsPartitioned;
GO

IF EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name = 'PS_Items')
    DROP PARTITION SCHEME PS_Items;
IF EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = 'PF_Items')
    DROP PARTITION FUNCTION PF_Items;
GO

CREATE PARTITION FUNCTION PF_Items (int) AS RANGE RIGHT FOR VALUES (25001, 50001, 75001);
CREATE PARTITION SCHEME   PS_Items AS PARTITION PF_Items ALL TO ([PRIMARY]);
GO

CREATE TABLE Demo.Items
(
    ItemID int       NOT NULL,
    Qty    int       NOT NULL,
    pad    char(200) NOT NULL CONSTRAINT DF_Items_pad DEFAULT ('x'),
    CONSTRAINT PK_Items PRIMARY KEY CLUSTERED (ItemID)
);

CREATE TABLE Demo.ItemsDisabled
(
    ItemID int       NOT NULL,
    Qty    int       NOT NULL,
    pad    char(200) NOT NULL CONSTRAINT DF_ItemsDisabled_pad DEFAULT ('x'),
    CONSTRAINT PK_ItemsDisabled PRIMARY KEY CLUSTERED (ItemID)
);

CREATE TABLE Demo.ItemsPartitioned
(
    ItemID int       NOT NULL,
    Qty    int       NOT NULL,
    pad    char(200) NOT NULL CONSTRAINT DF_ItemsPartitioned_pad DEFAULT ('x'),
    CONSTRAINT PK_ItemsPartitioned PRIMARY KEY CLUSTERED (ItemID) ON PS_Items (ItemID)
);
GO

;WITH n AS
(
    SELECT TOP (100000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.Items WITH (TABLOCK) (ItemID, Qty) SELECT rn, 1 FROM n;

INSERT Demo.ItemsDisabled    WITH (TABLOCK) (ItemID, Qty) SELECT ItemID, Qty FROM Demo.Items;
INSERT Demo.ItemsPartitioned WITH (TABLOCK) (ItemID, Qty) SELECT ItemID, Qty FROM Demo.Items;
GO

ALTER TABLE Demo.ItemsDisabled    SET (LOCK_ESCALATION = DISABLE);
ALTER TABLE Demo.ItemsPartitioned SET (LOCK_ESCALATION = AUTO);
GO

SELECT  TableName      = OBJECT_SCHEMA_NAME(t.object_id) + '.' + t.name,
        t.lock_escalation_desc,
        Partitions     = (SELECT COUNT(*) FROM sys.partitions AS p
                          WHERE p.object_id = t.object_id AND p.index_id = 1),
        Rows           = (SELECT SUM(p.rows) FROM sys.partitions AS p
                          WHERE p.object_id = t.object_id AND p.index_id = 1),
        RowsPerPage    = (SELECT CAST(SUM(ps.row_count) * 1.0 / SUM(ps.in_row_data_page_count) AS decimal(6,1))
                          FROM sys.dm_db_partition_stats AS ps
                          WHERE ps.object_id = t.object_id AND ps.index_id = 1)
FROM    sys.tables AS t
WHERE   t.schema_id = SCHEMA_ID('Demo')
ORDER BY t.name;
GO


PRINT '=== STEP 3: the evidence table and the probe ===';
GO

DROP TABLE IF EXISTS Demo.LockSnapshots;
CREATE TABLE Demo.LockSnapshots
(
    SnapshotID    int           IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Scenario      varchar(60)   NOT NULL,
    StepNo        int           NOT NULL,
    Label         varchar(90)   NOT NULL,
    RowsTouched   bigint        NULL,     -- @@ROWCOUNT of the last statement
    KeyLocks      int           NULL,
    PageLocks     int           NULL,
    ObjectMode    varchar(10)   NULL,     -- this session's lock on the table
    HobtLocks     int           NULL,     -- partition-level locks
    HobtModes     varchar(40)   NULL,
    TotalLocks    int           NULL,
    Escalations   bigint        NULL,     -- from sys.dm_db_index_operational_stats
    Expected      nvarchar(140) NULL,
    Verdict       varchar(24)   NULL,
    CapturedAt    datetime2(3)  NOT NULL CONSTRAINT DF_LESnap_CapturedAt DEFAULT SYSDATETIME()
);
GO

/*------------------------------------------------------------------------------
  Demo.usp_Probe -- run @Sql inside a transaction, record every lock THIS
  session holds in this database, then roll back.

  Everything happens in one session: sys.dm_tran_locks shows a session its
  own locks while the transaction is still open, so no second connection is
  needed to see what escalation did. What a second connection would SEE --
  being blocked by the table lock -- is described in the README rather than
  staged, because staging it needs two sessions running at once.

  ROLLBACK at the end puts every row back, so the demo can be re-run without
  re-running setup.

  Escalations are counted from index_lock_promotion_count in
  sys.dm_db_index_operational_stats, before and after. That is SQL Server's
  own record of escalating, independent of reading the lock list.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Probe
    @Scenario  varchar(60),
    @StepNo    int,
    @Label     varchar(90),
    @Table     sysname,
    @Sql       nvarchar(max),
    @Expected  nvarchar(140) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @obj int = OBJECT_ID(@Table);
    DECLARE @promo0 bigint =
        (SELECT SUM(index_lock_promotion_count)
         FROM   sys.dm_db_index_operational_stats(DB_ID(), @obj, NULL, NULL));
    DECLARE @rows bigint;

    -- A table variable, not Demo.LockSnapshots directly: the probe ROLLS BACK,
    -- and a row inserted into a real table inside the transaction would roll
    -- back with everything else. Table variables ignore ROLLBACK -- the one
    -- case where that is exactly what you want (see the tempdb topic).
    DECLARE @snap TABLE (KeyLocks int, PageLocks int, ObjectMode varchar(10),
                         HobtLocks int, HobtModes varchar(40), TotalLocks int);

    BEGIN TRANSACTION;

        EXEC sys.sp_executesql @Sql, N'@rc bigint OUTPUT', @rc = @rows OUTPUT;

        -- Modes are read with TOP (1) subqueries rather than MAX(CASE ...),
        -- which would raise a "Null value is eliminated" warning per probe.
        INSERT @snap (KeyLocks, PageLocks, ObjectMode, HobtLocks, HobtModes, TotalLocks)
        SELECT  SUM(CASE WHEN l.resource_type = 'KEY'  THEN 1 ELSE 0 END),
                SUM(CASE WHEN l.resource_type = 'PAGE' THEN 1 ELSE 0 END),
                (SELECT TOP (1) o.request_mode FROM sys.dm_tran_locks AS o
                 WHERE  o.request_session_id = @@SPID AND o.resource_database_id = DB_ID()
                   AND  o.resource_type = 'OBJECT' AND o.resource_associated_entity_id = @obj),
                SUM(CASE WHEN l.resource_type = 'HOBT' THEN 1 ELSE 0 END),
                (SELECT TOP (1) h.request_mode FROM sys.dm_tran_locks AS h
                 WHERE  h.request_session_id = @@SPID AND h.resource_database_id = DB_ID()
                   AND  h.resource_type = 'HOBT'),
                COUNT(*)
        FROM    sys.dm_tran_locks AS l
        WHERE   l.request_session_id   = @@SPID
          AND   l.resource_database_id = DB_ID()
          AND   l.resource_type IN ('KEY', 'PAGE', 'OBJECT', 'HOBT', 'RID');

    ROLLBACK TRANSACTION;

    DECLARE @promo1 bigint =
        (SELECT SUM(index_lock_promotion_count)
         FROM   sys.dm_db_index_operational_stats(DB_ID(), @obj, NULL, NULL));

    INSERT Demo.LockSnapshots
           (Scenario, StepNo, Label, RowsTouched, KeyLocks, PageLocks, ObjectMode,
            HobtLocks, HobtModes, TotalLocks, Escalations, Expected)
    SELECT  @Scenario, @StepNo, @Label, @rows, KeyLocks, PageLocks, ObjectMode,
            HobtLocks, HobtModes, TotalLocks, @promo1 - @promo0, @Expected
    FROM    @snap;
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the LockEscalationDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
