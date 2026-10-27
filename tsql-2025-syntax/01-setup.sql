/*==============================================================================
  01-setup.sql          RUN ONCE. Takes a few seconds.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, SyntaxDemo, with the collation
     SQL_Latin1_General_CP1_CI_AS stated explicitly (UNISTR's behaviour
     depends on it), and puts everything inside it. Nothing else on the
     instance is modified.

  ON SQL SERVER 2022 AND EARLIER the database is created, and the demo
  reports every scenario as SKIPPED: the syntax it tests arrived in 2025.
  None of the new syntax appears in this file, so it runs on any version.

  Creates, all inside SyntaxDemo:
     Demo.usp_Eval       - run one statement that sets @v, record what it
                           returned (or the error it raised)
     Demo.Results        - one row per attempt
     Demo.Verdicts       - one row per claim

  TESTED end to end on SQL Server 2025 RTM-CU9-GDR (17.0.5015.4), Linux
  container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create SyntaxDemo ===';
GO

IF DB_ID('SyntaxDemo') IS NOT NULL
BEGIN
    RAISERROR('SyntaxDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE SyntaxDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE SyntaxDemo;
END
GO

CREATE DATABASE SyntaxDemo COLLATE SQL_Latin1_General_CP1_CI_AS;
GO

ALTER DATABASE SyntaxDemo SET RECOVERY SIMPLE;
GO

USE SyntaxDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO


PRINT '=== STEP 2: the harness ===';
GO

CREATE TABLE Demo.Results
(
    Scenario  char(1)        NOT NULL,
    Item      varchar(200)   NOT NULL,
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

/*------------------------------------------------------------------------------
  Demo.usp_Eval -- run one statement that assigns @v (nvarchar(max)), and
  record what happened as one row of Demo.Results:

     the value, as text           when it ran
     NULL                         when it ran and returned NULL
     error <n>                    when it raised an error

  The error is caught, so the demo's output carries no error message. A
  syntax error in the statement is caught too: it runs in its own scope,
  through sp_executesql. @Out returns the same text, for the verdicts.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE Demo.usp_Eval
    @Scenario  char(1),
    @Item      varchar(200),
    @sql       nvarchar(max),
    @Out       varchar(400) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @v nvarchar(max);
    BEGIN TRY
        EXEC sys.sp_executesql @sql, N'@v nvarchar(max) OUTPUT', @v = @v OUTPUT;
        SET @Out = ISNULL(LEFT(@v, 400), 'NULL');
    END TRY
    BEGIN CATCH
        SET @Out = 'error ' + CAST(ERROR_NUMBER() AS varchar(10));
    END CATCH
    INSERT Demo.Results (Scenario, Item, Value) VALUES (@Scenario, @Item, @Out);
END
GO


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the SyntaxDemo database.';
PRINT ' No instance setting was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
