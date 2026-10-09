# RCSI and snapshot isolation: readers, writers, and the version store

Under the default isolation level, a reader waits for a writer. `NOLOCK`
"fixes" that by reading data that may never have existed. Read Committed
Snapshot Isolation (RCSI) fixes it properly. Snapshot isolation goes further,
and both have a price. Six scenarios measure all of it, including the
blocking, from one unattended script.

## The rule these scenarios are built around

**RCSI stops readers waiting for writers without dirty reads; it doesn't stop
writers waiting for writers. SNAPSHOT adds a consistent view for the whole
transaction, and update conflicts you have to handle. Both cost 14 bytes a row
and space in tempdb.**

## Prerequisites

- SQL Server 2016 or later. Developed and tested on **2022 CU25
  (16.0.4255.1)**, Linux container.
- No sample database. `01-setup.sql` creates its own database,
  `IsolationDemo`.
- Permission to `CREATE DATABASE` and to alter it, and `VIEW SERVER STATE` for
  the DMVs.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched

Inside `IsolationDemo`, setup turns on Service Broker (`ENABLE_BROKER`), and
the demo turns `READ_COMMITTED_SNAPSHOT` and `ALLOW_SNAPSHOT_ISOLATION` on and
back off. The version store those options use lives in **tempdb**, which every
database shares; scenario F puts about 20 MB there briefly, and the engine
cleans it up. `03-cleanup.sql` drops the database and confirms that none of
its files remain.

## Run order

```
01-setup.sql     seconds   creates IsolationDemo, the background writer, its queue
02-demo.sql      ~25 s     six scenarios; prints a summary
03-cleanup.sql   seconds   drops IsolationDemo
```

Run each file whole (F5). **No second window is needed** (see below).
Most of the 25 seconds is the writer holding its lock on purpose.

## How it's built: a second session from one script

Blocking needs two sessions, one holding a lock and one waiting for it. A
single script can't be two sessions, except that **Service Broker activation**
runs a procedure in a background session of its own when a message arrives on
a queue.

`Demo.usp_Writer` is that procedure. The demo sends it a command, and it
updates account 1 in its own session:

| command | what the writer does |
|---|---|
| `HOLD_COMMIT:<ms>` | add 100, hold the lock for *ms*, commit |
| `HOLD_ROLLBACK:<ms>` | add 100, hold, roll back |
| `DELAY_COMMIT:<ms>` | wait *ms*, then add 100 and commit at once |

Meanwhile the demo reads account 1 under each isolation level and times how
long it waited. No second window, no SQL Agent. The results record the
writer's session id alongside the script's, so you can see they're different.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25. Account 1
starts at 1,000. The writer adds 100.

| scenario | waited | read | |
|---|---|---|---|
| **A** locking `READ COMMITTED`, writer holds 2 s then commits | **1,966 ms** | 1,100 | blocked |
| **B** `WITH (NOLOCK)`, writer holds then **rolls back** | 0 ms | **1,100** | a value that never existed |
| **C1** RCSI, writer holds | **0 ms** | **1,000** | the last committed value |
| **C2** RCSI, a **second writer** on the same row | **1,962 ms** | 1,050 | writers still block |

### A — locking READ COMMITTED

The default. The reader needs a shared lock on the row, the writer holds an
exclusive one, and the reader waits about 2 seconds until the writer commits.
It then reads the new value, 1,100.

### B — NOLOCK

The writer rolls back this time, and the reader uses `WITH (NOLOCK)`. No wait,
but the reader saw **1,100**, a balance that was rolled back and never
existed. That's a dirty read, and it's what `NOLOCK` means. It's not a
performance hint.

### C — READ_COMMITTED_SNAPSHOT

With RCSI on, `READ COMMITTED` reads **row versions**: the last committed
value, kept in tempdb, instead of taking shared locks. The same reader against
the same writer doesn't wait, and reads **1,000**, the last *committed*
balance, not the uncommitted 1,100 that `NOLOCK` showed.

