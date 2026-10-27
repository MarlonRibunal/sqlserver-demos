# Index fragmentation: what it costs, and what it doesn't

> **The short version:** [Index fragmentation](https://marlonribunal.com/sqlserver-demos/index-fragmentation/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

Six scenarios that separate the two things "fragmentation" lumps together. They
show that the number most maintenance jobs act on doesn't predict what your
queries pay.

## The rule these scenarios are built around

**Watch page density, not fragmentation percentage.**

`sys.dm_db_index_physical_stats` reports two different conditions, and both get
called fragmentation:

| column | what it measures | what it costs |
|---|---|---|
| `avg_fragmentation_in_percent` | pages **out of order** in the file | nothing, once the pages are in memory |
| `avg_page_space_used_in_percent` | how **full** each page is | every read, and every MB of buffer pool, every time |

The familiar rule (under 5% leave it, 5–30% `REORGANIZE`, over 30% `REBUILD`)
reads the first column and ignores the second. Scenarios A and B take the two
apart. C shows that a real-world fragmented index is mostly paying for the
second. D finds the one place the first column does cost something. E runs the
rule against all three, and F prices `FILLFACTOR`.

## Prerequisites

- SQL Server 2016 or later. Developed and tested on **2022 CU25 (16.0.4255.1)**.
- No sample database. `01-setup.sql` creates its own database,
  `FragmentationDemo`.
- Permission to `CREATE DATABASE` and `ALTER DATABASE`, and `VIEW SERVER STATE`
  for the DMVs.
- About 1 GB of free disk. `FragmentationDemo` reaches roughly 900 MB by the
  end of the demo: about 600 MB of data files and 260 MB of log. Cleanup
  releases all of it.
- **A scratch instance.** Scenario D takes `FragmentationDemo` offline and back
  online. See [Why offline/online, and not DROPCLEANBUFFERS](#why-offlineonline-and-not-dropcleanbuffers).

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched
- no instance-wide buffer pool or plan cache flush

Two things in this topic look drastic but act **only on `FragmentationDemo`**:

- `01-setup.sql` runs `DBCC SHRINKFILE` on one of `FragmentationDemo`'s files.
  That's how it builds a table that is fragmented and nothing else (see
  scenario A).
- `02-demo.sql` sets `FragmentationDemo` `OFFLINE` and then `ONLINE` to get a
  cold cache for that database alone (see scenario D). Any other session
  connected to `FragmentationDemo` is disconnected.

`03-cleanup.sql` drops the database and confirms that none of its files remain.

## Run order

```
01-setup.sql     ~15 s     creates FragmentationDemo, four 100,000-row tables
02-demo.sql      ~40 s     the six scenarios; prints a summary
03-cleanup.sql   seconds   drops FragmentationDemo
```

Run each file whole (F5). `02-demo.sql` records its own evidence into
`Demo.DemoResults` and `Demo.IndexSnapshots`, so you don't have to read any
output while it runs. It can be re-run without re-running setup: scenarios E and
F build fresh tables of their own.

Not on SSMS? Everything works through sqlcmd. `-I` turns on
`QUOTED_IDENTIFIER`, as SSMS does by default.

```
sqlcmd -S <server> -I -i 01-setup.sql -o setup.txt
sqlcmd -S <server> -I -i 02-demo.sql  -o demo.txt
sqlcmd -S <server> -I -i 03-cleanup.sql
```

## The four tables

Every table holds **the same 100,000 rows of the same width**
(`id int, g uniqueidentifier, pad char(200)`). Only the page layout differs, so
any difference in reads comes from the layout and not from the data.

| table | how it was built | fragmentation | density |
|---|---|---|---|
| `Demo.Dense` | loaded in key order, rebuilt | 0.24% | 98.76% |
| `Demo.Scattered` | as Dense, then the file was **shrunk** | **99.97%** | 98.76% |
| `Demo.Sparse` | 200,000 rows, then every second one **deleted** | 0.12% | **49.44%** |
| `Demo.Random` | clustered on `NEWID()`, loaded in 100 batches | **99.32%** | **68.55%** |

Each shape is checked after it is built. A `Scattered` table that didn't come
out of the shrink fragmented would make scenario A prove nothing, so setup
raises an error instead of handing it over.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25, 8 schedulers,
Linux container on NVMe storage. Every scan runs with `OPTION (MAXDOP 1)`, a
query hint rather than a setting change. Your magnitudes will differ. The
*ratios* and the *verdicts* are the point.

### A — logical fragmentation, and nothing else

| | fragmentation | density | logical reads | buffer pool |
|---|---|---|---|---|
| `Demo.Dense` | 0.24% | 98.76% | 2,874 | 22.45 MB |
| `Demo.Scattered` | **99.97%** | 98.76% | **2,874** | **22.45 MB** |

The worst fragmentation figure the DMV can report, and the same number of
reads, to the page. A logical read is a page touched in memory. Once the page
is there, its position in the data file doesn't matter. The scan follows
next-page pointers, and following a pointer costs the same whichever way it
points.

The way `Demo.Scattered` was built is a lesson in itself. Setup put a filler
table in the file first and the real table after it, dropped the filler, then
ran `DBCC SHRINKFILE`. Shrink fills the hole at the front by moving pages from
the end of the file, last page first, so the table's page order comes out
reversed. Pages move whole, so no row changes page and density is untouched.
**Shrinking a data file does this to every index in it.**

The trick depends on where free space sits in the file, and a dropped table
over 128 extents is freed by a background task, not at once. The build waits
for that cleanup. If a table still comes out unscattered (seen once in CI, on
2025), it says so and builds again, up to three attempts.

### B — half-empty pages, and nothing else

| | fragmentation | density | logical reads | buffer pool |
|---|---|---|---|---|
| `Demo.Dense` | 0.24% | 98.76% | 2,874 | 22.45 MB |
| `Demo.Sparse` | **0.12%** | **49.44%** | **5,738** — 2.00× | **44.88 MB** — 2.00× |

This is a purge job in miniature: load 200,000 rows, then delete every second
one. No page moved, so fragmentation is lower than the control's. Every page
is half empty, so the same rows cost twice the reads.

The buffer pool column is the one people miss. Half-empty pages are cached
half-empty, so 22 MB of the 45 MB is empty space that pushed something else
out of memory.

Deleted rows become ghost records and are reclaimed by a background task a few
seconds later. Setup polls `ghost_record_count` until it reaches zero before it
measures anything. Measure too early and the density figure is wrong.

### C — a random GUID clustering key

| | fragmentation | density | logical reads | vs Dense |
|---|---|---|---|---|
| `Demo.Random` | 99.32% | 68.55% | 4,146 | **1.44×** |

This is the case that gave fragmentation its reputation, and it has **both**
conditions. Scenarios A and B predict which one costs the reads. If density is
the cost, reads should exceed the control's by the density ratio,
98.76 / 68.55 = **1.44**. They do, to two decimal places. The 99% fragmentation
adds nothing on top.

### D — cold reads: where page order does cost something

Everything above measured **logical** reads, the warm-cache cost. The classic
argument for defragmenting is about **physical** reads. A scan reads ahead in
large I/Os, and only pages that sit next to each other on disk can come back
in one I/O.

Each table lives alone in its own file. That lets `sys.dm_io_virtual_file_stats`
count exactly the I/Os each cold scan issued:

| | read I/Os | MB read | avg KB per I/O |
|---|---|---|---|
| `Demo.Dense` | 135 | 22.9 | 174 |
| `Demo.Scattered` | **147** | 22.5 | 157 |
| `Demo.Sparse` | 345 | **45.2** | 134 |
| `Demo.Random` | **901** — 6.7× | 33.8 | **38** |

- **`Demo.Scattered` costs the disk almost nothing.** Its pages are in reverse
  order but still *contiguous*, and read-ahead fetches contiguous runs in
  whichever direction they point. The I/O count was between 1.06× and 1.35×
  the control's across four setups of the tested instance. It varies with where
  the shrink happened to put pages, but it repeats exactly across demo runs on
  the same setup.
- **`Demo.Random` is where logical fragmentation really costs something.**
  Page splits scatter its pages across the file one at a time. Read-ahead
  rarely finds neighbours to fetch together, so the I/Os are about a fifth of
  the size and there are about seven times as many. On spinning disks that was
  serious. On SSD it is much smaller, and on a warm cache it is zero.
- **`Demo.Sparse` reads twice the bytes**, as it does warm.

Elapsed milliseconds are in the output but carry no verdict. On NVMe they were
11–28 ms for every table, which is too small and noisy to argue from.

### E — what the 5% / 30% rule does with these tables

A fresh copy of each problem table, maintained both ways:

| table | rule says | operation | reads saved | log written | time | statistics after |
|---|---|---|---|---|---|---|
| scattered | **REBUILD** | REORGANIZE | **0%** | 55.7 MB | 485 ms | untouched |
| scattered | **REBUILD** | REBUILD | **0%** | 0.2 MB | 45 ms | full scan |
| sparse | **leave alone** | REORGANIZE | **50%** | 61.3 MB | 2,224 ms | untouched |
| sparse | **leave alone** | REBUILD | **50%** | 0.2 MB | 42 ms | full scan |
| random | REBUILD | REORGANIZE | 31% | 72.9 MB | 2,841 ms | untouched |
| random | REBUILD | REBUILD | 31% | 0.2 MB | 38 ms | full scan |

**The rule rebuilds the table that gains nothing and skips the table that gains
most.** On `random` it pays off, but entirely through the density it recovers,
as scenario C predicted.

Three more things in this table are worth knowing:

- **`REORGANIZE` wrote roughly 300× the log of `REBUILD`.** That holds in SIMPLE
  recovery, which `FragmentationDemo` uses, where `REBUILD` is minimally
  logged. Under FULL recovery, `REBUILD` is fully logged and writes roughly the
  size of the index. `REORGANIZE` is fully logged in every recovery model.
  These tables are small. On a large index in an availability group, all of
  that log is shipped to every replica.
- **`REBUILD` refreshes the index's statistics with a full scan. `REORGANIZE`
  does not touch them.** Some jobs effectively rebuild "for the statistics".
  If that's the goal, `UPDATE STATISTICS ... WITH FULLSCAN` does it without
  rewriting the index.
- **`REORGANIZE` compacts as well as reorders.** It recovered all of `sparse`'s
  wasted space. Measured on its own, it is a cure for low density too. It's
  just slow and log-heavy.

### F — FILLFACTOR, priced

Two identical tables with even ids only, built at `FILLFACTOR` 100 and 80. The
same 10,000 random odd ids go into both, into the gaps in the key range, which
is the worst case for a full page.

| | before: reads vs FF100 | pages added | fragmentation after | density after |
|---|---|---|---|---|
| `FILLFACTOR 100` | 1.00 | **2,803** | 97.95% | 54.89% |
| `FILLFACTOR 80` | **1.21** | **67** | 3.92% | 88.34% |

`FILLFACTOR 80` costs 21% more reads on every scan before a single row arrives:
it is scenario B by design. In return it absorbed the inserts with 67 splits
where `FILLFACTOR 100` took 2,803. **After** the inserts the comparison
reverses. Every split left two half-full pages, so `FILLFACTOR 100` ended up at
55% density and reads 1.6× as much as the index that reserved its space up
front.

So `FILLFACTOR` below 100 is worth it for an index whose inserts land all over
its key range, and is pure cost for an ever-increasing key (identity, sequence,
date), whose inserts all go at the end.

## How to read the output

`02-demo.sql` prints six result sets. Result set 1 is the four-table comparison
at the top of this README: both DMV columns, the reads, the buffer pool, and
what the rule would do. Sets 2–5 are the scenarios.

**Result set 6 should be empty.** It collects every row whose verdict was
`unexpected`, `INCONCLUSIVE` or `MARGINAL`. If anything appears there, it's
either a real difference on your build or storage, or a condition the scenario
couldn't control. Read it before trusting the rest.

## Why offline/online, and not DROPCLEANBUFFERS

A cold-cache measurement needs the table's pages out of memory. The usual tool,
`DBCC DROPCLEANBUFFERS`, empties the buffer pool **of the whole instance**,
which breaks this repo's rule against instance-wide cache flushes.

Taking one database offline releases its pages and nobody else's. Scenario D
checks that it worked before trusting any number: it counts the database's
pages still in the buffer pool after the cycle (about 250, from recovery) and
marks every row `INCONCLUSIVE` if the count isn't small.

The cost is the `ROLLBACK IMMEDIATE`: any other session using
`FragmentationDemo` is disconnected. No other database is affected.

## Traps worth stealing

- **`sys.dm_db_index_physical_stats` in its default `LIMITED` mode returns
  `NULL` for `avg_page_space_used_in_percent`.** That's the density column this
  whole topic is about, and nothing errors to tell you. Use `SAMPLED` or
  `DETAILED`, and filter on `index_level = 0`.
- **`sys.dm_db_index_operational_stats.leaf_allocation_count` stayed at zero**
  on the tested build through thousands of page splits. Scenario F counts
  splits as growth in the leaf page count instead, which is deterministic and
  belongs to the one table. The alternative, the `Page Splits/sec` performance
  counter, is instance-wide.
- **Measure log volume with `sys.dm_io_virtual_file_stats` on the log file, not
  with `sys.dm_db_log_space_usage`.** In SIMPLE recovery a checkpoint can
  truncate the log partway through an operation, and the space-used delta
  becomes meaningless. Bytes written to the file are cumulative.
- **Ghost records.** Density measured straight after a big delete is wrong
  until ghost cleanup has run. See scenario B.

## Takeaways

1. **Fragmentation percentage measures page order, and on a warm cache page
   order costs nothing.** Scenario A: 99.97% fragmented, identical reads.
2. **Page density is the real cost.** It is paid in reads *and* in buffer pool
   memory, on every query, whether the cache is warm or cold. Scenario B:
   0.12% fragmented, twice the reads.
3. **A "fragmented" GUID index costs what its density says.** Scenario C: the
   read ratio matched the density ratio to two decimal places.
4. **Out-of-order pages do cost something on a cold read, but only when
   they're scattered.** Page splits from random inserts cut read-ahead I/Os to
   about 38 KB, with about 7× as many of them. A shrink's reversed but contiguous
   pages cost almost nothing.
5. **The 5% / 30% rule acts on the wrong column.** It would rebuild `Scattered`
   for nothing and never touch `Sparse`. Base maintenance on
   `avg_page_space_used_in_percent` and on what the index is used for.
6. **`REBUILD` also refreshes statistics with a full scan; `REORGANIZE` doesn't,
   and it writes far more log.** Know which one your job relies on.
7. **`FILLFACTOR` is a density tax paid in advance.** Pay it for random-insert
   keys. Don't pay it for ever-increasing ones.
8. **Don't shrink data files.** Setup used it precisely because it's the most
   reliable way to fragment an index.

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the single
configuration named under [Prerequisites](#prerequisites), SQL Server 2022 CU25
(16.0.4255.1) on 8 schedulers in a Linux container on NVMe storage, and nowhere
else. No other version, edition, storage type, or configuration has been
exercised, and the measured numbers throughout this README are from that one
instance rather than a general result. Scenario D's I/O figures in particular
depend on storage and read-ahead behaviour.

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
