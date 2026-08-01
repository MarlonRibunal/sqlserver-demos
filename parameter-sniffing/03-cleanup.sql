/*==============================================================================
  03-cleanup.sql        RUN LAST. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Undoes everything 01-setup.sql did:
     - restores the original compatibility level
     - restores the database scoped configuration values it changed
     - drops the Extended Events session
     - drops the Demo schema and everything in it (including the 500,000 rows)

  Settings are restored from Demo.DemoState, which is read BEFORE anything is
  dropped. If you already dropped the Demo schema by hand, the restore steps
  will report that they have nothing to go on and skip -- set the compatibility
  level back manually in that case.
==============================================================================*/

USE WideWorldImporters;
GO
SET NOCOUNT ON;
GO

PRINT '=== What we are about to restore ===';
GO

IF OBJECT_ID('Demo.DemoState') IS NOT NULL
    SELECT SettingName, SettingValue, CapturedAt FROM Demo.DemoState ORDER BY SettingName;
ELSE
    RAISERROR('Demo.DemoState is gone -- cannot restore settings automatically.', 0, 1) WITH NOWAIT;
GO


PRINT '=== STEP 1: restore database scoped configurations ===';
GO

IF OBJECT_ID('Demo.DemoState') IS NOT NULL
BEGIN
    DECLARE @name  sysname,
            @val   nvarchar(256),
            @sql   nvarchar(400);

    DECLARE dsc CURSOR LOCAL FAST_FORWARD FOR
        SELECT SettingName = RIGHT(SettingName, LEN(SettingName) - 4),   -- strip 'DSC_'
               SettingValue
        FROM   Demo.DemoState
        WHERE  SettingName LIKE 'DSC[_]%';

    OPEN dsc;
    FETCH NEXT FROM dsc INTO @name, @val;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Only touch it if the configuration still exists and has drifted.
        IF EXISTS (SELECT 1 FROM sys.database_scoped_configurations
                   WHERE name = @name AND CAST(value AS nvarchar(256)) <> @val)
        BEGIN
            SET @sql = N'ALTER DATABASE SCOPED CONFIGURATION SET ' + QUOTENAME(@name)
                     + N' = ' + CASE WHEN @val = N'1' THEN N'ON' ELSE N'OFF' END + N';';
            RAISERROR('  %s', 0, 1, @sql) WITH NOWAIT;
            EXEC sys.sp_executesql @sql;
        END
        ELSE
            RAISERROR('  %s already at its original value (or no longer exists). Skipped.', 0, 1, @name) WITH NOWAIT;

        FETCH NEXT FROM dsc INTO @name, @val;
    END
    CLOSE dsc; DEALLOCATE dsc;
END
GO


PRINT '=== STEP 2: restore compatibility level ===';
GO

IF OBJECT_ID('Demo.DemoState') IS NOT NULL
BEGIN
    DECLARE @original int = (SELECT CAST(SettingValue AS int) FROM Demo.DemoState
                             WHERE SettingName = 'OriginalCompatLevel');
    DECLARE @current  int = (SELECT compatibility_level FROM sys.databases WHERE database_id = DB_ID());

    IF @original IS NOT NULL AND @original <> @current
    BEGIN
        DECLARE @sql nvarchar(400) =
            N'ALTER DATABASE ' + QUOTENAME(DB_NAME())
          + N' SET COMPATIBILITY_LEVEL = ' + CAST(@original AS nvarchar(10)) + N';';
        RAISERROR('  restoring compatibility level %d -> %d', 0, 1, @current, @original) WITH NOWAIT;
        EXEC sys.sp_executesql @sql;
    END
    ELSE
        RAISERROR('  compatibility level already %d. Nothing to do.', 0, 1, @current) WITH NOWAIT;
END
GO


PRINT '=== STEP 2b: restore Query Store ===';
GO

