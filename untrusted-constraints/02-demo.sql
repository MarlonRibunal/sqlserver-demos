/*==============================================================================
  02-demo.sql           RUN AFTER 01-setup.sql. Run the whole file (F5).
  ----------------------------------------------------------------------------
  Untrusted constraints: a foreign key or CHECK constraint that is enabled,
  but that SQL Server doesn't trust, and the plans that costs.

     A  trusted: the join is removed, and an impossible filter reads nothing
     B  NOCHECK, then CHECK again: enabled, still not trusted
     C  two more ways a constraint starts out untrusted
     D  making it trusted again, when a bad row got in
     E  what WITH CHECK CHECK locks while it validates

  WHAT THIS CHANGES: only UntrustedDemo. It disables, re-enables, drops and
  re-adds the two constraints on Demo.Orders, and inserts and deletes one
  order. It leaves both constraints trusted.

  TESTED end to end on SQL Server 2025 RTM-CU10 (17.0.5035.5) and 2022
  RTM-CU25 (16.0.4255.1), Linux containers.
==============================================================================*/

USE UntrustedDemo;
GO
SET NOCOUNT ON;
GO

TRUNCATE TABLE Demo.Results;
TRUNCATE TABLE Demo.Verdicts;
GO

-- Start from trusted constraints and no bad rows, whatever a previous run
-- left behind.
DELETE Demo.Orders WHERE OrderID > 500000;
IF OBJECT_ID('Demo.FK_Orders_Customers') IS NOT NULL
    ALTER TABLE Demo.Orders DROP CONSTRAINT FK_Orders_Customers;
IF OBJECT_ID('Demo.CK_Orders_Status') IS NOT NULL
    ALTER TABLE Demo.Orders DROP CONSTRAINT CK_Orders_Status;
ALTER TABLE Demo.Orders ADD CONSTRAINT FK_Orders_Customers
    FOREIGN KEY (CustomerID) REFERENCES Demo.Customers (CustomerID);
ALTER TABLE Demo.Orders ADD CONSTRAINT CK_Orders_Status CHECK (Status BETWEEN 0 AND 3);
GO


/*==============================================================================
  A. Both constraints trusted.
==============================================================================*/
PRINT '=== A. trusted constraints ===';
GO
DECLARE @jc bit, @jo bit, @jr bigint, @cc bit, @co bit, @cr bigint;
EXEC Demo.usp_Run N'Demo.q_Join',  @jc OUTPUT, @jo OUTPUT, @jr OUTPUT;
EXEC Demo.usp_Run N'Demo.q_Check', @cc OUTPUT, @co OUTPUT, @cr OUTPUT;

INSERT Demo.Results (Scenario, Item, Value) VALUES
('A', 'FK_Orders_Customers',                       Demo.fn_State(N'FK_Orders_Customers')),
('A', 'CK_Orders_Status',                          Demo.fn_State(N'CK_Orders_Status')),
('A', 'q_Join: plan reads Demo.Customers',         CASE @jc WHEN 1 THEN 'yes' ELSE 'no' END),
('A', 'q_Join: logical reads',                     CAST(@jr AS varchar(20))),
('A', 'q_Check (Status = 7): plan reads Demo.Orders', CASE @co WHEN 1 THEN 'yes' ELSE 'no' END),
('A', 'q_Check: logical reads',                    CAST(@cr AS varchar(20)));

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('A', 'a trusted foreign key lets the optimizer remove the join: Demo.Customers is not read',
 'Customers in plan: ' + CASE @jc WHEN 1 THEN 'yes' ELSE 'no' END + ', ' + CAST(@jr AS varchar(20)) + ' reads',
 CASE WHEN @jc = 0 AND @jo = 1 THEN 'CONFIRMED' ELSE 'unexpected' END),
('A', 'a trusted CHECK constraint makes Status = 7 impossible: Demo.Orders is not in the plan',
 'Orders in plan: ' + CASE @co WHEN 1 THEN 'yes' ELSE 'no' END + ', ' + CAST(@cr AS varchar(20)) + ' reads',
 CASE WHEN @co = 0 THEN 'CONFIRMED' ELSE 'unexpected' END);
