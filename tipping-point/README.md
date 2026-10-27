# Key lookups and the tipping point

> **The short version:** [Key lookups and the tipping point](https://marlonribunal.com/sqlserver-demos/tipping-point/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

When a nonclustered index finds the rows but doesn't hold every column the
query needs, each row costs a **key lookup** into the clustered index. At some
number of rows, the optimizer decides one scan of the whole table is cheaper
than that many lookups. Five scenarios measure where that point is, what it
tracks, and when it's the wrong call.

## The rule these scenarios are built around

**The tipping point is about pages, not a percentage of rows. And it's priced
for a cold cache. If a query sits near it, cover the query and the question
goes away.**

## Prerequisites

- SQL Server 2016 or later. Developed and tested on **2022 CU25
  (16.0.4255.1)**.
- No sample database. `01-setup.sql` creates its own database,
  `TippingPointDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` for the DMVs.
- About 1.3 GB of free disk. The database reaches about 1.1 GB.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched
- no plan cache flush of any kind

Scenario E creates a covering index and drops it again. `03-cleanup.sql` drops
the database and confirms that none of its files remain.

## Run order

```
01-setup.sql     ~5 s      creates TippingPointDemo, two 1,000,000-row tables
02-demo.sql      ~10 s     about 100 measured executions; prints a summary
03-cleanup.sql   seconds   drops TippingPointDemo
```

Run each file whole (F5). `02-demo.sql` can be re-run without re-running setup.
Through sqlcmd, pass `-I` (`QUOTED_IDENTIFIER` ON, needed by the plan-reading
XML methods).

## How it's built

Two tables hold the same 1,000,000 orders for 100,000 customers, exactly 10
each, so `CustomerID <= @n` matches exactly `10 × @n` rows. A customer's orders
are spread across the table, as in a real orders table:

| table | row size | rows per page | pages |
|---|---|---|---|
| `Demo.Narrow` | ~60 bytes | 132 | 7,576 |
| `Demo.Wide` | ~320 bytes | 25 | 40,000 |

Each has a nonclustered index on `CustomerID` that does **not** include
`Amount`. The query, total `Amount` for the first *N* customers, needs every
matching row's `Amount`, so through that index every row is a lookup.

`Demo.usp_Measure` runs the query one of three ways: as the optimizer
chooses, forced to seek and look up (`INDEX(IX_..._CustomerID)`), or forced
to scan (`INDEX(1)`). It records the plan shape, the logical reads and the
CPU. Every run uses `MAXDOP 1` so the two plans are compared like for like,
and every row count gets its own plan, so no plan is reused across row counts.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25, 8 schedulers.

### A — the sweep

| rows | % of table | Narrow: optimizer picks | seek reads | scan reads | Wide: optimizer picks | scan reads |
|---|---|---|---|---|---|---|
| 1,000 | 0.1% | seek + lookups | 3,194 | 7,591 | seek + lookups | 40,150 |
| 2,000 | 0.2% | seek + lookups | 6,382 | 7,591 | seek + lookups | 40,150 |
| 3,000 | 0.3% | **clustered scan** | 9,573 | 7,591 | seek + lookups | 40,150 |
| 10,000 | 1.0% | clustered scan | 31,896 | 7,591 | seek + lookups | 40,150 |
| 15,000 | 1.5% | clustered scan | 47,843 | 7,591 | **clustered scan** | 40,150 |
| 50,000 | 5.0% | clustered scan | 159,465 | 7,591 | clustered scan | 40,150 |

A seek plus lookups costs **3.19 reads per row**, the depth of the clustered
index, and grows with the rows. A scan costs the table's page count, whatever
the rows. The full 12-point sweep is result set 1.

### B — the flip point, and where the reads cross

| | optimizer switches to a scan at | reads cross at | |
|---|---|---|---|
| `Demo.Narrow` | **2,620 rows** (0.26%) | 2,379 (7,591 ÷ 3.19) | 10% past |
| `Demo.Wide` | **10,810 rows** (1.08%) | 12,586 (40,150 ÷ 3.19) | 14% short |

Bisected to within 50 rows. The optimizer's switch lands close to where the
two plans' reads are equal. It isn't literally counting pages, but pages are
most of what it's weighing.

### C — pages, not percent

The rule of thumb puts the tipping point at "about 0.5% of the table". These
two tables have the same rows, and one flipped at **0.26%** while the other
flipped at **1.08%**. The wide table has 5.3× the pages and flipped 4.1× later.
That's not quite in proportion: a scan's cost has a per-row part too, and both
tables have a million rows. The tipping point grows with the page count. A
percentage of rows is the wrong unit.

### D — warm cache

At each table's flip point, the forced plans' CPU:

| | at | seek + lookups CPU | scan CPU |
|---|---|---|---|
| `Demo.Narrow` | 2,620 rows | **2 ms** | 26 ms |
| `Demo.Wide` | 10,810 rows | **10 ms** | 84 ms |

The optimizer prices a lookup as a random read that may have to come from
disk. On a warm cache, a lookup is a few page touches already in memory, and a
scan still touches every page. At the moment the optimizer switches to the
scan, the lookups were **8 to 13 times cheaper on CPU**. In the sweep, the
narrow table's lookups only caught up with its scan at around 30,000 rows,
eleven times past the flip. On the wide table they were still cheaper at
50,000.

That's the optimizer pricing a cold cache, and on a cold cache it would be
right. For a workload that's always warm, its tipping point is conservative,
which is the safe direction to be wrong in. It's also why "the optimizer
chose a scan, but the seek is faster when I force it" is so often true when
someone tests it on a warm development box.

### E — the covering index

| `Demo.Wide`, 50,000 rows | plan | reads |
|---|---|---|
| without a covering index | clustered scan | 40,150 |
| with `(CustomerID) INCLUDE (Amount)` | **index seek only** | **115** |

With `Amount` in the index, the index alone answers the query. There are no
lookups, so there's nothing to tip, at four times past the old flip point and
at 1/350th of the reads. That's the fix for a query that matters and sits near
its tipping point. The cost is a wider index to maintain on every insert and
update.

## How to read the output

`02-demo.sql` prints three result sets: the full sweep, the verdicts for B to
E, and **anything that didn't behave as predicted, which should be empty.**

## Takeaways

1. **A key lookup costs a walk down the clustered index for every row**, about
   3 reads here. Past a few thousand rows that adds up.
2. **The optimizer switches to a scan close to where the reads cross over**:
   10% past on one table, 14% short on the other.
3. **The tipping point is a page count, not a percentage.** The same rows
   tipped at 0.26% and at 1.08%, depending on row width.
4. **It's priced for a cold cache.** Warm, the lookups were 8 to 13 times
   cheaper on CPU at the point the optimizer gave up on them.
5. **Don't fight the tipping point with hints. Cover the query.** One
   `INCLUDE` column took a 40,150-read scan down to 115 reads.
6. **Estimates decide which side you land on.** A query whose estimate is
   wrong is planned for the wrong row count, which is how the
   [ascending-key](../ascending-key/) topic's report ended up doing 21,000
   lookups.

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