But a second **writer** still waits, 1,962 ms here, then applies its change to
the latest committed row: +100 − 50 = 1,050. RCSI takes readers out of the
blocking picture, not writers.

### D — RCSI vs SNAPSHOT

The same experiment under each: begin a transaction, read, let the writer add
100 and commit, read again.

| | first read | second read |
|---|---|---|
| RCSI | 1,000 | **1,100**: each statement sees the latest committed data |
| SNAPSHOT | 1,000 | **1,000**: the whole transaction sees its starting point |

RCSI is statement-level consistency, and SNAPSHOT is transaction-level. Use
SNAPSHOT for a report that must add up across several queries.

### E — the update conflict

A SNAPSHOT transaction reads account 1, the writer changes it and commits, and
then the snapshot transaction tries to update the row:

```
Msg 3960: Snapshot isolation transaction aborted due to update conflict. ...
```

It would have overwritten a change it never saw, so SQL Server refuses and
rolls the transaction back, and the writer's change survives. Code that writes
under SNAPSHOT has to catch 3960 and retry. RCSI has no such check: as C2
showed, an update just waits for the lock and applies to the latest row.

### F — the cost

The same 200,000-row update on two identical tables:

| | row size | pages | version store (tempdb) |
|---|---|---|---|
| versioning off | 35 → 35 bytes | 99.6% → 99.6% full | 0 KB |
| RCSI on | 35 → **49 bytes** | 99.6% → **68.7% full** | **19,456 KB** |

Every row modified while versioning is on gets a **14-byte** versioning tag.
These pages were full, so growing every row split them. And every update
copied the old row into the **version store in tempdb**, shared by every
database on the instance, until no transaction could need it. A long-running
SNAPSHOT transaction keeps that store from being cleaned up.

A row *inserted* while versioning is on carries the tag from birth. That's why
the demo loads these two tables with versioning off. The first version of
this scenario didn't, and both tables started at 49 bytes.

## Traps from building this

- **`SEND` is transactional.** A Service Broker message sent inside an open
  transaction isn't delivered until that transaction commits. Scenarios D and
  E send the writer a delayed command *before* opening their transaction.
- **Don't write in a helper called inside someone else's transaction.** The
  first version of `usp_Writer_Start` reset a status row with an `UPDATE`.
  Called inside scenario D's transaction, that lock blocked the very writer it
  was waiting for. The helpers now only read, `WITH (NOLOCK)`, which is the
  one place this topic uses it on purpose.
- **`WAITFOR DELAY` rejects `CONVERT(..., 114)` strings** (`00:00:02:000`, a
  colon before the milliseconds). Inside an activation procedure, that error
  goes nowhere visible. Pass a `datetime` variable.

## How to read the output

`02-demo.sql` prints two result sets: every scenario with how long it waited,
what it read and its verdict, and **anything that didn't behave as predicted,
which should be empty.** Another session working in `IsolationDemo` during the
run would show up there.

## Takeaways

1. **Locking `READ COMMITTED` makes readers wait for writers**, 2 seconds
   here, for as long as the writer holds its lock.
2. **`NOLOCK` doesn't wait and reads uncommitted data**: a value that was
   then rolled back.
3. **RCSI doesn't wait either, and reads the last committed value.** It's what
   people usually want when they reach for `NOLOCK`.
4. **Writers still block writers under RCSI.**
5. **SNAPSHOT gives a whole transaction one consistent view, and raises
   Msg 3960 on an update conflict.** Retry.
6. **Versioning costs 14 bytes per modified row (page splits on full pages)
   and space in tempdb's version store**: 19 MB for a 200,000-row update.

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the single
configuration named under [Prerequisites](#prerequisites), SQL Server 2022 CU25
(16.0.4255.1) in a Linux container, and nowhere else. No other version,
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
