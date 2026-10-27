/*==============================================================================
  01-setup.sql          RUN ONCE. Takes about 1 to 2 minutes.
  ----------------------------------------------------------------------------
  Builds everything the demo needs, but runs NO demo of its own. Safe to run
  top to bottom in one go (F5).

  WHAT THIS TOUCHES ON YOUR INSTANCE

     It creates ONE new database, VectorDemo, and puts everything inside it.
     Nothing else on the instance is modified. Inside VectorDemo it turns on
     the database scoped configuration PREVIEW_FEATURES: on the tested build
     a vector index can't be created without it (scenario F shows that).

  ON SQL SERVER 2022 AND EARLIER the database and the harness are created,
  but no vectors: the vector type arrived in 2025. The demo reports every
  scenario as SKIPPED.

  Creates, all inside VectorDemo (2025 and later):
     Demo.Embeddings   - 100,000 vectors of 128 dimensions, in 200 clusters
                         (500 each), with a DiskANN vector index (cosine)
     Demo.SetupLog     - how long loading the rows and building the vector
                         index took
     Demo.usp_Query    - the query vector for test query @i, not in the table
     Demo.Results      - one row per measurement
     Demo.Verdicts     - one row per claim

  The vectors are synthetic: each cluster has a fixed centre, and each row is
  its centre plus deterministic noise. Real embeddings come from a model;
  these behave enough like them to show how the search works.

  TESTED end to end on SQL Server 2025 RTM-CU9-GDR (17.0.5015.4), Linux
  container.
==============================================================================*/

USE master;
GO
SET NOCOUNT ON;
GO

PRINT '=== STEP 1: create VectorDemo ===';
GO

IF DB_ID('VectorDemo') IS NOT NULL
BEGIN
    RAISERROR('VectorDemo already exists. Dropping it first.', 0, 1) WITH NOWAIT;
    ALTER DATABASE VectorDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE VectorDemo;
END
GO

CREATE DATABASE VectorDemo;
GO

ALTER DATABASE VectorDemo SET RECOVERY SIMPLE;
GO

USE VectorDemo;
GO
SET NOCOUNT ON;
GO

IF SCHEMA_ID('Demo') IS NULL
    EXEC ('CREATE SCHEMA Demo AUTHORIZATION dbo;');
GO

CREATE TABLE Demo.SetupLog
(
    Item   varchar(100) NOT NULL,
    Value  bigint       NOT NULL
);
GO


PRINT '=== STEP 2: Demo.Embeddings (about 20 seconds) ===';
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    EXEC (N'
    CREATE TABLE Demo.Embeddings
    (
        ID        int          NOT NULL CONSTRAINT PK_Embeddings PRIMARY KEY CLUSTERED,
        ClusterID int          NOT NULL,
        Embedding vector(128)  NOT NULL
    );');

    DECLARE @t0 datetime2 = SYSDATETIME();

    -- Row n belongs to cluster n % 200. Each dimension is the cluster''s
    -- centre (0 to 1) plus noise (0 to 0.25), both from hashes, so every run
    -- builds the same vectors.
    EXEC (N'
    ;WITH n AS
    (
        SELECT TOP (100000) rn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
        FROM   sys.all_columns AS a CROSS JOIN sys.all_columns AS b
    ),
    d AS
    (
        SELECT TOP (128) dn = CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS int)
        FROM   sys.all_columns
    )
    INSERT Demo.Embeddings WITH (TABLOCK) (ID, ClusterID, Embedding)
    SELECT n.rn, n.rn % 200,
           CAST(''['' + STRING_AGG(CAST(CAST(
                    (ABS(CHECKSUM(CONCAT(''c'', n.rn % 200, ''-'', d.dn))) % 1000) / 1000.0
                  + (ABS(CHECKSUM(CONCAT(''n'', n.rn, ''-'', d.dn))) % 1000) / 4000.0
                AS decimal(9,6)) AS varchar(max)), '','') WITHIN GROUP (ORDER BY d.dn) + '']'' AS vector(128))
    FROM   n CROSS JOIN d
    GROUP BY n.rn;');

    INSERT Demo.SetupLog (Item, Value) VALUES ('load ms', DATEDIFF(ms, @t0, SYSDATETIME()));
END
GO


PRINT '=== STEP 3: the vector index (about a minute) ===';
GO

-- The setting applies from the next batch, not the one that changes it.
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
    EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;');
GO

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 17
BEGIN
    DECLARE @t0 datetime2 = SYSDATETIME();
    EXEC (N'CREATE VECTOR INDEX VX_Embeddings ON Demo.Embeddings (Embedding) WITH (METRIC = ''cosine'', TYPE = ''diskann'');');
    INSERT Demo.SetupLog (Item, Value) VALUES ('vector index build ms', DATEDIFF(ms, @t0, SYSDATETIME()));
END
GO


PRINT '=== STEP 4: the harness ===';
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

/*------------------------------------------------------------------------------
  Demo.usp_Try -- run one statement, and return the error number it raised,
  or 0. The error is caught, so the demo's output carries no error message.
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


PRINT '';
PRINT '========================================================';
PRINT ' SETUP COMPLETE.';
PRINT '';
PRINT ' Everything lives in the VectorDemo database.';
PRINT ' No instance setting was changed.';
PRINT '';
PRINT ' Now open 02-demo.sql and run the whole file (F5).';
PRINT ' It prints a summary at the bottom; that is the payoff.';
PRINT '========================================================';
GO