GO


/*==============================================================================
  B. Disable both constraints, then enable them again the way most people
  do: CHECK CONSTRAINT, without WITH CHECK. The rows already in the table
  are not checked, so SQL Server can't trust the constraint any more.
==============================================================================*/
PRINT '=== B. NOCHECK, then CHECK ===';
GO
ALTER TABLE Demo.Orders NOCHECK CONSTRAINT FK_Orders_Customers, CK_Orders_Status;
ALTER TABLE Demo.Orders CHECK CONSTRAINT FK_Orders_Customers, CK_Orders_Status;
GO
DECLARE @jc bit, @jo bit, @jr bigint, @cc bit, @co bit, @cr bigint,
        @fk varchar(60) = Demo.fn_State(N'FK_Orders_Customers'),
        @ck varchar(60) = Demo.fn_State(N'CK_Orders_Status');
EXEC Demo.usp_Run N'Demo.q_Join',  @jc OUTPUT, @jo OUTPUT, @jr OUTPUT;
EXEC Demo.usp_Run N'Demo.q_Check', @cc OUTPUT, @co OUTPUT, @cr OUTPUT;

INSERT Demo.Results (Scenario, Item, Value) VALUES
('B', 'FK_Orders_Customers',                       @fk),
('B', 'CK_Orders_Status',                          @ck),
('B', 'q_Join: plan reads Demo.Customers',         CASE @jc WHEN 1 THEN 'yes' ELSE 'no' END),
('B', 'q_Join: logical reads',                     CAST(@jr AS varchar(20))),
('B', 'q_Check (Status = 7): plan reads Demo.Orders', CASE @co WHEN 1 THEN 'yes' ELSE 'no' END),
('B', 'q_Check: logical reads',                    CAST(@cr AS varchar(20)));

DECLARE @ajr varchar(20) = (SELECT Value FROM Demo.Results WHERE Scenario = 'A' AND Item = 'q_Join: logical reads');

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('B', 'after NOCHECK then CHECK, both constraints are enabled but not trusted',
 'FK ' + @fk + '; CHECK ' + @ck,
 CASE WHEN @fk = 'enabled, NOT trusted' AND @ck = 'enabled, NOT trusted' THEN 'CONFIRMED' ELSE 'unexpected' END),
('B', 'the untrusted foreign key: the join is back, and Demo.Customers is read',
 'Customers in plan: ' + CASE @jc WHEN 1 THEN 'yes' ELSE 'no' END + ', ' + CAST(@jr AS varchar(20)) + ' reads (trusted: ' + @ajr + ')',
 CASE WHEN @jc = 1 AND @jr > CAST(@ajr AS bigint) THEN 'CONFIRMED' ELSE 'unexpected' END),
('B', 'the untrusted CHECK constraint: Status = 7 scans Demo.Orders',
 'Orders in plan: ' + CASE @co WHEN 1 THEN 'yes' ELSE 'no' END + ', ' + CAST(@cr AS varchar(20)) + ' reads (trusted: '
 + (SELECT Value FROM Demo.Results WHERE Scenario = 'A' AND Item = 'q_Check: logical reads') + ')',
 CASE WHEN @co = 1 AND @cr > 1000 THEN 'CONFIRMED' ELSE 'unexpected' END);
GO


/*==============================================================================
  C. Two more ways to end up with an untrusted constraint:
     - adding it WITH NOCHECK, so existing rows aren't checked
     - NOT FOR REPLICATION, which SQL Server never trusts, even after a
       successful WITH CHECK CHECK
==============================================================================*/
PRINT '=== C. born untrusted ===';
GO
ALTER TABLE Demo.Orders DROP CONSTRAINT FK_Orders_Customers;
ALTER TABLE Demo.Orders WITH NOCHECK ADD CONSTRAINT FK_Orders_Customers
    FOREIGN KEY (CustomerID) REFERENCES Demo.Customers (CustomerID);
GO
DECLARE @nocheck varchar(60) = Demo.fn_State(N'FK_Orders_Customers');

