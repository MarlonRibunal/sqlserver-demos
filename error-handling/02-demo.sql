/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Error handling in T-SQL: what an error does to the rest of the batch and to
  the transaction, with and without XACT_ABORT and TRY/CATCH.

     A  no TRY/CATCH: XACT_ABORT OFF commits half a transaction
     B  TRY/CATCH: XACT_STATE() in the CATCH block, and doomed transactions
     C  errors TRY/CATCH doesn't catch
     D  a trigger written for one row
     E  RAISERROR and THROW

  Scenarios A, C and E run their batches in ErrorDemo's background session
  (see 01-setup.sql), where nothing catches the error: that's the point.
  The errors appear in the SQL Server error log, not here.

  WHAT THIS CHANGES: only ErrorDemo. It adds and deletes orders, and
  creates and drops triggers on Demo.Orders.

  TESTED end to end on SQL Server 2025 RTM-CU10 (17.0.5035.5) and 2022
  RTM-CU25 (16.0.4255.1), Linux containers.
==============================================================================*/

USE ErrorDemo;
GO
SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO

TRUNCATE TABLE Demo.Results;
TRUNCATE TABLE Demo.Verdicts;
GO

-- Start clean, whatever a previous run left behind.
IF OBJECT_ID('Demo.trg_Orders_Check') IS NOT NULL DROP TRIGGER Demo.trg_Orders_Check;
IF OBJECT_ID('Demo.trg_Orders_Audit') IS NOT NULL DROP TRIGGER Demo.trg_Orders_Audit;
DELETE Demo.Orders;
TRUNCATE TABLE Demo.OrderAudit;
GO


/*==============================================================================
  A. One transaction, three inserts, the second a duplicate key. No
  TRY/CATCH anywhere: the code most of us inherited.
==============================================================================*/
PRINT '=== A. no TRY/CATCH ===';
GO
DECLARE @ret1 bit, @steps1 varchar(400), @orders1 varchar(400),
        @ret2 bit, @orders2 varchar(400);

EXEC Demo.usp_RunUncaught N'
SET XACT_ABORT OFF;
BEGIN TRANSACTION;
    INSERT Demo.Orders (OrderID, Amount) VALUES (1, 10);  EXEC Demo.usp_Step ''insert 1'';
    INSERT Demo.Orders (OrderID, Amount) VALUES (1, 20);  EXEC Demo.usp_Step ''insert 1 again'';
    INSERT Demo.Orders (OrderID, Amount) VALUES (3, 30);  EXEC Demo.usp_Step ''insert 3'';
COMMIT;
EXEC Demo.usp_Step ''committed'';', @ret1 OUTPUT;
SELECT @steps1 = Demo.fn_Steps(), @orders1 = Demo.fn_Orders();
DELETE Demo.Orders;

EXEC Demo.usp_RunUncaught N'
SET XACT_ABORT ON;
BEGIN TRANSACTION;
    INSERT Demo.Orders (OrderID, Amount) VALUES (11, 10);
    INSERT Demo.Orders (OrderID, Amount) VALUES (11, 20);
    INSERT Demo.Orders (OrderID, Amount) VALUES (13, 30);
COMMIT;', @ret2 OUTPUT;
SELECT @orders2 = Demo.fn_Orders();
DELETE Demo.Orders;

INSERT Demo.Results (Scenario, Item, Value) VALUES
('A', 'XACT_ABORT OFF: steps reached',               @steps1),
('A', 'XACT_ABORT OFF: orders committed',            @orders1),
('A', 'XACT_ABORT ON: batch ran to the end',         CASE @ret2 WHEN 1 THEN 'yes' ELSE 'no: aborted at the error' END),
('A', 'XACT_ABORT ON: orders committed',             @orders2);

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('A', 'XACT_ABORT OFF: the duplicate key fails one statement; the rest runs, and COMMIT saves orders 1 and 3',
 @steps1 + ' | orders: ' + @orders1,
 CASE WHEN @orders1 = '1,3' AND @steps1 LIKE '%insert 3 > committed' THEN 'CONFIRMED' ELSE 'unexpected' END),
('A', 'XACT_ABORT ON: the error stops the batch and rolls the whole transaction back',
 'ran to the end: ' + CASE @ret2 WHEN 1 THEN 'yes' ELSE 'no' END + ' | orders: ' + @orders2,
 CASE WHEN @ret2 = 0 AND @orders2 = '(none)' THEN 'CONFIRMED' ELSE 'unexpected' END);
GO


