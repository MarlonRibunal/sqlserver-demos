/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, TempGovDemo. Setup itself changes nothing
     else, but it RECORDS the current Resource Governor settings (whether it
     is enabled, and the default workload group's tempdb limits), because
     the DEMO CHANGES THEM:

        02-demo.sql puts a tempdb limit on the DEFAULT workload group and
        enables Resource Governor. The default group holds every session
        that no classifier function sends elsewhere: on most servers, all
        of them. While the demo runs, every such session on the instance
        is limited to 20 MB of tempdb between them.

     The demo puts the recorded settings back at the end, and so does
     03-cleanup.sql. Run this on a scratch instance only.

  ON SQL SERVER 2022 AND EARLIER the database is created, and the demo
  reports every scenario as SKIPPED: tempdb space governance arrived in
  2025. Nothing is changed.

  Creates, all inside TempGovDemo:
     Demo.Numbers        - 1 to 10,000, to generate rows without touching
                           tempdb
     Demo.Wide           - 6,400 rows of 7,000 bytes, about 50 MB, for the
                           version store test; READ_COMMITTED_SNAPSHOT is on
     Demo.OriginalRG     - the Resource Governor settings found at setup
     Demo.usp_ApplyRG    - set the default group's tempdb limits
     Demo.usp_RestoreRG  - put the recorded settings back
     Demo.usp_Drain      - wait until tempdb space the default group holds
                           has been released
     Demo.usp_Try        - run one statement, return the error it raised
     Demo.Results        - one row per attempt
     Demo.Verdicts       - one row per claim

  TESTED end to end on SQL Server 2025 RTM-CU10 (17.0.5035.5), Linux
  container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create TempGovDemo ===';
GO

IF DB_ID('TempGovDemo') IS NOT NULL
BEGIN
    RAISERROR('TempGovDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE TempGovDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE TempGovDemo;
END
GO

CREATE DATABASE TempGovDemo;
GO

ALTER DATABASE TempGovDemo SET RECOVERY SIMPLE;
ALTER DATABASE TempGovDemo SET READ_COMMITTED_SNAPSHOT ON;
GO

USE TempGovDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: the tables ===';
GO

CREATE TABLE Demo.Numbers (N int NOT NULL CONSTRAINT PK_Numbers PRIMARY KEY);
INSERT Demo.Numbers (N)
SELECT TOP (10000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
FROM sys.all_columns AS a CROSS JOIN sys.all_columns AS b;
GO

CREATE TABLE Demo.Wide
(
    ID   int         NOT NULL CONSTRAINT PK_Wide PRIMARY KEY,
    Pad  char(7000)  NOT NULL
);
INSERT Demo.Wide (ID, Pad) SELECT N, 'a' FROM Demo.Numbers WHERE N <= 6400;
GO


PRINT '=== STEP 3: record the Resource Governor settings ===';
GO

CREATE TABLE Demo.OriginalRG
(
    IsEnabled   bit            NOT NULL,
    MaxMB       bigint         NULL,
    MaxPercent  decimal(5,2)   NULL,
    RecordedAt  datetime2(0)   NOT NULL DEFAULT SYSDATETIME()
);
GO

-- The tempdb columns exist from 2025 only, so this is dynamic SQL.
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
    EXEC (N'
    INSERT Demo.OriginalRG (IsEnabled, MaxMB, MaxPercent)
    SELECT c.is_enabled, g.group_max_tempdb_data_mb, g.group_max_tempdb_data_percent
    FROM   sys.resource_governor_configuration AS c
    CROSS JOIN sys.resource_governor_workload_groups AS g
    WHERE  g.name = N''default'';');
GO


PRINT '=== STEP 4: the harness ===';
GO

/*------------------------------------------------------------------------------
  Demo.usp_ApplyRG -- set the default group's tempdb limits (NULL = none) and
  apply them with ALTER RESOURCE GOVERNOR RECONFIGURE, which also enables
  Resource Governor. @Reconfigure = 0 changes the group and stops there.
  Resource Governor DDL runs in master.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_ApplyRG
    @MaxMB        bigint,
    @MaxPercent   decimal(5,2),
    @Reconfigure  bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql nvarchar(400) =
        N'ALTER WORKLOAD GROUP [default] WITH (GROUP_MAX_TEMPDB_DATA_MB = '
        + ISNULL(CAST(@MaxMB AS nvarchar(20)), N'NULL')
        + N', GROUP_MAX_TEMPDB_DATA_PERCENT = '
        + ISNULL(CAST(@MaxPercent AS nvarchar(20)), N'NULL') + N');';
    EXEC master.sys.sp_executesql @sql;
    IF @Reconfigure = 1
        EXEC master.sys.sp_executesql N'ALTER RESOURCE GOVERNOR RECONFIGURE;';
END
GO

-- Put back what Demo.OriginalRG recorded: the limits, and Resource Governor
-- enabled or disabled as it was.
CREATE OR ALTER PROCEDURE Demo.usp_RestoreRG
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @on bit, @mb bigint, @pct decimal(5,2);
    SELECT TOP (1) @on = IsEnabled, @mb = MaxMB, @pct = MaxPercent FROM Demo.OriginalRG;
    IF @on IS NULL RETURN;
    EXEC Demo.usp_ApplyRG @mb, @pct, @Reconfigure = 0;
    IF @on = 1
        EXEC master.sys.sp_executesql N'ALTER RESOURCE GOVERNOR RECONFIGURE;';
    ELSE
        EXEC master.sys.sp_executesql N'ALTER RESOURCE GOVERNOR DISABLE;';
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_Drain -- tempdb pages are released in the background after a
  temporary object is dropped (deferred drop), and until then they still
  count against the group. Wait, at most 30 seconds, until the default group
  holds less than 4 MB of tempdb.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Drain
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 datetime2(3) = SYSDATETIME(), @kb bigint;
    WHILE 1 = 1
    BEGIN
        EXEC sys.sp_executesql
             N'SELECT @kb = tempdb_data_space_kb FROM sys.dm_resource_governor_workload_groups WHERE name = N''default'';',
             N'@kb bigint OUTPUT', @kb = @kb OUTPUT;
        IF @kb < 4096 OR DATEDIFF(second, @t0, SYSDATETIME()) >= 30 BREAK;
        WAITFOR DELAY '00:00:00.200';
    END
END
GO

/*------------------------------------------------------------------------------
  Demo.usp_Try -- run one statement and return the error number it raised,
  or 0. The error is caught, so the demo's output carries no error message.
  A temporary table the statement creates is dropped when it ends.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Try
    @sql    nvarchar(max),
    @Error  int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Error = 0;
    BEGIN TRY
        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        SET @Error = ERROR_NUMBER();
    END CATCH
END
GO

CREATE TABLE Demo.Results
(
    Scenario  char(1)        NOT NULL,
    Item      varchar(160)   NOT NULL,
    Value     varchar(400)   NULL,
    Seq       int            IDENTITY(1,1) NOT NULL
);
GO

CREATE TABLE Demo.Verdicts
(
    Scenario  char(1)        NOT NULL,
    Claim     varchar(200)   NOT NULL,
    Evidence  varchar(400)   NULL,
    Verdict   varchar(30)    NOT NULL,
    Seq       int            IDENTITY(1,1) NOT NULL
);
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the TempGovDemo database. The';
PRINT ' Resource Governor settings were recorded, not changed.';
PRINT '';
PRINT ' 02-demo.sql CHANGES THE DEFAULT WORKLOAD GROUP for the';
PRINT ' whole instance while it runs. Scratch instances only.';
PRINT '========================================================';
GO
