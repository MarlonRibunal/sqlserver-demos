# Deadlock patterns: making them on cue, fixing them, and reading the graphs

> **The short version:** [Deadlock patterns](https://marlonribunal.com/sqlserver-demos/deadlock-patterns/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

`Msg 1205: Transaction was deadlocked on lock resources with another process
and has been chosen as the deadlock victim.` Most deadlocks in real systems
are one of a handful of patterns. This topic makes each one happen on cue
between two sessions, shows the change that stops it, and then reads back
the deadlock graphs SQL Server already recorded, with no trace flag and
nothing to switch on.

## The rule these scenarios are built around

**A deadlock is two sessions taking the same locks in opposite orders. Take
them in the same order, take the strongest lock you'll need first, or don't
take the second lock at all. Then, because you can't rule deadlocks out
everywhere, retry on 1205.**

## Prerequisites

- SQL Server 2017 or later (scenario G reads `timestamp_utc` from
  `sys.fn_xe_file_target_read_file`). Developed and tested on **2022 CU25
  (16.0.4255.1)**, Linux container.
- No sample database. `01-setup.sql` creates its own database, `DeadlockDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` to read
  `system_health`.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set (not 1204, not 1222)
- no Extended Events session created; the demo only reads the built-in
  `system_health` session
- no existing database touched

Setup turns on Service Broker in `DeadlockDemo` for the background worker.
The demo's deadlocks are added to `system_health`'s event file, as every
deadlock on the instance is. `03-cleanup.sql` drops the database and
confirms that none of its files remain.

## Run order

```
01-setup.sql     seconds         creates DeadlockDemo, the background worker
02-demo.sql      ~1-3 minutes    seven scenarios; prints a summary
03-cleanup.sql   seconds         drops DeadlockDemo
```

Run each file whole (F5). **No second window is needed.** The other
session is a Service Broker activation procedure (see
[rcsi-snapshot-isolation](../rcsi-snapshot-isolation/) for the technique).
It takes its first lock, reports that it has, waits two seconds, and then
reaches for the lock the demo's session took in the meantime. Each deadlock
happens every time, not by luck.

The demo's session runs with `DEADLOCK_PRIORITY LOW` in A–D and F, so
whenever there's a deadlock, it is the victim and the worker finishes. That
makes the outcome predictable. Without it, SQL Server rolls back whichever
transaction is cheaper to undo.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25.

| | pattern | deadlocks | what happened |
|---|---|---|---|
| A | two transactions update accounts 1 and 2 in opposite orders | **1** | this session rolled back after 5.7 s; the worker committed |
| B | the same, in the same order | 0 | this session **waited 2.0 s**, then committed |
| C | `REPEATABLE READ`: read account 1, then update it | **1** | one row is enough |
| D | read `WITH (UPDLOCK)`, then update | 0 | waited 2.0 s at the read; **nothing lost** |
| E | a `SELECT` by `AccountRef` vs an `UPDATE` of `Status`, 5 s each | **24** | the reader managed 73 reads |
| E | … with `Balance` included in the index | 0 | the reader managed **9,425 reads** |
| F | A, with a retry on 1205 | 1 | 2 attempts; **both changes committed** |
| G | `system_health` | | **27 graphs for 27 deadlocks** |

### A — opposite order

The worker updates account 2 and holds it. This session updates account 1,
then asks for account 2 and waits for the worker. The worker asks for
account 1 and waits for this session. Neither can move. The lock monitor
finds the cycle and rolls one back. Finding it took **5.7 s**, because the
monitor wakes every 5 seconds (more often once it starts finding deadlocks).
A deadlock is also a long wait.

### B — the fix: the same order

The same two transactions, but both touch account 1 first. This session asks
for account 1, finds the worker holding it, and waits its turn: **2 s of
blocking instead of a deadlock**, and both changes kept. Blocking is the
normal, harmless price of two sessions wanting the same row. A deadlock is
blocking in a circle.

In practice this means a convention: update parent before child, accounts
in ascending ID order, tables in the same order in every procedure.

### C — one row is enough

```sql
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
BEGIN TRANSACTION;
    SELECT @b = Balance FROM Demo.Accounts WHERE AccountID = 1;   -- S lock, kept
    UPDATE Demo.Accounts SET Balance = @b + 1 WHERE AccountID = 1; -- needs X
COMMIT;
```

Both sessions read account 1 and keep their shared locks, which are
compatible with each other. Then both want to update it, which needs an
exclusive lock, which must wait for the *other* session's shared lock. This
is the conversion deadlock: one row, one table, two copies of the same
code. Under the default `READ COMMITTED` the shared lock is released at once
and this becomes a [lost update](../upsert-race-conditions/) instead.

### D — the fix: UPDLOCK on the read

```sql
SELECT @b = Balance FROM Demo.Accounts WITH (UPDLOCK) WHERE AccountID = 1;
```

Update locks are compatible with readers but not with each other. The
second session **waits at its read** until the first commits, then reads the
value the first one wrote: 1000, +10 from the worker, +1 from this session,
**1011**. No deadlock and no lost update. Take the strongest lock you'll
need at the first touch.

### E — a SELECT and an UPDATE, no transaction

```sql
-- the reader: seek on IX_Accounts_Ref, then a key lookup for Balance
SELECT @b = Balance FROM Demo.Accounts WHERE AccountRef = 'ACC0005000';
-- the writer: Status is a key column of IX_Accounts_Ref
UPDATE Demo.Accounts SET Status = 1 - Status WHERE AccountID = 5000;
```

No `BEGIN TRANSACTION`, no hints, one row each, and still **24 deadlocks in
5 seconds**. Each statement locks two indexes, in opposite orders:

- the reader locks the **index** row, then the **clustered** row (the lookup)
- the writer locks the **clustered** row, then the **index** row (to
  maintain it)

The graphs say exactly that: `keylock PK_Accounts X; keylock
IX_Accounts_Ref S`. The plain `SELECT`, the cheaper of the two to roll back,
was the victim every time.

Including `Balance` in the index makes it covering. The reader never touches
the clustered index, the second lock disappears, and with it the cycle:
**no deadlocks, and 9,425 reads instead of 73**. Read committed snapshot
isolation would also fix it, since readers then take no shared locks at all.
See [rcsi-snapshot-isolation](../rcsi-snapshot-isolation/).

### F — retry on 1205

A deadlock victim's transaction is rolled back completely, and nothing about
it was wrong. Running it again almost always works. Scenario A again, with
the transaction in a loop that retries on error 1205: **one deadlock, two
attempts, both changes committed** (1011 / 1011). Any code that can deadlock
should do this, with a small cap on attempts. The patterns above make
deadlocks rare; a retry makes the rare one harmless.

### G — the graphs SQL Server already kept

The built-in `system_health` Extended Events session records an
`xml_deadlock_report` for every deadlock, on every instance, by default. The
demo reads its event file and finds **one graph per deadlock: 27 for 27**.
Each graph names the victim's procedure and statement, and every lock in the
cycle:

| scenario | victim | locks in the cycle |
|---|---|---|
| A | `Demo.usp_Scenario: UPDATE Demo.Accounts SET Balance += 1 …` | `keylock PK_Accounts X; keylock PK_Accounts X` |
| C | `Demo.usp_Scenario: UPDATE Demo.Accounts SET Balance = @b + 1 …` | `keylock PK_Accounts S; keylock PK_Accounts S` |
| E | `Demo.usp_LookupRace: SELECT @b = Balance FROM Demo.Accounts …` | `keylock PK_Accounts X; keylock IX_Accounts_Ref S` |

Two indexes of the same table in one graph is the key-lookup signature. The
fix for that pattern is in the index, not in the code. Result set 2 is
the query; remove its date and database filters to read your own instance's
deadlocks.

## Traps from building this

- **`system_health` writes to its file in batches.** Its
  `max_dispatch_latency` is 120 s, so a deadlock can take up to two minutes
  to reach the file. In the tested runs it took about 30 seconds. Scenario G
  polls for up to 150 s and reports `INCONCLUSIVE`, not a failure, if a graph
  still hasn't arrived. The `ring_buffer` target is no shortcut: on the
  tested instance it hadn't shown a new deadlock in days.
- **Compare `timestamp_utc` as a `datetime2`.** Filtered against a string
  literal, `sys.fn_xe_file_target_read_file` returned no rows at all on the
  tested build.
- **`inputbuf` is the whole batch.** For a script run with F5 that's the top
  of the file. The victim's innermost `executionStack/frame` holds the
  procedure and the statement.

## How to read the output

`02-demo.sql` prints four result sets:

1. how each side of each scenario ended: attempts, deadlocks, iterations,
   time
2. the deadlock graphs, one row per deadlock
3. the verdicts
4. **anything that didn't behave as predicted, which should be empty**

## Takeaways

1. **Same rows, opposite order, is a deadlock.** Same order is a 2 s wait.
2. **One row can deadlock** when two sessions read it under a shared lock
   and then both try to update it. Read `WITH (UPDLOCK)`.
3. **A `SELECT` and an `UPDATE` with no transaction can deadlock** through a
   key lookup: 24 times in 5 s. A covering index removed every one.
4. **Retry on 1205.** The victim did nothing wrong; the second attempt
   committed.
5. **The graphs are already there**: `system_health` kept all 27, with the
   statement and the index of every lock.

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