/*==============================================================================
  B. The same with TRY/CATCH, in this session. What state is the
  transaction in when CATCH runs?
==============================================================================*/
PRINT '=== B. TRY/CATCH and XACT_STATE() ===';
GO
-- B1: XACT_ABORT OFF. The CATCH block commits if it can.
DECLARE @state1 int, @orders1 varchar(400);
SET XACT_ABORT OFF;
BEGIN TRY
    BEGIN TRANSACTION;
    INSERT Demo.Orders (OrderID, Amount) VALUES (21, 10);
    INSERT Demo.Orders (OrderID, Amount) VALUES (21, 20);
    INSERT Demo.Orders (OrderID, Amount) VALUES (23, 30);
    COMMIT;
END TRY
BEGIN CATCH
    SET @state1 = XACT_STATE();
    IF XACT_STATE() = 1 COMMIT;
    IF XACT_STATE() = -1 ROLLBACK;
END CATCH
SET @orders1 = Demo.fn_Orders();
DELETE Demo.Orders;

-- B2: XACT_ABORT ON, and a CATCH block that tries to commit anyway.
DECLARE @state2 int, @commitErr int = 0;
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;
    INSERT Demo.Orders (OrderID, Amount) VALUES (31, 10);
    INSERT Demo.Orders (OrderID, Amount) VALUES (31, 20);
    COMMIT;
END TRY
BEGIN CATCH
    SET @state2 = XACT_STATE();
    BEGIN TRY
        COMMIT;
    END TRY
    BEGIN CATCH
        SET @commitErr = ERROR_NUMBER();
    END CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
END CATCH
SET XACT_ABORT OFF;

INSERT Demo.Results (Scenario, Item, Value) VALUES
('B', 'XACT_ABORT OFF: XACT_STATE() in CATCH',                CAST(@state1 AS varchar(5))),
('B', 'XACT_ABORT OFF: orders after CATCH committed',         @orders1),
('B', 'XACT_ABORT ON: XACT_STATE() in CATCH',                 CAST(@state2 AS varchar(5))),
('B', 'XACT_ABORT ON: COMMIT in CATCH',                       CASE @commitErr WHEN 0 THEN 'succeeded' ELSE 'error ' + CAST(@commitErr AS varchar(10)) END);

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('B', 'XACT_ABORT OFF: the transaction is still committable (1) in CATCH; committing it keeps the insert before the error',
 'XACT_STATE() ' + CAST(@state1 AS varchar(5)) + ', orders: ' + @orders1,
 CASE WHEN @state1 = 1 AND @orders1 = '21' THEN 'CONFIRMED' ELSE 'unexpected' END),
('B', 'XACT_ABORT ON: the transaction is doomed (-1); COMMIT fails with error 3930, only ROLLBACK works',
 'XACT_STATE() ' + CAST(@state2 AS varchar(5)) + ', COMMIT: ' + CASE @commitErr WHEN 0 THEN 'succeeded' ELSE 'error ' + CAST(@commitErr AS varchar(10)) END,
 CASE WHEN @state2 = -1 AND @commitErr = 3930 THEN 'CONFIRMED' ELSE 'unexpected' END);
GO

-- B3: an error raised in a trigger, with XACT_ABORT OFF in the caller.
CREATE TRIGGER Demo.trg_Orders_Check ON Demo.Orders AFTER INSERT
AS
    IF EXISTS (SELECT 1 FROM inserted WHERE Amount < 0)
        THROW 50001, 'Amount must not be negative.', 1;
GO
DECLARE @state int, @err int;
SET XACT_ABORT OFF;
BEGIN TRY
    BEGIN TRANSACTION;
    INSERT Demo.Orders (OrderID, Amount) VALUES (41, 10);
    INSERT Demo.Orders (OrderID, Amount) VALUES (42, -5);
    COMMIT;
END TRY
BEGIN CATCH
    SELECT @state = XACT_STATE(), @err = ERROR_NUMBER();
    IF XACT_STATE() <> 0 ROLLBACK;
END CATCH
DROP TRIGGER Demo.trg_Orders_Check;

INSERT Demo.Results (Scenario, Item, Value) VALUES
('B', 'error from a trigger, XACT_ABORT OFF: error / XACT_STATE() in CATCH', CAST(@err AS varchar(10)) + ' / ' + CAST(@state AS varchar(5)));

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('B', 'an error in a trigger dooms the transaction (-1), even with XACT_ABORT OFF',
 'error ' + CAST(@err AS varchar(10)) + ', XACT_STATE() ' + CAST(@state AS varchar(5)),
 CASE WHEN @err = 50001 AND @state = -1 THEN 'CONFIRMED' ELSE 'unexpected' END);
GO


