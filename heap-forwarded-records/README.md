# Heaps: forwarded records, and the pages a heap keeps

> **The short version:** [Heaps and forwarded records](https://marlonribunal.com/sqlserver-demos/heap-forwarded-records/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

"Heaps are fine for staging tables." Often they are. Four scenarios measure
the two ways a heap quietly gets expensive: rows that grow get **forwarded**,
and deleted rows leave **empty pages that never go away**. One of them is
caused by the cure for lock escalation.

## The rule these scenarios are built around

**A heap is fine while its rows don't grow and it's emptied with `TRUNCATE`
or a table-locked `DELETE`. If either stops being true, give it a clustered
index, or budget for `ALTER TABLE ... REBUILD`.**

## Prerequisites

- SQL Server 2016 or later (`ALTER TABLE ... REBUILD` needs 2008). Developed
  and tested on **2022 CU25 (16.0.4255.1)**.
- No sample database. `01-setup.sql` creates its own database, `HeapDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` for the DMVs.
- About 500 MB of free disk. The database reaches about 400 MB.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched

`03-cleanup.sql` drops `HeapDemo` and confirms that none of its files remain.

## Run order

```
01-setup.sql     seconds   creates HeapDemo and the procedures
02-demo.sql      ~1 min    builds its own tables; four scenarios; prints a summary
03-cleanup.sql   seconds   drops HeapDemo
```

Run each file whole (F5). Every scenario builds fresh tables through
`Demo.usp_Build`, so `02-demo.sql` can be re-run without re-running setup.
Most of the minute is scenario C waiting for ghost cleanup.

## How it's built

`Demo.usp_Build` creates a table as a **heap** or with a **clustered primary
key**, and loads the same 100,000 rows: an id, a status, and a `Notes` column
that starts at 10 characters, about 290 rows to a page. Every 50th row has
`Status = 'X'`, and `Status` has a nonclustered index.

`Demo.usp_Snapshot` records:

- pages, forwarded records and density, from `sys.dm_db_index_physical_stats`
  in `DETAILED` mode. `LIMITED` returns NULL for both.
- the logical reads of a full scan
- the reads of a 2,000-row fetch through the nonclustered index, which makes
  every row a lookup

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25, 8 schedulers.

### A — rows that grow

The same `UPDATE` on both tables: `Notes` goes from 10 characters to 400 on
every third row. The rows no longer fit on their pages.

| | pages | forwarded records | density | full-scan reads |
|---|---|---|---|---|
| heap, before | 347 | 0 | 99.7% | 351 |
| clustered, before | 347 | 0 | 99.7% | 349 |
| **heap, after** | **2,121** | **31,949** | 96.3% | **34,074** |
| clustered, after | 3,730 | 0 | 52.3% | 3,745 |

The clustered table **splits** its pages: more of them, about half full, and
every row is still where the key says. The heap **moves** each row that no
longer fits to any page with room, and leaves a forwarding pointer in the old
slot, because every nonclustered index still points there.

The heap ends up with *fewer* pages than the clustered table, and a full scan
reads **9× as much**. A scan follows each forwarding pointer to the row's new
page, then comes back:

```
2,121 pages + 31,949 forwarded records = 34,070      measured: 34,074
```

One extra read per forwarded row, almost exactly.

### B — lookups through a nonclustered index

| | lookup reads, 2,000 rows |
|---|---|
| heap, before | 2,132 |
| heap, after | **2,770** |
| clustered, before | 4,255 |
| clustered, after | 6,380 |

A heap's nonclustered index points to a physical row id (RID), so a lookup is
one read. That's cheaper than a clustered table's key lookup, which is a seek
down the clustered index, before and after. Forwarding erodes that advantage:
666 of the 2,000 rows had been forwarded, and lookups rose by 638 reads, about
one extra per forwarded row.

### C — deletes, and the pages a heap keeps

Delete the first 90,000 of the 100,000 rows, so whole pages empty out, four
ways:

| | pages left | full-scan reads | |
|---|---|---|---|
| C1 heap, 20 `DELETE`s of 4,500 rows | **347 of 347** | 351 | **every page kept** |
| C2 heap, one `DELETE` of 90,000 rows | 53 | 57 | escalated to a table lock |
| C3 heap, `DELETE ... WITH (TABLOCK)` | 36 | 40 | |
| C4 clustered, 20 `DELETE`s of 4,500 rows | 37 | 39 | released by ghost cleanup |

A heap only releases a page emptied by `DELETE` when the delete holds a lock on
the whole table. Otherwise the empty page stays allocated, and every scan keeps
reading it. C1 holds 10,000 rows on 347 pages, 16% full, and will stay that
way until something rebuilds it.

C2 got its table lock by escalating, which `index_lock_promotion_count`
confirms. C1 never escalated, because each 4,500-row statement stays under the
threshold. That's exactly what batching is for: it's the standard cure for
lock escalation (see the [lock-escalation](../lock-escalation/) topic). **The
purge that is kindest to concurrency is the one that leaves a heap full of
empty pages.** A clustered index doesn't have this problem: its emptied pages
are released by ghost cleanup in the background.

If you purge a heap in batches, finish with `ALTER TABLE ... REBUILD`, or
truncate instead of deleting when the whole table goes.

### D — the fix

| | before | after | time |
|---|---|---|---|
| widened heap from A: forwarded records | 31,949 | **0** | 167 ms |
| widened heap from A: full-scan reads | 34,074 | **1,972** | |
| batch-deleted heap from C1: pages | 347 | **35** | 17 ms |

`ALTER TABLE ... REBUILD` puts forwarded rows back in line and releases empty
pages. It's not free on a real table. A heap's nonclustered indexes point at
physical row ids, and a rebuild changes every one of them, so it **rebuilds
every nonclustered index too**. And it only resets the problem: if rows keep
growing, they'll be forwarded again. A clustered index fixes it for good.

## How to read the output

`02-demo.sql` prints three result sets: every snapshot, the verdicts, and
**anything that didn't behave as predicted, which should be empty.**

## Traps worth stealing

- **`sys.dm_db_index_physical_stats` in `LIMITED` mode returns NULL for
  `forwarded_record_count`.** Use `SAMPLED` or `DETAILED`.
- **`index_lock_promotion_count` can reset.** Read straight after the delete,
  it showed the escalation. Read a few statements later in the first version
  of this demo, it showed 0. Its values live in a metadata cache and aren't
  durable, so capture them immediately.
- **Measure page counts after ghost cleanup.** Deleted rows in an index are
  ghosts for a few seconds. The demo polls `ghost_record_count` before
  measuring.

## Takeaways

1. **Rows that grow in a heap are forwarded, and every forwarded row costs an
   extra read on every scan.** 31,949 forwarded rows turned a 2,121-page scan
   into 34,074 reads.
2. **Fewer pages doesn't mean less work.** The heap had fewer pages than the
   split clustered table and read 9× as much.
3. **RID lookups are cheaper than key lookups, until rows are forwarded.**
4. **A heap keeps the pages a `DELETE` empties unless the delete held a table
   lock.** Batched purges, which avoid escalation, kept every one of 347
   pages.
5. **`ALTER TABLE ... REBUILD` fixes both, and rebuilds every nonclustered
   index while it's at it.** A clustered index fixes both for good.

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
