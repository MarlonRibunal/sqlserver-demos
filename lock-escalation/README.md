# Lock escalation: the threshold, and what does and doesn't avoid it

> **The short version:** [Lock escalation](https://marlonribunal.com/sqlserver-demos/lock-escalation/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

When a statement takes enough row locks, SQL Server swaps them for a single
lock on the whole table. It's cheaper for the lock manager, and every other
session is locked out of every row until the transaction ends. Five scenarios
measure where that happens and which of the usual remedies work, all from one
session, by reading the session's own locks out of `sys.dm_tran_locks`.

## The rule these scenarios are built around

**Escalation is decided per statement, by lock count. Change the count (batch
the work, lock pages, partition the table), not the hint.**

## Prerequisites

- SQL Server 2016 or later. Developed and tested on **2022 CU25
  (16.0.4255.1)**. Partitioning is available in every edition from 2016 SP1.
- No sample database. `01-setup.sql` creates its own database,
  `LockEscalationDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` for
  `sys.dm_tran_locks`.
- The server setting `locks` at its default of 0. Setup prints it. A fixed
  lock count changes how escalation is triggered.
- **A quiet instance.** Another session holding locks on these tables would
  change the results. Nothing outside the demo database uses them.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set. Trace flags 1211 and 1224 change escalation for the
  whole instance; they're discussed below and never used.
- no existing database touched

`LOCK_ESCALATION` is a table option, set only on tables the demo creates.
Every probe rolls back, so no data changes and no locks are left behind.
`03-cleanup.sql` drops the database and confirms that none of its files remain.

## Run order

```
01-setup.sql     ~5 s      creates LockEscalationDemo, three 100,000-row tables
02-demo.sql      ~3 s      about 50 probes; prints a summary
03-cleanup.sql   seconds   drops LockEscalationDemo
```

Run each file whole (F5). `02-demo.sql` can be re-run without re-running setup.

## How it's built

`Demo.usp_Probe` runs one statement inside a transaction, reads every lock the
session holds in the demo database, then **rolls back**. A session can see its
own locks while its transaction is open, so no second connection is needed to
see what escalation did. The escalation count comes separately from
`index_lock_promotion_count` in `sys.dm_db_index_operational_stats`: SQL
Server's own record, independent of the lock list.

One detail: the probe captures the locks into a **table variable** before the
rollback. A row written to a real table inside the transaction would roll back
with everything else. Table variables ignore `ROLLBACK`, the one case
[the tempdb topic](../tempdb/) shows where that's exactly what you want.

The three tables hold the same 100,000 rows, about 37 per page:

| table | `LOCK_ESCALATION` | partitions |
|---|---|---|
| `Demo.Items` | `TABLE` (the default) | 1 |
| `Demo.ItemsDisabled` | `DISABLE` | 1 |
| `Demo.ItemsPartitioned` | `AUTO` | 4 × 25,000 rows |

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25, 8 schedulers.

### A — the threshold

`UPDATE` the first *N* rows and look at what the session holds:

| rows updated | key locks | page locks | table lock | total locks | escalations |
|---|---|---|---|---|---|
| 5,000 | 5,000 | 136 | IX | 5,137 | 0 |
| 6,000 | 6,000 | 163 | IX | 6,164 | 0 |
| 6,080 | 6,080 | 165 | IX | **6,246** | 0 |
| **6,090** | 0 | 0 | **X** | **1** | **1** |
| 7,000 | 0 | 0 | X | 1 | 1 |
| `DELETE` 7,000 | 0 | 0 | X | 1 | 1 |

Below the line, the session holds one key lock per row, an intent lock on each
page, and an intent lock (IX) on the table. Above it, it holds **one exclusive
lock on the whole table** and nothing else.

The documented threshold is 5,000 locks. On the tested build the first
escalation came once the statement held more than **6,250**: no escalation at
6,246 locks, escalation at 6,090 rows, which would have been 6,256. 6,250 is
exactly 5,000 + 1,250, and 1,250 is the documented interval at which
escalation is re-checked. But the demo measures the boundary; it doesn't
explain it. Treat "about 5,000" as the order of magnitude, not a line you can
work up to.

### B — per statement, not per transaction

| | key locks | total locks | escalations |
|---|---|---|---|
| four `UPDATE`s of 5,000 rows each, **one transaction** | 20,000 | **20,542** | **0** |

Each statement stays under the threshold, so none escalates, even though the
transaction ends up holding over 20,000 locks. That's why batching works. A
purge that deletes 5,000 rows per statement never escalates, whether or not
it commits between batches. (Commit between batches anyway: it releases the
locks, and the log can truncate.)

### C — hints

| | key locks | page locks | table lock | escalations |
|---|---|---|---|---|
| `UPDATE ... WITH (ROWLOCK)`, 7,000 rows | 0 | 0 | **X** | **1** |
| `UPDATE ... WITH (PAGLOCK)`, 7,000 rows | 0 | 190 | IX | 0 |

**`ROWLOCK` does not prevent escalation.** It sets the granularity a statement
*starts* with. 7,000 row locks are still over the threshold, and the statement
escalates exactly as it would without the hint.

`PAGLOCK` avoids escalation by taking one lock per page instead of one per
row: 190 locks for 7,000 rows. The price is coarser locking from the start:
every row on a locked page is unavailable, not just the ones being updated.

### D — readers escalate too

| | table lock | total locks | escalations |
|---|---|---|---|
| `SELECT` 50,000 rows, `READ COMMITTED` | — | **0** | 0 |
| `SELECT` 7,000 rows `WITH (REPEATABLEREAD)` | **S** | 1 | **1** |

Under the default `READ COMMITTED`, a reader releases each shared lock as it
moves on, holds nothing afterwards, and never gets near the threshold. Under
`REPEATABLE READ`, `SERIALIZABLE` or a `HOLDLOCK` hint, shared locks are
**kept** until the transaction ends, so a reader can escalate. The result is a
shared lock on the whole table: other readers are fine, but no session can
modify any row until the reader commits.

### E — the table option

| | key locks | table lock | partition locks | escalations |
|---|---|---|---|---|
| `DISABLE`, 20,000 rows | 20,000 (20,542 total) | IX | — | 0 |
| `AUTO`, partitioned, 20,000 rows in one partition | 0 | **IX** | **1 × X** | 1 |
| `AUTO`, partitioned, 20,000 rows across two partitions | 0 | **IX** | **2 × X** | 2 |

`ALTER TABLE ... SET (LOCK_ESCALATION = DISABLE)` keeps every row lock. That
preserves concurrency and spends lock memory instead (the documentation puts
each lock at 96 bytes). That is fine at 20,000 locks and not at 20 million.
(Escalation can still happen in rare cases, such as a table hint that requires
it.)

`LOCK_ESCALATION = AUTO` on a **partitioned** table escalates to the
**partition** (a HOBT lock) instead of the table. The table keeps only an
intent lock, so rows in the other partitions stay available. An update that
spans two partitions escalates each of them separately. On a table that isn't
partitioned, `AUTO` behaves like `TABLE`.

## What escalation costs, and why there's no second session here

The table-level X lock in scenario A means any other session that wants to
read (under locking isolation) or write **any** row of `Demo.Items` waits
until this transaction ends. That blocking is the real cost of escalation.

Staging it needs two sessions running at once, which a single unattended
script can't do. The demo shows the lock that causes the blocking. To see the
blocking itself:

1. Run scenario A's 7,000-row `UPDATE` in a `BEGIN TRAN` without committing.
2. In a second window, `SELECT * FROM Demo.Items WHERE ItemID = 99999`, a row
   the first session never touched.
3. It waits until the first window rolls back.

If the database uses `READ_COMMITTED_SNAPSHOT`, step 2 doesn't wait: readers
use row versions instead of shared locks. Writers still block each other.

## Trace flags 1211 and 1224

Trace flag 1211 disables escalation for the whole instance, and 1224 disables
it except under lock-memory pressure. Both are instance-wide, which is why
this demo uses the per-table option instead and why you usually should too.

## Takeaways

1. **Escalation trades thousands of row locks for one table lock**, and with
   it the whole table's concurrency, until the transaction ends.
2. **It's per statement.** Four 5,000-row statements held 20,542 locks in one
   transaction and never escalated. Batch big modifications.
3. **The boundary on the tested build was 6,250 locks, not 5,000.** Don't
   design to an exact number; stay well under it.
4. **`ROWLOCK` does not prevent escalation.** It escalated at 7,000 rows
   exactly as without the hint.
5. **Readers escalate under `REPEATABLE READ` and `SERIALIZABLE`**, to a
   shared table lock that blocks every writer.
6. **Per table, `LOCK_ESCALATION = DISABLE` stops it, at the cost of lock
   memory. `AUTO` on a partitioned table escalates to the partition only.**

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the single
configuration named under [Prerequisites](#prerequisites), SQL Server 2022 CU25
(16.0.4255.1) on 8 schedulers, and nowhere else. No other version, edition, or
configuration has been exercised, and the measured numbers throughout this
README are from that one instance rather than a general result.

Run them only on a scratch instance you can afford to lose, and read every
script before you run it. You alone are responsible for reviewing, testing,
and deciding whether to run anything here.

To the fullest extent permitted by law, the author provides these scripts
WITHOUT WARRANTY OF ANY KIND, express or implied, and shall not be liable for
any claim, damages, data loss, service interruption, or other liability arising
from or in connection with their use. See the
[full disclaimer](../README.md#disclaimer).