/*==============================================================================
  C. Errors TRY/CATCH doesn't catch.
==============================================================================*/
PRINT '=== C. errors TRY/CATCH does not catch ===';
GO
-- C1: a table that doesn't exist, inside TRY, in the background session.
DECLARE @ret bit, @steps varchar(400);
EXEC Demo.usp_RunUncaught N'
BEGIN TRY
    EXEC Demo.usp_Step ''in TRY'';
    SELECT * FROM Demo.NoSuchTable;
    EXEC Demo.usp_Step ''after the SELECT'';
END TRY
BEGIN CATCH
    EXEC Demo.usp_Step ''in CATCH'';
END CATCH
EXEC Demo.usp_Step ''after CATCH'';', @ret OUTPUT;
SET @steps = Demo.fn_Steps();

-- C2: the same SELECT one level down, in dynamic SQL, inside TRY.
DECLARE @caught int = 0;
BEGIN TRY
    EXEC (N'SELECT * FROM Demo.NoSuchTable;');
END TRY
BEGIN CATCH
    SET @caught = ERROR_NUMBER();
END CATCH

-- C3: RAISERROR with severity 10, inside TRY. It prints its message below.
DECLARE @sev10 varchar(20) = 'not caught';
BEGIN TRY
    RAISERROR('C3: a severity 10 message. TRY/CATCH lets it through.', 10, 1);
END TRY
BEGIN CATCH
    SET @sev10 = 'caught';
END CATCH

INSERT Demo.Results (Scenario, Item, Value) VALUES
('C', 'missing table, same level as TRY: steps reached',          @steps),
('C', 'missing table: the caller one level up carried on',        CASE @ret WHEN 1 THEN 'yes' ELSE 'no' END),
('C', 'missing table, one level down (EXEC): CATCH got',          CASE @caught WHEN 0 THEN 'nothing' ELSE 'error ' + CAST(@caught AS varchar(10)) END),
('C', 'RAISERROR severity 10 inside TRY',                         @sev10);

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('C', 'a missing table at the same level as TRY: CATCH never runs, and the rest of the batch is skipped; the error goes to the caller',
 @steps + ' | caller carried on: ' + CASE @ret WHEN 1 THEN 'yes' ELSE 'no' END,
 CASE WHEN @steps = 'in TRY' AND @ret = 1 THEN 'CONFIRMED' ELSE 'unexpected' END),
('C', 'one level down, the same error is caught: error 208',
 CASE @caught WHEN 0 THEN 'nothing' ELSE 'error ' + CAST(@caught AS varchar(10)) END,
 CASE WHEN @caught = 208 THEN 'CONFIRMED' ELSE 'unexpected' END),
('C', 'severity 10 or lower is a message, not an error: CATCH doesn''t run',
 @sev10, CASE WHEN @sev10 = 'not caught' THEN 'CONFIRMED' ELSE 'unexpected' END);
GO


/*==============================================================================
  D. An audit trigger written as if INSERT always inserted one row.
==============================================================================*/
PRINT '=== D. a trigger written for one row ===';
GO
CREATE TRIGGER Demo.trg_Orders_Audit ON Demo.Orders AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id int;
    SELECT @id = OrderID FROM inserted;
    INSERT Demo.OrderAudit (OrderID) VALUES (@id);
END
GO
INSERT Demo.Orders (OrderID, Amount) VALUES (51, 10), (52, 20), (53, 30);
INSERT Demo.Results (Scenario, Item, Value)
SELECT 'D', 'one-row trigger: audit rows for a 3-row INSERT', CAST(COUNT(*) AS varchar(10)) FROM Demo.OrderAudit;
DELETE Demo.Orders;
TRUNCATE TABLE Demo.OrderAudit;
GO
-- The fix: treat inserted as the set of rows it is.
ALTER TRIGGER Demo.trg_Orders_Audit ON Demo.Orders AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT Demo.OrderAudit (OrderID) SELECT OrderID FROM inserted;
END
GO
INSERT Demo.Orders (OrderID, Amount) VALUES (51, 10), (52, 20), (53, 30);
DECLARE @set int = (SELECT COUNT(*) FROM Demo.OrderAudit),
        @one int = (SELECT CAST(Value AS int) FROM Demo.Results WHERE Scenario = 'D');
DROP TRIGGER Demo.trg_Orders_Audit;
DELETE Demo.Orders;
TRUNCATE TABLE Demo.OrderAudit;

INSERT Demo.Results (Scenario, Item, Value) VALUES
('D', 'set-based trigger: audit rows for a 3-row INSERT', CAST(@set AS varchar(10)));

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('D', 'a trigger that reads inserted into a variable audits one row of three, with no error',
 CAST(@one AS varchar(10)) + ' audit row(s); set-based: ' + CAST(@set AS varchar(10)),
 CASE WHEN @one = 1 AND @set = 3 THEN 'CONFIRMED' ELSE 'unexpected' END);