ALTER TABLE Demo.Orders DROP CONSTRAINT FK_Orders_Customers;
ALTER TABLE Demo.Orders ADD CONSTRAINT FK_Orders_Customers
    FOREIGN KEY (CustomerID) REFERENCES Demo.Customers (CustomerID) NOT FOR REPLICATION;
ALTER TABLE Demo.Orders WITH CHECK CHECK CONSTRAINT FK_Orders_Customers;
DECLARE @nfr varchar(60) = Demo.fn_State(N'FK_Orders_Customers');
DECLARE @jc bit, @jo bit, @jr bigint;
EXEC Demo.usp_Run N'Demo.q_Join', @jc OUTPUT, @jo OUTPUT, @jr OUTPUT;

INSERT Demo.Results (Scenario, Item, Value) VALUES
('C', 'added WITH NOCHECK',                                   @nocheck),
('C', 'added NOT FOR REPLICATION, then WITH CHECK CHECK',     @nfr),
('C', 'NOT FOR REPLICATION: q_Join plan reads Demo.Customers', CASE @jc WHEN 1 THEN 'yes' ELSE 'no' END);

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('C', 'a constraint added WITH NOCHECK starts out not trusted',
 @nocheck, CASE WHEN @nocheck = 'enabled, NOT trusted' THEN 'CONFIRMED' ELSE 'unexpected' END),
('C', 'NOT FOR REPLICATION is never trusted, even after WITH CHECK CHECK, and the join stays',
 @nfr + '; Customers in plan: ' + CASE @jc WHEN 1 THEN 'yes' ELSE 'no' END,
 CASE WHEN @nfr = 'enabled, NOT trusted' AND @jc = 1 THEN 'CONFIRMED' ELSE 'unexpected' END);

-- Back to an ordinary foreign key, not trusted, for D.
ALTER TABLE Demo.Orders DROP CONSTRAINT FK_Orders_Customers;
ALTER TABLE Demo.Orders WITH NOCHECK ADD CONSTRAINT FK_Orders_Customers
    FOREIGN KEY (CustomerID) REFERENCES Demo.Customers (CustomerID);
GO


/*==============================================================================
  D. While the foreign key was disabled, an order for a customer that
  doesn't exist got in. Making the key trusted again has to check every row,
  and that row stops it.
==============================================================================*/
PRINT '=== D. re-trusting, with a bad row ===';
GO
ALTER TABLE Demo.Orders NOCHECK CONSTRAINT FK_Orders_Customers;
INSERT Demo.Orders (OrderID, CustomerID, Status, Amount) VALUES (500001, 999999, 1, 50);
ALTER TABLE Demo.Orders CHECK CONSTRAINT FK_Orders_Customers;
GO
DECLARE @e int = 0, @orphans int, @joined bigint, @all bigint;

-- The untrusted key gives the honest answer: the join drops the bad order.
SELECT @joined = COUNT_BIG(*) FROM Demo.Orders AS o JOIN Demo.Customers AS c ON c.CustomerID = o.CustomerID;
SELECT @all = COUNT_BIG(*) FROM Demo.Orders;

BEGIN TRY
    ALTER TABLE Demo.Orders WITH CHECK CHECK CONSTRAINT FK_Orders_Customers;
END TRY
BEGIN CATCH
    SET @e = ERROR_NUMBER();
END CATCH

-- Find the rows that break it, and remove them.
SELECT @orphans = COUNT(*)
FROM   Demo.Orders AS o
WHERE  NOT EXISTS (SELECT 1 FROM Demo.Customers AS c WHERE c.CustomerID = o.CustomerID);
DELETE o
FROM   Demo.Orders AS o
WHERE  NOT EXISTS (SELECT 1 FROM Demo.Customers AS c WHERE c.CustomerID = o.CustomerID);

ALTER TABLE Demo.Orders WITH CHECK CHECK CONSTRAINT FK_Orders_Customers;
DECLARE @after varchar(60) = Demo.fn_State(N'FK_Orders_Customers');
DECLARE @jc bit, @jo bit, @jr bigint;
EXEC Demo.usp_Run N'Demo.q_Join', @jc OUTPUT, @jo OUTPUT, @jr OUTPUT;

