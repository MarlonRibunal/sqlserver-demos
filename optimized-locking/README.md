# Optimized locking: fewer locks, less blocking, and what still waits

> **The short version:** [Optimized locking (SQL Server 2025)](https://marlonribunal.com/sqlserver-demos/optimized-locking/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

SQL Server 2025's optimized locking changes how writers lock. An updated
row is protected by its transaction's ID instead of a row lock held to the
end. Under `READ_COMMITTED_SNAPSHOT`, an `UPDATE` checks its `WHERE`
clause before it locks anything. This topic runs the same updates with it
off and on, counts the locks, and watches a second session to see what
still blocks.

## The rule these scenarios are built around

**Turn on optimized locking together with `READ_COMMITTED_SNAPSHOT`.
Without RCSI you get the smaller lock footprint but keep most of the
blocking. Writers that change the same row still wait for each other, and
the wait has a new name: `LCK_M_S_XACT_MODIFY`, on an `XACT` resource.**

## Prerequisites

- **SQL Server 2025 or later.** Developed and tested on **2025 RTM-CU8
  (17.0.4075.5)**, Linux container. On 2022 and earlier the scripts still
  run, and the demo reports every scenario as `SKIPPED`.
- No sample database. `01-setup.sql` creates its own database, `LockDemo`.
- Permission to `CREATE DATABASE`.

## What setup and the demo change on your instance

Nothing outside the database they create. Inside `LockDemo`:

- setup turns on **Accelerated Database Recovery**, which optimized locking
  requires, and **Service Broker**, for the demo's background session
- the demo switches **`OPTIMIZED_LOCKING`** and
  **`READ_COMMITTED_SNAPSHOT`** between three configurations, `WITH
  ROLLBACK IMMEDIATE` (anyone else connected to `LockDemo` is disconnected),
  and leaves both on

`03-cleanup.sql` drops the database and confirms that none of its files
remain.

## Run order

```
01-setup.sql     ~10 s     creates LockDemo: 100,000 orders
02-demo.sql      ~45 s     four scenarios, three configurations; prints a summary
03-cleanup.sql   seconds   drops LockDemo
```

Run each file whole (F5).

## How it measures

For the lock counts (A), the demo opens a transaction, updates the rows,
and reads its own locks from `sys.dm_tran_locks` before rolling back.

For blocking (B to D), a background session (Service Broker activation)
tries an update while the demo holds its own update open for 2 seconds. The
demo watches the background session in `sys.dm_os_waiting_tasks`, then
records how long its update took and what it waited on.

| configuration | `OPTIMIZED_LOCKING` | `READ_COMMITTED_SNAPSHOT` |
|---|---|---|
| 1 | OFF | ON |
| 2 | ON | ON |
| 3 | ON | OFF |

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2025 RTM-CU8.

### A — the locks an open `UPDATE` holds

| | 1,000 rows | 20,000 rows |
|---|---|---|
| 1: OFF | **1,000 `KEY X`**, 59 `PAGE IX`, `OBJECT IX` | **`OBJECT X`**: escalated to the whole table |
| 2: ON, RCSI | `XACT X`: 1, `OBJECT IX` | `XACT X`: 1, `OBJECT IX` |
| 3: ON, no RCSI | | `XACT X`: 1, `OBJECT IX` |

Without optimized locking, a transaction holds an exclusive lock on every
row it has changed, until it ends. Past about 5,000 locks on one table,
SQL Server swaps them for one table lock (see
[lock escalation](../lock-escalation/)). With it, each row is still locked
while it is changed, then let go. What protects the change until commit is
one lock on the transaction's ID (`XACT`), and each changed row carries
that ID. 20,000 rows held two locks. With so few locks there was nothing to
escalate. This part, TID locking, doesn't need RCSI (configuration 3).

### B — escalation blocks an unrelated row

The demo holds an update of orders 1 to 20,000; the background session
updates order 90,000:

| | the background update |
|---|---|
| 1: OFF | **blocked 2,132 ms** on `LCK_M_IX`, the escalated table lock, until the demo rolled back |
| 2: ON, RCSI | 0 ms |
| 3: ON, no RCSI | 0 ms |

### C — reading past a locked row: lock after qualification

The demo holds an update of order 1 (status `s1`). The background session
runs `UPDATE ... WHERE OrderID <= 1000 AND Status = 's2'`. `Status` has no
index, so the update reads all 1,000 rows, order 1 included, though order
1 doesn't qualify:

| | the background update |
|---|---|
| 1: OFF, RCSI | **blocked 2,133 ms** on `LCK_M_U`, order 1's key lock |
| 2: ON, RCSI | **0 ms**, 10 rows updated |
| 3: ON, no RCSI | **blocked 2,129 ms** on `LCK_M_S_XACT_MODIFY` |

Without optimized locking, an update takes an update (`U`) lock on every
row it reads, to check whether the row qualifies. RCSI doesn't change that:
it protects readers, not writers. **Lock after qualification** checks the
`WHERE` clause against the last committed version, with no lock, and only
locks the 10 rows that qualify. It needs RCSI. In configuration 3 the
update waited again, now on the demo's transaction ID.

This is the change most likely to remove blocking you have today: updates
and deletes whose `WHERE` clause isn't fully covered by an index, waiting
on rows they were never going to change.

### D — the same row still waits

Both sessions update order 1:

| | the background update |
|---|---|
| 1: OFF | blocked 2,117 ms on **`LCK_M_X`**, resource `keylock hobtid=...` |
| 2: ON, RCSI | blocked 2,154 ms on **`LCK_M_S_XACT_MODIFY`**, resource `xactlock xdesIdLow=... UnderlyingResource keylock ...` |

Optimized locking doesn't let two transactions change one row at once.
The second still waits for the first to finish. What changes is how the
wait looks: the resource is the other transaction (`xactlock`), not the
row. Blocking scripts and alerts that look for `KEY` or `PAGE` resources,
or for `LCK_M_X` and `LCK_M_U`, need to know about `XACT` too.
`blocking_session_id` still names the blocker.

## How to read the output

`02-demo.sql` prints three result sets:

1. every measurement: the locks held, and how each background update went
2. the verdicts, each with its evidence
3. **anything that didn't behave as predicted, which should be empty**
   on 2025 (on 2022 and earlier, the `SKIPPED` rows)

## Takeaways

1. **A transaction's locks no longer grow with its row count.** 20,000
   updated rows held 2 locks, and nothing escalated.
2. **Escalation stops blocking unrelated rows**: 2.1 s of waiting dropped
   to none.
3. **Lock after qualification removes blocking on rows an update only
   reads**, but only with `READ_COMMITTED_SNAPSHOT` on.
4. **Writers on the same row still wait**, as `LCK_M_S_XACT_MODIFY` on an
   `XACT` resource. Teach your blocking queries the new names.
5. **It needs Accelerated Database Recovery**, and with it, ADR's
   [version store costs](../accelerated-database-recovery/).

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the single
configuration named under [Prerequisites](#prerequisites), SQL Server 2025
RTM-CU8 (17.0.4075.5) in a Linux container, and nowhere else. No other version,
edition, platform, or configuration has been exercised, and the measured
numbers throughout this README are from that one instance rather than a
general result.

Run them only on a scratch instance you can afford to lose, and read every
script before you run it. You alone are responsible for reviewing, testing,
and deciding whether to run anything here.

To the fullest extent permitted by law, the author provides these scripts
WITHOUT WARRANTY OF ANY KIND, express or implied, and shall not be liable for
any claim, damages, data loss, service interruption, or other liability arising
from or in connection with their use. See the
[full disclaimer](../README.md#disclaimer).