GO


/*==============================================================================
  E. RAISERROR and THROW, with no TRY/CATCH, in the background session.
==============================================================================*/
PRINT '=== E. RAISERROR and THROW ===';
GO
DECLARE @ret1 bit, @steps1 varchar(400), @ret2 bit, @steps2 varchar(400),
        @ret3 bit, @orders3 varchar(400), @ret4 bit, @orders4 varchar(400);

EXEC Demo.usp_RunUncaught N'
EXEC Demo.usp_Step ''before'';
RAISERROR(''E1'', 16, 1);
EXEC Demo.usp_Step ''after RAISERROR'';', @ret1 OUTPUT;
SET @steps1 = Demo.fn_Steps();

EXEC Demo.usp_RunUncaught N'
EXEC Demo.usp_Step ''before'';
THROW 50002, ''E2'', 1;
EXEC Demo.usp_Step ''after THROW'';', @ret2 OUTPUT;
SET @steps2 = Demo.fn_Steps();

-- With XACT_ABORT ON, inside a transaction.
EXEC Demo.usp_RunUncaught N'
SET XACT_ABORT ON;
BEGIN TRANSACTION;
    INSERT Demo.Orders (OrderID, Amount) VALUES (61, 10);
    RAISERROR(''E3'', 16, 1);
    INSERT Demo.Orders (OrderID, Amount) VALUES (62, 20);
COMMIT;', @ret3 OUTPUT;
SET @orders3 = Demo.fn_Orders();
DELETE Demo.Orders;

EXEC Demo.usp_RunUncaught N'
SET XACT_ABORT ON;
BEGIN TRANSACTION;
    INSERT Demo.Orders (OrderID, Amount) VALUES (71, 10);
    THROW 50004, ''E4'', 1;
    INSERT Demo.Orders (OrderID, Amount) VALUES (72, 20);
COMMIT;', @ret4 OUTPUT;
SET @orders4 = Demo.fn_Orders();
DELETE Demo.Orders;

INSERT Demo.Results (Scenario, Item, Value) VALUES
('E', 'RAISERROR severity 16: steps reached',                    @steps1),
('E', 'THROW: steps reached',                                    @steps2),
('E', 'XACT_ABORT ON, RAISERROR in a transaction: orders kept',  @orders3),
('E', 'XACT_ABORT ON, THROW in a transaction: orders kept',      @orders4);

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('E', 'RAISERROR reports an error and carries on with the next statement',
 @steps1, CASE WHEN @steps1 = 'before > after RAISERROR' AND @ret1 = 1 THEN 'CONFIRMED' ELSE 'unexpected' END),
('E', 'THROW stops the batch',
 @steps2, CASE WHEN @steps2 = 'before' AND @ret2 = 0 THEN 'CONFIRMED' ELSE 'unexpected' END),
('E', 'RAISERROR ignores XACT_ABORT ON: the transaction goes on and commits both orders',
 'orders: ' + @orders3, CASE WHEN @orders3 = '61,62' THEN 'CONFIRMED' ELSE 'unexpected' END),
('E', 'THROW honours XACT_ABORT ON: the transaction is rolled back',
 'orders: ' + @orders4, CASE WHEN @orders4 = '(none)' AND @ret4 = 0 THEN 'CONFIRMED' ELSE 'unexpected' END);
GO


/*==============================================================================
  Summary
==============================================================================*/
PRINT '';
PRINT '=== 1. EVERY ATTEMPT ===';
GO
SELECT Scenario, Item, Value FROM Demo.Results ORDER BY Seq;
GO

PRINT '';
PRINT '=== 2. VERDICTS ===';
GO
SELECT Scenario, Claim, Evidence, Verdict FROM Demo.Verdicts ORDER BY Scenario, Seq;
GO

PRINT '';
PRINT '=== 3. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===';
GO
SELECT Scenario, Claim, Evidence, Verdict FROM Demo.Verdicts
WHERE  Verdict IN ('unexpected', 'INCONCLUSIVE', 'SKIPPED') ORDER BY Scenario, Seq;
GO

PRINT '';
PRINT '========================================================';
PRINT ' DEMO COMPLETE.';
PRINT '';
PRINT ' Result set 3 should be EMPTY. Anything in it is a';
PRINT ' genuine difference on your build, worth reading before';
PRINT ' you trust the rest.';
PRINT '';
PRINT ' Then run 03-cleanup.sql.';
PRINT '========================================================';
GO
