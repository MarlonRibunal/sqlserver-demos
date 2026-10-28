# Error handling in T-SQL: XACT_ABORT, TRY/CATCH, and what an error leaves behind

> **The short version:** [T-SQL error handling: XACT_ABORT and TRY/CATCH](https://marlonribunal.com/sqlserver-demos/error-handling/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

An order is saved without its lines. A nightly job reports success, and
half its work is missing. Usually nothing is wrong with the data or the
server: an error stopped one statement, and the rest of the transaction
carried on and committed. What an error does in T-SQL depends on the error,
on `XACT_ABORT`, on whether there's a `TRY` block, and on how many levels
up it is. This topic measures each case.

## The rule these scenarios are built around

**With `XACT_ABORT OFF`, most errors stop one statement, not the
transaction. Turn `XACT_ABORT ON`, wrap the work in `TRY`/`CATCH`, and in
`CATCH`, roll back if `XACT_STATE()` isn't 0, then rethrow with `THROW`.**

## Prerequisites

- **SQL Server 2017 or later** (the demo uses `STRING_AGG`). Developed and
  tested on **2025 RTM-CU10 (17.0.5035.5)** and **2022 RTM-CU25
  (16.0.4255.1)**, Linux containers; CI also runs it on 2019.
- No sample database. `01-setup.sql` creates its own database, `ErrorDemo`,
  with Service Broker enabled.
- Permission to `CREATE DATABASE`.

## What setup and the demo change on your instance

Nothing outside the database they create. Scenarios A, C and E raise errors
that nothing catches, in a background session (below), and **SQL Server
writes those errors to its error log**, as it does for any activation
procedure. `03-cleanup.sql` drops the database and confirms that none of its
files remain.

## Run order

```
01-setup.sql     seconds   creates ErrorDemo, its tables and the background session
02-demo.sql      ~25 s     five scenarios
03-cleanup.sql   seconds   drops ErrorDemo
```

Run each file whole (F5).

## How it's built

Some of the behaviour here only happens when **nothing** catches the error:
no `TRY` block anywhere, at any level. An uncaught error would also end the
demo script, so those batches run somewhere else: a Service Broker queue in
`ErrorDemo` whose activation procedure, `Demo.usp_Runner`, runs one batch
with `EXEC ()` and no error handling, then records that it got past it.
`Demo.usp_RunUncaught` sends it a batch and waits. The batches record the
steps they reach in `Demo.Steps`. The other scenarios run in the demo's own
session, inside `TRY`/`CATCH`.

## The scenarios, and what they showed

The results below come from the tested run on SQL Server 2025 RTM-CU10. 2022
gave the same results.

### A — no `TRY`/`CATCH`

```sql
BEGIN TRANSACTION;
    INSERT Demo.Orders (OrderID, Amount) VALUES (1, 10);
    INSERT Demo.Orders (OrderID, Amount) VALUES (1, 20);   -- duplicate key
    INSERT Demo.Orders (OrderID, Amount) VALUES (3, 30);
COMMIT;
```

| | steps reached | orders committed |
|---|---|---|
| `XACT_ABORT OFF` (the default) | insert 1 > insert 1 again > insert 3 > **committed** | **1, 3** |
| `XACT_ABORT ON` | stopped at the error | **none** |

With `XACT_ABORT OFF`, the duplicate key failed one statement. The next
statement ran, and `COMMIT` saved half the transaction. This is the
default, and how most inherited code runs.

### B — `TRY`/`CATCH`, and `XACT_STATE()`

| | `XACT_STATE()` in `CATCH` | then |
|---|---|---|
| `XACT_ABORT OFF`, duplicate key | **1**: committable | `COMMIT` in `CATCH` kept order 21, inserted before the error |
| `XACT_ABORT ON`, duplicate key | **-1**: doomed | `COMMIT` failed with **error 3930**; only `ROLLBACK` works |
| `XACT_ABORT OFF`, error `THROW`n in a trigger | **-1**: doomed | |

`TRY`/`CATCH` alone doesn't undo anything. With `XACT_ABORT OFF`, the
transaction is still committable in `CATCH`, so a `CATCH` block that commits,
or that forgets to roll back, keeps the partial work. **An error in a
trigger dooms the transaction even with `XACT_ABORT OFF`.**

### C — errors `TRY`/`CATCH` doesn't catch

| | result |
|---|---|
| `SELECT` from a table that doesn't exist, inside `TRY` | steps: **"in TRY" only**. `CATCH` never ran; nothing after the error in that batch ran. The caller one level up carried on. |
| the same `SELECT` one level down, in `EXEC ()`, inside `TRY` | **caught: error 208** |
| `RAISERROR(..., 10, 1)` inside `TRY` | **not caught**: severity 10 is a message |

A missing object is found when the statement is compiled, which for a table
that didn't exist when the batch started happens when the statement runs.
That error can't be caught by a `TRY` block at the same level. It's passed
to the caller, which can catch it. So a procedure's `TRY`/`CATCH` doesn't
protect it against a dropped or renamed table; the caller's does.

### D — a trigger written for one row

```sql
DECLARE @id int;
SELECT @id = OrderID FROM inserted;
INSERT Demo.OrderAudit (OrderID) VALUES (@id);
```

| trigger | audit rows for a 3-row `INSERT` |
|---|---|
| reads `inserted` into a variable | **1** |
| `INSERT ... SELECT OrderID FROM inserted` | 3 |

No error, just two orders without an audit row. A trigger fires once per
statement, and `inserted` holds every row that statement changed.

### E — `RAISERROR` and `THROW`

| | result |
|---|---|
| `RAISERROR(..., 16, 1)`, no `TRY` | **the next statement ran** |
| `THROW`, no `TRY` | **the batch stopped** |
| `XACT_ABORT ON`, `RAISERROR` inside a transaction | **both orders committed** |
| `XACT_ABORT ON`, `THROW` inside a transaction | rolled back |

`RAISERROR` reports an error and carries on, and it ignores `XACT_ABORT`.
Code that raises its own errors with `RAISERROR` and relies on `XACT_ABORT
ON` to roll back commits anyway. `THROW` stops the batch and honours
`XACT_ABORT`.

## How to read the output

`02-demo.sql` prints three result sets:

1. every measurement
2. the verdicts, each with its evidence
3. **anything that didn't behave as predicted, which should be empty**

It also prints the message from C3's `RAISERROR` with severity 10. That's
expected: such messages go through to the client.

## Traps from building this

- **"The batch stops" depends on which batch.** The first version of C
  expected the missing table to stop the background session's procedure
  too. It didn't: the error ended the inner batch run by `EXEC ()` and went
  to the procedure, which, having no `TRY`, carried on. That's the same
  rule as C2, seen from the other side.
- **Uncaught errors can't run in the demo script.** They'd end it. That's
  why the background session exists.

## Takeaways

1. **`SET XACT_ABORT ON`** in every procedure that opens a transaction.
2. **In `CATCH`: `IF XACT_STATE() <> 0 ROLLBACK;` then `THROW;`**, so the
   caller learns about the error.
3. **Use `THROW`, not `RAISERROR`, to raise errors** that must stop the
   work. `RAISERROR` carries on, even with `XACT_ABORT ON`.
4. **A missing object isn't caught at the same level.** Catch it in the
   caller.
5. **Write triggers for sets of rows.**

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the
configurations named under [Prerequisites](#prerequisites), SQL Server 2025
RTM-CU10 (17.0.5035.5) and 2022 RTM-CU25 (16.0.4255.1) in Linux containers,
and nowhere else. No other version, edition, platform, or configuration has
been exercised, and the measured numbers throughout this README are from
those instances rather than a general result.

Run them only on a scratch instance you can afford to lose, and read every
script before you run it. You alone are responsible for reviewing, testing,
and deciding whether to run anything here.

To the fullest extent permitted by law, the author provides these scripts
WITHOUT WARRANTY OF ANY KIND, express or implied, and shall not be liable for
any claim, damages, data loss, service interruption, or other liability arising
from or in connection with their use. See the
[full disclaimer](../README.md#disclaimer).

These scripts and this README were written with the help of AI. The results
come from running the scripts on SQL Server, not from the AI. See
[how this was made](../README.md#how-this-was-made).
