# Data compression: ROW, PAGE, columnstore, and COMPRESS()

> **The short version:** [Data compression](https://marlonribunal.com/sqlserver-demos/data-compression/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

"Turn on PAGE compression" is the usual answer to a database that's too big
or a scan that reads too much. Often it's the right one. This topic
compresses the same million rows every way SQL Server offers and measures
what each saves and costs. It also covers the cases where compression saves
nothing, costs more than it saves, or quietly doesn't happen at all.

## The rule these scenarios are built around

**Compression trades CPU for pages. Take the trade on data that repeats and
is read far more than it's written. Estimate first. Know that a heap needs a
rebuild or `TABLOCK` to get PAGE compression, and that big off-row values
aren't compressed at all.**

## Prerequisites

- SQL Server 2016 SP1 or later (compression in every edition). Developed
  and tested on **2022 CU25 (16.0.4255.1)**, Linux container.
- No sample database. `01-setup.sql` creates its own database,
  `CompressionDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` (CPU and reads
  are measured through `sys.dm_exec_requests`).
- About 600 MB of free disk.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched

`03-cleanup.sql` drops the database and confirms that none of its files
remain.

## Run order

```
01-setup.sql     ~10 s     creates CompressionDemo, 1,000,000 source rows
02-demo.sql      ~20 s     builds every copy, seven scenarios; prints a summary
03-cleanup.sql   seconds   drops CompressionDemo
```

Run each file whole (F5). The demo builds every table it measures from
`Demo.Source`, so each run starts from the same state.

## How it's built

`Demo.Source` holds order data with the repetition real order tables have:
dates that advance, customer IDs that fit in two bytes, six countries, four
statuses, three delivery notes in a `char(60)` that's mostly trailing spaces,
and amounts far smaller than `decimal(19,4)` allows. CPU and reads are this
session's `sys.dm_exec_requests` counters before and after each step, and
every step runs at `MAXDOP 1`, so the CPU is the work done.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25.

### A — one table, five ways

| compression | size | vs. none | CPU to build |
|---|---|---|---|
| `NONE` | 116.8 MB | | 0.5 s |
| `ROW` | 55.5 MB | 48% | 0.7 s |
| `PAGE` | **22.9 MB** | **20%** | 1.9 s |
| `COLUMNSTORE` | 13.2 MB | 11% | 2.8 s |
| `COLUMNSTORE_ARCHIVE` | **6.4 MB** | **5%** | 2.6 s |

- **ROW** stores each value in as few bytes as it needs: no trailing
  spaces, a small integer in 1 byte instead of 4.
- **PAGE** adds a per-page dictionary of repeated values and prefixes on
  top of that.
- **Columnstore** stores each column separately and encodes runs of
  repeated values.
- **ARCHIVE** adds a general-purpose compressor on top, for data you rarely
  read.

### B — the estimate

| | `sp_estimate_data_compression_savings` | actually built |
|---|---|---|
| `ROW` | 55.8 MB | 55.5 MB |
| `PAGE` | 23.6 MB | 22.9 MB |

The procedure compresses a sample of the table in tempdb and scales the
result up. Here it was **within 3%**. It's the cheapest way to find out
whether a table is worth compressing. Run it before rebuilding a large table.

### C — the same report on each copy

| copy | reads per scan | CPU per scan |
|---|---|---|
| `NONE` | 14,952 | 47 ms |
| `ROW` | 7,098 | 86 ms |
| `PAGE` | **2,930** | **97 ms** |
| `COLUMNSTORE` | 375 | 13 ms |

The trade in one table: PAGE read **one fifth of the pages** and used
**twice the CPU**, because every row read has to be decompressed. Fewer
pages also means less memory to cache them and less I/O when they're not
cached. On a server short of memory or I/O, it's a good deal. On a server
short of CPU, it may not be. Columnstore read fewer pages *and* used less
CPU: it read only the columns the query needed, in batch mode.

### D — data that doesn't repeat

| a GUID and 100 random bytes per row | pages |
|---|---|
| `NONE` | 5,011 |
| `PAGE` | **4,929** (1.6% saved) |

No trailing spaces, no small numbers, no repeated values: nothing for either
method to work with. The rebuild still cost CPU, and every read afterwards
still pays to decompress. Encrypted values, hashes, GUIDs and
already-compressed images look like this. The estimate in B would have said
so.

### E — updating compressed rows

| 300,000 rows, `SET Amount = Amount + 0.01` | CPU |
|---|---|
| `NONE` | 230 ms |
| `PAGE` | **1,554 ms**, and the table grew from 2,930 to **3,809 pages** (+30%) |

Every changed row on a PAGE-compressed page is re-encoded, and a new value
that isn't in the page's dictionary makes the row longer. Rows that no
longer fit split the page. **6.8× the CPU**, and the table loses part of what
compression saved until it's rebuilt. PAGE suits data that's written once
and read many times, not a hot table updated all day. ROW costs much less
on writes.

### F — the heap that wasn't compressed

`CREATE TABLE ... WITH (DATA_COMPRESSION = PAGE)`, no clustered index, the
same 200,000 rows loaded three ways:

| loaded by | pages |
|---|---|
| ordinary `INSERT`s, 1,000 rows at a time | **1,415**, the same as a ROW-compressed heap (1,419) |
| … then `ALTER TABLE ... REBUILD` | 590 |
| one `INSERT ... WITH (TABLOCK)` | 590 |

**A heap only gets PAGE compression from a rebuild, a `TABLOCK` insert, or a
bulk load. Ordinary inserts get ROW compression.** A heap loaded row by row
(most staging and logging tables) has to be rebuilt now and then to keep what
PAGE promises. According to the documentation, a clustered index compresses
its pages as they fill instead; the demo doesn't measure that.

### G — big documents

5,000 JSON documents of 23.6 KB each, each too big to stay in the row:

| | pages |
|---|---|
| `nvarchar(max)`, `NONE` | 15,044 |
| `nvarchar(max)`, `PAGE` | **15,051**, nothing saved |
| `varbinary(max)` holding `COMPRESS(Doc)` | **838**, 1,271 bytes each |

ROW and PAGE compression work on the pages of the row itself. Values stored
**off-row**, on LOB pages, are never compressed. `COMPRESS()` gzips a value,
and `DECOMPRESS()` gave all 5,000 documents back intact. The price: the
column is now `varbinary(max)`. It can't be searched or indexed without
decompressing, and every reader has to call `DECOMPRESS()`. It suits
documents you store and fetch whole: payloads, audit logs, API responses.

## How to read the output

`02-demo.sql` prints three result sets:

1. every measurement: pages, MB, LOB pages, reads, CPU
2. the verdicts
3. **anything that didn't behave as predicted, which should be empty**

## Takeaways

1. **PAGE made the table a fifth of its size**, and columnstore archive a
   twentieth, on data with ordinary repetition.
2. **The estimate is worth running first**: within 3% here.
3. **Compressed rowstore reads fewer pages and spends more CPU**: 1/5 the
   reads, 2× the CPU.
4. **Random data doesn't compress**: 1.6% saved.
5. **Updates cost far more on PAGE** (6.8× the CPU here) and give back part
   of the space.
6. **A PAGE heap filled by ordinary inserts is only ROW-compressed.**
   Rebuild it, or load with `TABLOCK`.
7. **Off-row LOB values aren't compressed** by ROW or PAGE. `COMPRESS()` took
   them from 117 MB to 6.5 MB.

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
