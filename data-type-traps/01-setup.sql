/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, TypeTrapsDemo, and puts everything inside
     it. Nothing else on the instance is modified:

        - no compatibility level is changed
        - no database scoped configuration is changed
        - no trace flag is set
        - no language or date format is changed for anyone; scenario G sets
          one for a single dynamic batch, which ends with it
        - no existing database is touched

  Creates, all inside TypeTrapsDemo:
     Demo.Ratings        - star ratings, int
     Demo.Payments       - 1,000,000 payments of 0.10, as float and decimal
     Demo.Events         - one event a minute around a month end, datetime
     Demo.Codes          - product codes, char(10), unique
     Demo.Tickets        - an int identity close to its limit
     Demo.Results        - what each scenario returned

  COST: about 60 MB, all inside TypeTrapsDemo.

  TESTED end to end on SQL Server 2022 CU25 (16.0.4255.1), Linux container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create TypeTrapsDemo ===';
GO

IF DB_ID('TypeTrapsDemo') IS NOT NULL
BEGIN
    RAISERROR('TypeTrapsDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE TypeTrapsDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE TypeTrapsDemo;
END
GO

CREATE DATABASE TypeTrapsDemo;
GO

ALTER DATABASE TypeTrapsDemo SET RECOVERY SIMPLE;
GO

USE TypeTrapsDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: tables ===';
GO

-- A: a product's ratings. Stars are whole numbers, so the column is int.
CREATE TABLE Demo.Ratings (RatingID int IDENTITY(1,1) PRIMARY KEY, ProductID int NOT NULL, Stars int NOT NULL);
INSERT Demo.Ratings (ProductID, Stars) VALUES (1, 5), (1, 4), (1, 4), (2, 3), (2, 4);
GO

-- B: a million payments of 10 cents each, stored twice.
CREATE TABLE Demo.Payments
(
    PaymentID   int            NOT NULL PRIMARY KEY,
    AmountFloat float          NOT NULL,
    AmountDec   decimal(12,2)  NOT NULL
);
;WITH n AS
(
    SELECT TOP (1000000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
    FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b CROSS JOIN sys.all_columns AS c
)
INSERT Demo.Payments WITH (TABLOCK) (PaymentID, AmountFloat, AmountDec)
SELECT rn, 0.1, 0.10 FROM n;
GO

-- F: one event a minute from 2025-01-31 00:00 to 2025-02-01 00:59.
CREATE TABLE Demo.Events (EventID int IDENTITY(1,1) PRIMARY KEY, At datetime NOT NULL);
;WITH n AS
(
    SELECT TOP (1500) rn = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
    FROM   sys.all_columns
)
INSERT Demo.Events (At) SELECT DATEADD(minute, rn, '20250131') FROM n;
GO

-- H: product codes, fixed width, and unique.
CREATE TABLE Demo.Codes (Code char(10) NOT NULL CONSTRAINT UQ_Codes UNIQUE, Note varchar(40) NULL);
CREATE TABLE Demo.VarCodes (Code varchar(10) NOT NULL CONSTRAINT UQ_VarCodes UNIQUE, Note varchar(40) NULL);
GO

-- I: an int identity with only three values left before the end.
CREATE TABLE Demo.Tickets (TicketID int IDENTITY(2147483645, 1) PRIMARY KEY, Note varchar(40) NOT NULL);
GO

CREATE TABLE Demo.Results
(
    Scenario  char(1)        NOT NULL,
    Item      nvarchar(100)  NOT NULL,
    Got       nvarchar(200)  NULL,
    Wanted    nvarchar(200)  NULL,
    Verdict   varchar(30)    NULL
);
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the TypeTrapsDemo database.';
PRINT ' No engine setting on this instance was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
