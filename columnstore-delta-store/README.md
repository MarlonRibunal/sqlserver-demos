# Columnstore: the delta store, and the rowgroups a query can skip

> **The short version:** [Columnstore and the delta store](https://marlonribunal.com/sqlserver-demos/columnstore-delta-store/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

A clustered columnstore index is only columnstore once its rows are
compressed. Until then they sit in a **delta store**: an ordinary rowstore,
uncompressed, read row by row. Four scenarios measure how rows end up there,
what it costs, how to get them out, and how the order rows are loaded in
decides how much of the table a query can skip.

## The rule these scenarios are built around

**Load columnstore in batches of at least 102,400 rows, compress what
trickles in, and load in the order you filter by.**

## Prerequisites

- SQL Server 2016 SP1 or later: columnstore is in every edition from 2016 SP1.
  Developed and tested on **2022 CU25 (16.0.4255.1)**.
- No sample database. `01-setup.sql` creates its own database,
  `ColumnstoreDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` for the DMVs.
- About 1.2 GB of free disk.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched

`03-cleanup.sql` drops the database and confirms that none of its files remain.

## Run order

```
01-setup.sql     ~15 s     creates ColumnstoreDemo, 6,000,000 rows, two columnstore tables
02-demo.sql      ~10 s     four scenarios; prints a summary
03-cleanup.sql   seconds   drops ColumnstoreDemo
```

Run each file whole (F5). Scenarios A to C build their own tables, so
`02-demo.sql` can be re-run without re-running setup.

## How it's built

`Demo.Source` holds 6,000,000 sales rows, 2,000 a day from 2018-01-01. Every
columnstore table is loaded from it. Evidence comes from:

- `sys.dm_db_column_store_row_group_physical_stats`: each rowgroup's state,
  rows and size
- `sys.column_store_segments`: each rowgroup's min and max per column
- `sys.dm_exec_requests` deltas: the logical reads and CPU of each query,
  measured warm

Rowgroup states:

| state | what it is |
|---|---|
| `OPEN` | a delta store still taking rows: a rowstore b-tree, uncompressed |
| `CLOSED` | a full delta store (1,048,576 rows), waiting for the background tuple mover |
| `COMPRESSED` | actual columnstore |
| `TOMBSTONE` | a delta store that has been compressed, waiting to be deallocated |

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25, 8 schedulers.

### A — the 102,400-row line

One `INSERT ... SELECT` into an empty columnstore table:

| rows in the insert | rowgroup state | size |
|---|---|---|
| 102,399 | **OPEN** (delta store) | 2,856 KB |
| 102,400 | **COMPRESSED** (trim reason `BULKLOAD`) | 358 KB, **8× smaller** |

An insert of at least 102,400 rows goes straight into a compressed rowgroup.
One row fewer, and the whole lot goes into the delta store.

### B — trickle inserts

The same 200,000 rows, loaded two ways:

| | rowgroups | size | full-scan reads |
|---|---|---|---|
| 200 `INSERT`s of 1,000 rows | **1 OPEN**, 200,000 rows | 5,576 KB | **703** |
| 1 `INSERT` of 200,000 rows | 1 COMPRESSED | 706 KB | **12** — 59× fewer |

Every small insert lands in the delta store. A delta store stays `OPEN` until
it holds **1,048,576** rows. Only then is it closed and handed to the
background tuple mover to compress. A table fed a few hundred thousand rows a
day in small batches can spend its whole life as a rowstore with a
columnstore's name, at 8× the size and many times the reads.

### C — the fix

```sql
ALTER INDEX CCI ON Demo.Trickle REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);
```

| | rowgroups | full-scan reads |
|---|---|---|
| before | 1 OPEN, 200,000 rows, 5,576 KB | 703 |
| after | 1 **COMPRESSED**, 706 KB, trim reason `REORG`; the old delta store as a **TOMBSTONE** | **12** |

`COMPRESS_ALL_ROW_GROUPS = ON` compresses open and closed delta stores now,
instead of waiting for them to fill. It's an online operation and cheap next
to a rebuild. Schedule it after a trickle-fed load window. The tombstone is
deallocated by background cleanup.

The result is one compressed rowgroup of 200,000 rows: compressed, but well
short of the 1,048,576 a rowgroup can hold. Many small compressed rowgroups
beat delta stores but are worse than full ones. Reorganizing every few
thousand rows would trade one problem for the other.

### D — rowgroup elimination

The same 6,000,000 rows, compressed into six rowgroups each, built in setup:

- `Demo.Ordered`: rowstore clustered index on `SaleDate` first, then converted
  with `CREATE CLUSTERED COLUMNSTORE INDEX ... WITH (DROP_EXISTING = ON, MAXDOP = 1)`
- `Demo.Unordered`: the same, but the rowstore index was on `Amount`

| query: total Amount for 2021-03-15 | rowgroups whose date range covers the day | logical reads | answer |
|---|---|---|---|
| `Demo.Ordered` | **1 of 6** | **236** | 999,000 |
| `Demo.Unordered` | **6 of 6** | **1,303** | 999,000 |

Every compressed rowgroup records the minimum and maximum of each column, and
a query skips any rowgroup whose range can't contain the value. In the
ordered table each rowgroup holds a separate run of dates, so five of six are
skipped. In the unordered table every rowgroup spans every date, so none can
be. The answers match, at 5.5× fewer reads.

`MAXDOP 1` on the conversion matters. A parallel build splits the input
across threads, and their rowgroups interleave the ranges again. On SQL Server
2022, `CREATE CLUSTERED COLUMNSTORE INDEX` also accepts an `ORDER` clause.

## A trap from building this

**`INSERT ... SELECT ... ORDER BY` into a columnstore does not order its
rowgroups.** The first version of scenario D loaded the "ordered" table that
way, with `MAXDOP 1`. Its six rowgroups' date ranges overlapped exactly as
much as the unordered table's did. The ordering has to come from a rowstore
clustered index that the columnstore is built over, as above.

## How to read the output

`02-demo.sql` prints four result sets:

1. every rowgroup snapshot
2. every query's reads, CPU and answer
3. the verdicts
4. **anything that didn't behave as predicted, which should be empty**

## Takeaways

1. **Below 102,400 rows per insert, nothing is compressed.** 102,399 rows went
   to the delta store; 102,400 were compressed on arrival at an eighth of the
   size.
2. **Trickle-fed columnstore is rowstore until a delta store fills at
   1,048,576 rows.** 200 small inserts left 200,000 rows uncompressed, at 59×
   the scan reads.
3. **`REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON)` fixes it on your
   schedule**, online and cheaply.
4. **Load in the order you filter by.** Ordered rowgroups let a one-day query
   skip five of six; unordered, it read all six.
5. **`ORDER BY` on the insert doesn't do that.** A rowstore clustered index
   converted with `DROP_EXISTING` and `MAXDOP = 1` does.

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

These scripts and this README were written with the help of AI. The results
come from running the scripts on SQL Server, not from the AI. See
[how this was made](../README.md#how-this-was-made).
