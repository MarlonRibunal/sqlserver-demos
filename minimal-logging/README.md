# Minimal logging: when bulk inserts really are cheap

"Use `TABLOCK` and the insert is minimally logged." Sometimes. This topic
loads the same 200,000 rows (43 MB) seven ways under each recovery model, and
measures exactly what each load writes to the transaction log, from the
load's own transaction.

## The rule these scenarios are built around

**Minimal logging needs a recovery model that allows it, a table lock, and a
target with no nonclustered index. Miss any one and you pay for every row.**

## Prerequisites

- SQL Server 2016 or later. Developed and tested on **2022 CU25
  (16.0.4255.1)**, in a Linux container.
- No sample database. `01-setup.sql` creates its own database,
  `MinimalLoggingDemo`.
- Permission to `CREATE DATABASE` and `BACKUP DATABASE` / `BACKUP LOG`, and
  `VIEW SERVER STATE` for the DMVs.
- About 1 GB of free disk.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched

`02-demo.sql` switches **`MinimalLoggingDemo`** between SIMPLE, BULK_LOGGED
and FULL recovery, and backs it up to the **null device**,
`DISK = N'NUL'`. Those backups exist only so that FULL recovery is real (see
scenario C), and they write no file anywhere. **Don't copy that to a database
you care about.** A backup to `NUL` can't be restored, and it breaks the
chain your real backups depend on. The backups leave ordinary history rows in
`msdb`, pointing at `NUL`. `03-cleanup.sql` drops the database and confirms
that none of its files remain.

## Run order

```
01-setup.sql     seconds   creates MinimalLoggingDemo and 200,000 source rows
02-demo.sql      ~10 s     21 loads under three recovery models; prints a summary
03-cleanup.sql   seconds   drops MinimalLoggingDemo
```

Run each file whole (F5).

## How it's built

`Demo.usp_Load` builds one target shape, then loads every source row inside an
explicit transaction. Before committing, it reads the transaction's own
`database_transaction_log_bytes_used` and `_log_record_count` from
`sys.dm_tran_database_transactions`. That's that load's log exactly, unaffected
by checkpoints or anything else writing to the log.

The seven load shapes:

| | target | statement |
|---|---|---|
| H1 | heap | `INSERT ... SELECT` |
| H2 | heap | `INSERT ... WITH (TABLOCK) SELECT` |
| H3 | heap with a nonclustered index | `INSERT ... WITH (TABLOCK) SELECT` |
| C1 | empty clustered index | `INSERT ... SELECT` |
| C2 | empty clustered index | `INSERT ... WITH (TABLOCK) SELECT` |
| C3 | clustered index already holding 200,000 rows; new keys above them | `INSERT ... WITH (TABLOCK) SELECT` |
| S1 | new table | `SELECT ... INTO` |

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25.

### The four tiers

What a load writes to the log falls into four tiers, told apart by size
against the 43 MB of data and by record count against the 200,000 rows:

| tier | log size | log records | what's logged |
|---|---|---|---|
| **minimal** | under 3% of the data | a few thousand | page allocations only |
| **reduced** | 3–25% | a few thousand | new pages minimally, the rest per row |
| **page images** | about the data size | a few thousand | whole pages |
| **row by row** | more than the data size | one or more per row | every row |

### A and B — SIMPLE and BULK_LOGGED

The two models gave the same answers:

| | log | records | tier |
|---|---|---|---|
| H1 heap | 60.75 MB | 205,389 | row by row |
| **H2 heap, `TABLOCK`** | **0.36 MB** | 4,827 | **minimal** |
| **H3 heap + nonclustered index, `TABLOCK`** | **61.12 MB** | 206,804 | **row by row** |
| **C1 empty clustered, no `TABLOCK`** | **4.32 MB** | 5,930 | **reduced** |
| C2 empty clustered, `TABLOCK` | 0.22 MB | 733 | minimal |
| C3 non-empty clustered, `TABLOCK` | 4.32 MB | 5,908 | reduced |
| S1 `SELECT ... INTO` | 0.49 MB | 6,526 | minimal |

Three rows are worth a second look:

- **A heap is minimal only with `TABLOCK`.** Without it, H1 logs every row:
  170× the log of H2.
- **One nonclustered index cancels the whole benefit.** H3 has `TABLOCK` and
  logs as much as H1. Drop nonclustered indexes before a big load and
  rebuild them afterwards, or accept the log.
- **An empty clustered index is cheap even without `TABLOCK`.** Since SQL
  Server 2016, rows written to brand-new pages are minimally logged by
  default (the behaviour trace flag 610 used to enable). C1 wrote 4.32 MB, a
  tenth of the data. With `TABLOCK` it's 0.22 MB. C3, appending above
  existing keys, behaves like C1.

BULK_LOGGED exists so that bulk loads can stay minimal while the database
keeps a log chain. The price isn't measured here: a log backup covering
minimally logged work has to copy the changed data pages, and you can't
restore to a point in time inside it.

### C — FULL

| | log | records | tier |
|---|---|---|---|
| H1 heap | 61.19 MB | 205,389 | row by row |
| H2 heap, `TABLOCK` | **44.34 MB** | **12,048** | **page images** |
| H3 heap + nonclustered index, `TABLOCK` | 80.76 MB | 405,907 | row by row |
| C1 empty clustered | 65.14 MB | 200,338 | row by row |
| C2 empty clustered, `TABLOCK` | **44.14 MB** | **6,289** | **page images** |
| C3 non-empty clustered, `TABLOCK` | 64.47 MB | 200,335 | row by row |
| S1 `SELECT ... INTO` | **44.41 MB** | **12,917** | **page images** |

Nothing is minimally logged under FULL; point-in-time restore depends on it.
But "fully logged" comes in two kinds. The loads that would have been minimal
log **whole page images**: about the size of the data, in a few thousand
records instead of 200,000. Everything else logs every row, at 1.4–1.9× the
data. `TABLOCK` still pays under FULL, just much less.

**"FULL" here is real FULL.** A database switched to FULL recovery behaves as
if it were still SIMPLE until a full backup starts its log chain. This is
often called pseudo-simple, and a test that skips the backup measures SIMPLE
while labelling it FULL. The demo records `RealFull` for every FULL load from
`sys.database_recovery_status.last_log_backup_lsn`, and would mark the
results `INCONCLUSIVE` if the chain were missing.

## Traps worth stealing

- **On Linux, `BACKUP ... TO DISK = '/dev/null'` fails** with OS error 31
  while SQL Server tries to size the file. **`DISK = 'NUL'` works on Linux
  too.**
- **Measure a load's log from its own transaction.**
  `sys.dm_tran_database_transactions` for `CURRENT_TRANSACTION_ID()` gives
  bytes and records for exactly that work. A before/after on the log file is
  disturbed by checkpoints and by everyone else.

## How to read the output

`02-demo.sql` prints four result sets:

1. log MB per load shape and recovery model, side by side
2. every load with its record count and time
3. the verdicts
4. **anything that didn't behave as predicted, which should be empty**

## Takeaways

1. **`TABLOCK` on a heap: 0.36 MB instead of 60.75.** Without it there is no
   minimal logging.
2. **A nonclustered index on the target makes the load row by row,
   `TABLOCK` or not.**
3. **An empty clustered index is reduced-logged even without `TABLOCK`**
   (2016+), and minimal with it.
4. **FULL recovery is never minimal, but `TABLOCK` loads still write page
   images**: 44 MB in a few thousand records, against 61–81 MB row by row.
5. **A database newly switched to FULL isn't really in FULL until its first
   full backup.** Test accordingly.

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