INSERT Demo.Results (Scenario, Item, Value) VALUES
('D', 'orders, all / joined to a customer',            CAST(@all AS varchar(20)) + ' / ' + CAST(@joined AS varchar(20))),
('D', 'WITH CHECK CHECK CONSTRAINT, bad row present',  CASE @e WHEN 0 THEN 'succeeded' ELSE 'error ' + CAST(@e AS varchar(10)) END),
('D', 'orders without a customer, found and deleted',  CAST(@orphans AS varchar(20))),
('D', 'after WITH CHECK CHECK CONSTRAINT',             @after),
('D', 'q_Join: plan reads Demo.Customers',             CASE @jc WHEN 1 THEN 'yes' ELSE 'no' END);

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('D', 'while untrusted, the join is what keeps the bad order out of the total',
 CAST(@all AS varchar(20)) + ' orders, ' + CAST(@joined AS varchar(20)) + ' with a customer',
 CASE WHEN @all = @joined + 1 THEN 'CONFIRMED' ELSE 'unexpected' END),
('D', 'WITH CHECK CHECK fails with error 547 while a bad row exists',
 CASE @e WHEN 0 THEN 'succeeded' ELSE 'error ' + CAST(@e AS varchar(10)) END,
 CASE WHEN @e = 547 THEN 'CONFIRMED' ELSE 'unexpected' END),
('D', 'with the bad row deleted, WITH CHECK CHECK makes the key trusted, and the join is removed again',
 @after + '; Customers in plan: ' + CASE @jc WHEN 1 THEN 'yes' ELSE 'no' END,
 CASE WHEN @after = 'enabled, trusted' AND @jc = 0 THEN 'CONFIRMED' ELSE 'unexpected' END);
GO


/*==============================================================================
  E. What WITH CHECK CHECK holds while it validates. Inside a transaction,
  so the locks can be read before they are released; rolled back, so the
  key ends untrusted, and then re-trusted for good at the end.
==============================================================================*/
PRINT '=== E. the locks WITH CHECK CHECK takes ===';
GO
ALTER TABLE Demo.Orders NOCHECK CONSTRAINT FK_Orders_Customers;
ALTER TABLE Demo.Orders CHECK CONSTRAINT FK_Orders_Customers;
GO
DECLARE @r0 bigint, @r1 bigint, @orders varchar(20), @customers varchar(20);

BEGIN TRANSACTION;
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
ALTER TABLE Demo.Orders WITH CHECK CHECK CONSTRAINT FK_Orders_Customers;
SELECT @r1 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;

SELECT @orders    = MAX(CASE WHEN resource_associated_entity_id = OBJECT_ID(N'Demo.Orders')    THEN request_mode END),
       @customers = MAX(CASE WHEN resource_associated_entity_id = OBJECT_ID(N'Demo.Customers') THEN request_mode END)
FROM   sys.dm_tran_locks
WHERE  request_session_id = @@SPID AND resource_type = 'OBJECT' AND resource_database_id = DB_ID();
ROLLBACK;

INSERT Demo.Results (Scenario, Item, Value) VALUES
('E', 'lock held on Demo.Orders during WITH CHECK CHECK',    @orders),
('E', 'lock held on Demo.Customers during WITH CHECK CHECK', @customers),
('E', 'logical reads to validate 500,000 orders',            CAST(@r1 - @r0 AS varchar(20)));

INSERT Demo.Verdicts (Scenario, Claim, Evidence, Verdict) VALUES
('E', 'WITH CHECK CHECK holds a schema modification (Sch-M) lock on both tables until it commits',
 'Orders ' + ISNULL(@orders, 'none') + ', Customers ' + ISNULL(@customers, 'none'),
 CASE WHEN @orders = 'Sch-M' AND @customers = 'Sch-M' THEN 'CONFIRMED' ELSE 'unexpected' END);

-- Leave the key trusted.
ALTER TABLE Demo.Orders WITH CHECK CHECK CONSTRAINT FK_Orders_Customers;
ALTER TABLE Demo.Orders WITH CHECK CHECK CONSTRAINT CK_Orders_Status;
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