/*------------------------------------------------------------------------------
  01-setup.sql set Query Store to READ_WRITE for scenario F if it was not
  already. Put the desired state back.

  Collected data is deliberately left alone. Turning Query Store off does not
  discard it, and this script has no business deciding that a database's query
  history is disposable.
------------------------------------------------------------------------------*/
IF OBJECT_ID('Demo.DemoState') IS NOT NULL
BEGIN
    DECLARE @qs_orig    nvarchar(60) = (SELECT SettingValue FROM Demo.DemoState
                                        WHERE SettingName = 'QueryStoreDesiredState');
    DECLARE @qs_current nvarchar(60) = (SELECT desired_state_desc FROM sys.database_query_store_options);
    DECLARE @qs_sql     nvarchar(400);

    IF @qs_orig IS NULL
        RAISERROR('  no recorded Query Store state. Nothing to do.', 0, 1) WITH NOWAIT;
    ELSE IF @qs_orig = @qs_current
        RAISERROR('  Query Store already %s. Nothing to do.', 0, 1, @qs_current) WITH NOWAIT;
    ELSE
    BEGIN
        SET @qs_sql = N'ALTER DATABASE ' + QUOTENAME(DB_NAME())
                    + CASE @qs_orig
                          WHEN N'OFF'       THEN N' SET QUERY_STORE = OFF;'
                          WHEN N'READ_ONLY' THEN N' SET QUERY_STORE = ON (OPERATION_MODE = READ_ONLY);'
                          ELSE                   N' SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);'
                      END;
        RAISERROR('  restoring Query Store %s -> %s', 0, 1, @qs_current, @qs_orig) WITH NOWAIT;
        EXEC sys.sp_executesql @qs_sql;
    END
END
GO


PRINT '=== STEP 3: drop the Extended Events session ===';
GO

BEGIN TRY
    IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = 'Demo_ParamSniffing')
        ALTER EVENT SESSION Demo_ParamSniffing ON SERVER STATE = STOP;

    IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'Demo_ParamSniffing')
    BEGIN
        DROP EVENT SESSION Demo_ParamSniffing ON SERVER;
        RAISERROR('  dropped event session Demo_ParamSniffing', 0, 1) WITH NOWAIT;
    END
    ELSE
        RAISERROR('  no event session to drop', 0, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    -- RAISERROR arguments must be variables or constants, never function calls.
    DECLARE @errmsg nvarchar(2048) = ERROR_MESSAGE();
    RAISERROR('  could not drop the event session: %s', 0, 1, @errmsg) WITH NOWAIT;
    RAISERROR('  drop it by hand if it still exists.', 0, 1) WITH NOWAIT;
END CATCH
GO


PRINT '=== STEP 4: drop the demo objects ===';
GO

-- Free the plan cache entries for these procedures. Object-scoped, not
-- instance-wide -- no DBCC FREEPROCCACHE here either.
BEGIN TRY
    IF OBJECT_ID('Demo.usp_CustomerLinesByPrice') IS NOT NULL
        EXEC sys.sp_recompile N'Demo.usp_CustomerLinesByPrice';
    IF OBJECT_ID('Demo.usp_CustomerLinesByPrice_Recompile') IS NOT NULL
        EXEC sys.sp_recompile N'Demo.usp_CustomerLinesByPrice_Recompile';
END TRY
BEGIN CATCH
END CATCH
GO

DROP PROCEDURE IF EXISTS Demo.usp_CustomerLinesByPrice;
DROP PROCEDURE IF EXISTS Demo.usp_CustomerLinesByPrice_Recompile;
DROP PROCEDURE IF EXISTS Demo.usp_Capture;
DROP PROCEDURE IF EXISTS Demo.usp_BackfillMGFeedback;
DROP VIEW      IF EXISTS Demo.vw_GrantStats;
DROP VIEW      IF EXISTS Demo.vw_CachedPlan;
DROP TABLE     IF EXISTS Demo.OrderLinesSkewed;
DROP TABLE     IF EXISTS Demo.DemoResults;
DROP TABLE     IF EXISTS Demo.DemoState;
GO

IF SCHEMA_ID('Demo') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.objects WHERE schema_id = SCHEMA_ID('Demo'))
BEGIN
    DROP SCHEMA Demo;
    RAISERROR('  dropped schema Demo', 0, 1) WITH NOWAIT;
END
ELSE IF SCHEMA_ID('Demo') IS NOT NULL
BEGIN
    RAISERROR('  schema Demo still contains objects -- left in place. Contents:', 0, 1) WITH NOWAIT;
    SELECT SchemaName = 'Demo', ObjectName = name, type_desc
    FROM   sys.objects WHERE schema_id = SCHEMA_ID('Demo');
END
GO


PRINT '=== STEP 5: verify ===';
GO

SELECT  DatabaseName = DB_NAME(),
        CompatLevel  = d.compatibility_level,
        DemoSchema   = CASE WHEN SCHEMA_ID('Demo') IS NULL THEN 'gone' ELSE 'still present' END
FROM    sys.databases AS d
WHERE   d.database_id = DB_ID();

SELECT  name, value, value_for_secondary
FROM    sys.database_scoped_configurations
WHERE   name LIKE '%FEEDBACK%' OR name LIKE '%PARAMETER_SENSITIVE%'
ORDER BY name;
GO

PRINT '';
PRINT '=== CLEANUP COMPLETE. Compare the output above against the first ===';
PRINT '=== two result sets from 01-setup.sql.                           ===';
GO
