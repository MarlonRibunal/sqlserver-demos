# Partition elimination traps

Partitioning a table by date promises that a query for one month reads one
month. This topic counts the partitions each query actually opens, and finds
three ways to lose that promise without the query looking any different,
plus the catch in the fix for one of them.

## The rule these scenarios are built around

**Elimination needs a bare partitioning column compared with a value of its
own type. And every index has to be aligned if you ever want to `SWITCH`,
including the one that would have fixed your `MAX`.**

## Prerequisites

- SQL Server 2016 SP1 or later: partitioning is in every edition from 2016
  SP1. Developed and tested on **2022 CU25 (16.0.4255.1)**.
- No sample database. `01-setup.sql` creates its own database,
  `PartitionDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` for the DMVs.
- About 600 MB of free disk.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched

Scenario E switches a partition out **inside a transaction and rolls it
back**, so no data moves. The non-aligned indexes are created and dropped by
the demo. `03-cleanup.sql` drops the database and confirms that none of its
files remain.

## Run order

```
01-setup.sql     ~30 s     creates PartitionDemo, 2,400,000 sales in 25 monthly partitions
02-demo.sql      seconds   five scenarios; prints a summary
03-cleanup.sql   seconds   drops PartitionDemo
```

Run each file whole (F5). `02-demo.sql` can be re-run without re-running setup.

## How it's built

`Demo.Sales` holds 2,400,000 sales, about 100,000 a month through 2024 and
2025, partitioned by `SaleDate` into monthly partitions (25: one per month,
plus an empty one for anything earlier). It's clustered on `(SaleDate, SaleID)`
and has an **aligned** nonclustered index on `SaleID`.

`Demo.usp_Touch` runs a query twice and, for the second run, counts the
partitions of `Demo.Sales` whose `range_scan_count` or `singleton_lookup_count`
in `sys.dm_db_index_operational_stats` went up: the partitions the query
actually opened. That needs no actual execution plan, which a script can't
capture for itself.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25, 8 schedulers.
Every query asks for March 2025.

| query | partitions opened (of 25) | logical reads |
|---|---|---|
| A: `SaleDate >= '20250301' AND SaleDate < '20250401'` | **1** | 1,525 |
| A: the same range as `date` parameters | 2 | 1,529 |
| **B: `YEAR(SaleDate) = 2025 AND MONTH(SaleDate) = 3`** | **25** | **35,958** |
| C: the range as `varchar(20)` parameters | 2 | 1,529 |
| **C: the range as `datetime2(7)` parameters** | **25** | 1,617 |
| **C: the range as `datetimeoffset` parameters** | **25** | 1,617 |

### A — the control

A half-open range on the partitioning column. With literals, the optimizer
knows which partition holds March and opens only that one. With `date`
parameters it's decided at run time, and on the tested build the query opened
March and the next partition and read the same.

### B — a function on the partitioning column

`YEAR(SaleDate) = 2025 AND MONTH(SaleDate) = 3` asks the same question.
Partition elimination works on the partitioning column's **values**, and a
function of the column has none, so every partition is opened and every row
tested: **24× the reads.** It's the same rule as an index seek (see
[non-sargable predicates](../non-sargable-predicates/)), at partition scale.

### C — the parameter's type

The same range passed as parameters of four types:

- **`date`** matches the column and is eliminated.
- **`varchar(20)`** has lower precedence, so it's converted to `date` once
  and is eliminated.
- **`datetime2(7)` and `datetimeoffset`** outrank `date`. The comparison
  can't be made in the column's terms, so **every partition is opened**.

With the wrong types the query still seeks, which is why the reads are only a
little higher. But it can't rule partitions out, so it opens all 25 to look.
An ORM or driver that sends every date as `datetime2` does this to every query
on a date-partitioned table. The cost grows with the partition count, and the
plan doesn't show anything wrong.

### D — MIN and MAX

| query | partitions opened | logical reads |
|---|---|---|
| `MAX(SaleID)` on the **aligned** index | 25 | **3,918** |
| `MAX(SaleDate)`, the partitioning column | 1 | 3 |
| `MAX(SaleID)` on a **non-aligned** index | (one index, not partitioned) | **3** |

`MAX(SaleID)` on an ordinary index is one seek to its end. On an **aligned**
index there's no single end: each partition holds its own slice, ordered on
its own, so every partition has to be read. On the tested build that cost
3,918 pages, far more than one seek per partition. `MAX` of the partitioning
column itself is fine: the last non-empty partition holds it. A
**non-aligned** index, one not built on the partition scheme, gives `MAX`
back its single seek.

### E — a non-aligned index blocks SWITCH

Partitioning usually exists for partition **switching**: moving a whole month
in or out as a metadata-only operation. Tested on `Demo.SwitchTest`, a small
copy partitioned the same way:

| | result |
|---|---|
| E1: `SWITCH PARTITION 2` with a non-aligned index present | **Msg 7733**: *the table is partitioned while index '...NonAligned' is not partitioned* |
| E2: the same after dropping it | switched out instantly, then rolled back |

So the fix for scenario D costs you scenario E. If the table's purpose is
switching, keep every index aligned and accept the `MAX` cost, or keep the
value somewhere else (a sequence, or a small summary table).

## A trap from building this

**A `SWITCH` and the index DDL around it reset the per-partition counters in
`sys.dm_db_index_operational_stats`.** The first version switched
`Demo.Sales` itself, and on the second run every partition count was off by
one. These counters live in a metadata cache, not durable storage.
Switching is now tested on its own table, and a partition whose counter entry
appears during a run is counted from zero.

## How to read the output

`02-demo.sql` prints three result sets: partitions opened and reads per query,
the verdicts, and **anything that didn't behave as predicted, which should be
empty.**

## Takeaways

1. **Filter the bare partitioning column with a half-open range.** One
   partition, one month of reads.
2. **A function on the partitioning column opens every partition.**
   `YEAR()`/`MONTH()` cost 24× the reads.
3. **Pass values of the column's own type.** `datetime2` and
   `datetimeoffset` parameters against a `date` column opened all 25
   partitions; `date` and `varchar` didn't.
4. **`MIN`/`MAX` of a non-partitioning column reads every partition of an
   aligned index**: 3,918 reads against 3.
5. **A non-aligned index fixes that, and blocks `SWITCH`** (Msg 7733).
   Decide which matters more.

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
