# Upsert race conditions: IF EXISTS, MERGE, and the locks that make them safe

"Update the row if it's there, insert it if it isn't" is one of the most
common things an application asks of a database, and the most common way to
write it is wrong under concurrency. It passes every test with one user. Under
load it produces primary key violations, or duplicate rows, or counts that
quietly come out short. This topic runs the usual patterns on four sessions at
once, over the same keys, and counts what each one left behind.

## The rule these scenarios are built around

**A check followed by an action is two steps, and another session can act in
between. Make the check take a lock that lasts until the action is done:
`UPDLOCK, SERIALIZABLE` (or `MERGE ... WITH (HOLDLOCK)`), inside one
transaction. Put a unique constraint on the key either way.**

## Prerequisites

- SQL Server 2016 SP1 or later. Developed and tested on **2022 CU25
  (16.0.4255.1)**, 8 schedulers, Linux container.
- No sample database. `01-setup.sql` creates its own database, `UpsertDemo`.
- Permission to `CREATE DATABASE`.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched

Setup turns on Service Broker in `UpsertDemo`; its queues and activation
procedures run the four background workers. `03-cleanup.sql` drops the
database and confirms that none of its files remain.

## Run order

```
01-setup.sql     seconds        creates UpsertDemo, the four workers
02-demo.sql      ~1-2 minutes   seven scenarios; prints a summary
03-cleanup.sql   seconds        drops UpsertDemo
```

Run each file whole (F5). **No second window is needed.** The four
concurrent sessions are Service Broker activation procedures (the technique
is explained in [rcsi-snapshot-isolation](../rcsi-snapshot-isolation/)).
Each reports `ready` and then waits on a flag, so all four start within a
millisecond of one another.

## How it's built

Each worker runs `Demo.usp_Upsert` for keys 1, 2, 3 … *N* in order, adding
1 to that key's `Hits`. Four workers each doing *N* upserts should leave
exactly *N* rows, with `Hits` adding up to 4 × *N*. Anything else is a race
that was lost.

The patterns that read first and write afterwards (A, B and C) **pause
10 ms between the read and the write**. The pause stands in for whatever real
code does between deciding and acting: a second query, a calculation, a
round trip to the application. It doesn't create the race. Without it, the
tested build still lost a few in every 8,000 upserts; the pause just makes
the race show up every time instead of now and then. The locked patterns
(F and G) get **the same pause**, to show that the lock, not luck, is what
makes them right.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25. The races
are timing-dependent, so your counts will differ; what matters is which
columns are zero.

| | pattern | upserts | rows for keys | `Hits` total, of expected | errors |
|---|---|---|---|---|---|
| A | `IF EXISTS` … `UPDATE` `ELSE INSERT` | 800 | 200 for 200 | **202 of 800** | **598 PK violations** |
| B | the same, table with no unique key | 800 | **777 for 200** | 808 of 800 | none |
| C | `SELECT` the value, then `UPDATE` it | 800 | 200 for 200 | **748 of 800** | none |
| D | `MERGE`, no hint | 80,000 | 20,000 for 20,000 | 79,997 of 80,000 | **3 PK violations** |
| E | `MERGE WITH (HOLDLOCK)` | 20,000 | 5,000 for 5,000 | 20,000 of 20,000 | none |
| F | `UPDATE WITH (UPDLOCK, SERIALIZABLE)`, then `INSERT` | 800 | 200 for 200 | 800 of 800 | none |
| G | `SELECT WITH (UPDLOCK)`, then `UPDATE` | 800 | 200 for 200 | 800 of 800 | none |

### A — check, then insert

```sql
IF EXISTS (SELECT 1 FROM Demo.Counters WHERE KeyID = @KeyID)
    UPDATE Demo.Counters SET Hits = Hits + 1 WHERE KeyID = @KeyID;
ELSE
    INSERT Demo.Counters (KeyID, Hits) VALUES (@KeyID, 1);
```

All four sessions ask "is key 7 there?" and all four hear "no". All four
insert it. One wins, and the primary key rejects the other three: **598 PK
violations in 800 upserts**. The table is consistent, because the key held,
but every violation is an error the application received, and an increment
that was never counted unless something retried it.

### B — the same, with no key

The same code against a table built the way many are, with an index on the
key but no unique constraint, because "the application checks first". Nothing
rejects anything. **777 rows for 200 keys**, and no error anywhere. It gets
worse afterwards: the next `UPDATE ... WHERE KeyID = @KeyID` updates every
copy, so the total came out **higher** than the work done (808 of 800).
Duplicate rows don't stay in their own lane.

