/*==============================================================================
  01-setup.sql          RUN ONCE. Takes about 10 seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, FuzzyDemo, and puts everything inside it.
     Nothing else on the instance is modified. Two things about FuzzyDemo
     matter, and scenario A shows why:

       - it's created with a Windows collation, Latin1_General_100_CI_AS,
         whatever the server's default is. The fuzzy functions refuse
         SQL_* collations, and SQL_Latin1_General_CP1_CI_AS is the default
         on a US-English install.
       - it turns on the database scoped configuration PREVIEW_FEATURES. Up
         to RTM-CU9-GDR the fuzzy functions don't exist without it; from
         CU10 (17.0.5035.5) it's no longer needed, and does no harm.

  ON SQL SERVER 2022 AND EARLIER the database is created, and the demo
  reports every scenario as SKIPPED: the functions arrived in 2025.

  Creates, all inside FuzzyDemo:
     Demo.People       - 200,000 surnames: 40 common surnames, each as
                         written and with four kinds of typo (two letters
                         swapped, a letter dropped, a letter replaced by
                         'y', a different first letter), 1,000 rows of
                         each; a persisted SOUNDEX code, indexed
     Demo.usp_Measure  - run one statement, return its CPU
     Demo.usp_Try      - run one statement, return the error it raised
     Demo.Results      - one row per measurement
     Demo.Verdicts     - one row per claim

  TESTED end to end on SQL Server 2025 RTM-CU9-GDR (17.0.5015.4), Linux
  container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create FuzzyDemo ===';
GO

IF DB_ID('FuzzyDemo') IS NOT NULL
BEGIN
    RAISERROR('FuzzyDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE FuzzyDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE FuzzyDemo;
END
GO

CREATE DATABASE FuzzyDemo COLLATE Latin1_General_100_CI_AS;
GO

ALTER DATABASE FuzzyDemo SET RECOVERY SIMPLE;
GO

USE FuzzyDemo;
GO
SET NOCOUNT ON;
GO

-- A database scoped configuration applies from the next batch.
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
    EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;');
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: Demo.People ===';
GO

CREATE TABLE Demo.People
(
    ID           int           NOT NULL CONSTRAINT PK_People PRIMARY KEY CLUSTERED,
    Surname      nvarchar(50)  NOT NULL,
    SoundexCode  AS SOUNDEX(Surname) PERSISTED
);

DECLARE @s TABLE (k int IDENTITY(0,1), n nvarchar(50));
INSERT @s (n) VALUES
 (N'Johnson'),(N'Smith'),(N'Williams'),(N'Brown'),(N'Jones'),(N'Garcia'),(N'Miller'),(N'Davis'),(N'Rodriguez'),(N'Martinez'),
 (N'Hernandez'),(N'Lopez'),(N'Gonzalez'),(N'Wilson'),(N'Anderson'),(N'Thomas'),(N'Taylor'),(N'Moore'),(N'Jackson'),(N'Martin'),
 (N'Lee'),(N'Perez'),(N'Thompson'),(N'White'),(N'Harris'),(N'Sanchez'),(N'Clark'),(N'Ramirez'),(N'Lewis'),(N'Robinson'),
 (N'Walker'),(N'Young'),(N'Allen'),(N'King'),(N'Wright'),(N'Scott'),(N'Torres'),(N'Nguyen'),(N'Hill'),(N'Flores');

-- Row n has surname n % 40, written one of five ways by (n / 40) % 5:
--   0 as written                     Johnson
--   1 2nd and 3rd letters swapped    Jhonson
--   2 3rd letter dropped             Jonson
--   3 2nd letter replaced by 'y'     Jyhnson
--   4 the next letter of the alphabet first   Kohnson... (Z wraps to A)
;WITH n AS
(
    SELECT TOP (200000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
)
INSERT Demo.People (ID, Surname)
SELECT n.rn,
       CASE (n.rn / 40) % 5
           WHEN 0 THEN s.n
           WHEN 1 THEN STUFF(s.n, 2, 2, SUBSTRING(s.n, 3, 1) + SUBSTRING(s.n, 2, 1))
           WHEN 2 THEN STUFF(s.n, 3, 1, N'')
           WHEN 3 THEN STUFF(s.n, 2, 1, N'y')
           ELSE        STUFF(s.n, 1, 1, NCHAR(CASE WHEN UNICODE(s.n) = 90 THEN 65 ELSE UNICODE(s.n) + 1 END))
       END
FROM   n JOIN @s AS s ON s.k = n.rn % 40;

CREATE INDEX IX_People_Soundex ON Demo.People (SoundexCode);
GO


PRINT '=== STEP 3: the harness ===';
GO

CREATE TABLE Demo.Results
(
    Scenario  char(1)        NOT NULL,
    Item      varchar(120)   NOT NULL,
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

CREATE OR ALTER PROCEDURE Demo.usp_Measure
    @sql    nvarchar(max),
    @CpuMs  bigint OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @c0 bigint, @c1 bigint;
    SELECT @c0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    EXEC sys.sp_executesql @sql;
    SELECT @c1 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    SET @CpuMs = @c1 - @c0;
END
GO

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


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the FuzzyDemo database.';
PRINT ' No instance setting was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