### C — read, then write

```sql
DECLARE @h int = (SELECT Hits FROM Demo.Counters WHERE KeyID = @KeyID);
UPDATE Demo.Counters SET Hits = @h + 1 WHERE KeyID = @KeyID;
```

The lost update: two sessions read 5, both write 6. **52 of 800 increments
vanished** with no error and no trace. It's the pattern every ORM produces
when it loads an entity, changes a property and saves it. `SET Hits = Hits
+ 1` in a single `UPDATE` doesn't have this problem; when you need the read,
G is the fix.

### D — plain MERGE

`MERGE` is one statement, so it looks atomic. It isn't: it still finds out
whether the row exists, then inserts it, and under the default isolation
level nothing stops another session from inserting the same key in between.
The window is a few microseconds rather than 10 ms, so the race is rare:
**3 PK violations in 80,000 upserts**. Rare isn't never. On a busy system it
is the error that shows up a few times a day and can't be reproduced.

The demo runs up to three rounds of 80,000. If none of them lose, it reports
`INCONCLUSIVE` rather than claiming that `MERGE` is safe.

### E — MERGE WITH (HOLDLOCK)

`HOLDLOCK` is `SERIALIZABLE` for that table: the check takes a key-range lock
that covers the missing row and keeps it until the statement is done, so the
second session waits instead of inserting. **Exact, and no errors.**

### F — UPDLOCK, SERIALIZABLE

```sql
BEGIN TRANSACTION;
    UPDATE Demo.Counters WITH (UPDLOCK, SERIALIZABLE) SET Hits = Hits + 1 WHERE KeyID = @KeyID;
    IF @@ROWCOUNT = 0
        INSERT Demo.Counters (KeyID, Hits) VALUES (@KeyID, 1);
COMMIT;
```

The usual recommendation, and the reason for each hint:

- `SERIALIZABLE` locks the *range* where the missing key would go, so nobody
  else can insert it.
- `UPDLOCK` makes that lock an update lock rather than a shared one, so two
  sessions can't both hold it and then deadlock trying to convert it.
- Updating first, rather than checking first, means the common case (the row
  exists) costs one statement.

With the same 10 ms pause that broke A, between the `UPDATE` and the
`INSERT`, it was **exact, with no errors and no deadlocks.**

### G — read WITH (UPDLOCK), then write

The fix for C when the code really does need to read first. `UPDLOCK` on the
read, in a transaction, makes the next session wait at its read until this one
has written. **Exact, with the same 10 ms pause.**

### What correctness cost

| | upserts | slowest worker |
|---|---|---|
| D: `MERGE`, no hint | 80,000 | 16.3 s |
| E: `MERGE WITH (HOLDLOCK)` | 20,000 | 21.0 s |

This is the worst case for locking: four sessions hitting the *same* key at
the *same* moment, which makes them take turns. Real traffic spread over many
keys mostly doesn't contend at all. The cost is real where sessions do
collide, and that is exactly where the unlocked version is wrong.

## How to read the output

`02-demo.sql` prints three result sets:

1. what each pattern left behind: rows, distinct keys, hits, errors, time
2. the verdicts
3. **anything that didn't behave as predicted, which should be empty.** D can
   appear there as `INCONCLUSIVE` when no round caught the `MERGE` race.

## Traps from building this

- **`WAITFOR DELAY` with a `datetime` counts in 1/300 s.** A 1 ms pause
  rounds to zero and doesn't wait at all; the first version of the demo
  "paused" 1 ms and showed almost no races. 10 ms it is.
- **Don't truncate under running workers.** A race that outlived the wait for
  it was still writing into the next scenario's table. `Demo.usp_Race` waits
  up to three minutes, and every verdict first checks that all four workers
  finished.

## Takeaways

1. **`IF EXISTS` then `INSERT` is a race.** 598 PK violations in 800
   upserts once there was work between the check and the insert.
2. **Without a unique constraint the race is silent**: 777 rows for 200
   keys, and the duplicates inflate every later update.
3. **Read, then write loses updates** without an error: 52 of 800.
4. **`MERGE` alone is not a lock.** 3 in 80,000 is rare, not safe.
5. **`UPDLOCK, SERIALIZABLE` in a transaction, or `MERGE WITH (HOLDLOCK)`,
   is exact**, even with the same pause that broke the others.
6. **Keep the unique constraint anyway.** It turns a silent duplicate into a
   loud error.

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
