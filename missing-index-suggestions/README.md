# Missing-index suggestions: what the DMVs ask for, and what to build instead

> **The short version:** [Missing-index suggestions](https://marlonribunal.com/sqlserver-demos/missing-index-suggestions/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

"Just create the indexes the missing-index DMVs suggest." This topic runs a
six-query workload against a table with no nonclustered indexes, captures
exactly what the DMVs suggest, and measures that design against three indexes
designed by hand for the same workload.

## The rule these scenarios are built around

**Treat a missing-index suggestion as evidence that a query wanted an index,
not as the index to build. Merge overlapping suggestions, put ORDER BY columns
in the key, and refuse INCLUDE lists that copy the table.**

## Prerequisites

- SQL Server 2016 or later. Developed and tested on **2022 CU25
  (16.0.4255.1)**.
- No sample database. `01-setup.sql` creates its own database,
  `MissingIndexDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` for the DMVs.
- About 1 GB of free disk.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched

The missing-index DMVs are instance-wide, but the demo only reads them, for
its own database. Every index it creates, it drops again. `03-cleanup.sql`
drops the database and confirms that none of its files remain.

## Run order

```
01-setup.sql     ~5 s      creates MissingIndexDemo, 1,000,000 orders, the workload
02-demo.sql      ~5 s      workload, suggestions, three designs; prints a summary
03-cleanup.sql   seconds   drops MissingIndexDemo
```

Run each file whole (F5). `02-demo.sql` can be re-run without re-running setup.

## How it's built

`Demo.Orders` holds 1,000,000 orders: 50,000 customers × 20 orders, about 457
a day over six years, 2% of them `Open`, and a 200-byte `Notes` column. It's
clustered on `OrderID` and has **no** nonclustered indexes. The workload:

| | query |
|---|---|
| Q1 | one customer's order dates and amounts |
| Q2 | one customer's spend since a date |
| Q3 | one customer's order statuses |
| Q4 | one customer's spend in one status |
| Q5 | every column of one day's orders (a `SELECT *` in disguise) |
| Q6 | the 50 most recent `Open` orders: `TOP (50) ... ORDER BY OrderDate DESC` |

The demo runs it five times, then reads `sys.dm_db_missing_index_details`,
`_groups` and `_group_stats`. It does that **before** creating any index,
because creating an index on a table discards that table's missing-index
entries. Then it measures each query under:

- **none**: no nonclustered indexes
- **dmv**: every suggestion, created exactly as the DMVs describe it
- **hand**: `(CustomerID, Status, OrderDate) INCLUDE (Amount)`,
  `(Status, OrderDate) INCLUDE (Amount)`, and `(OrderDate)`

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25, 8 schedulers.

### A — what the DMVs suggest

| | equality | inequality | include | claimed impact |
|---|---|---|---|---|
| 1 | `CustomerID` | | | 99.86% |
| 2 | `CustomerID` | `OrderDate` | | 99.86% |
| 3 | `CustomerID`, `Status` | | | 99.86% |
| 4 | `OrderDate` | | `CustomerID`, `Status`, `Amount`, `ShipCity`, `Notes` | 99.80% |
| 5 | `Status` | | `OrderDate`, `Amount` | 93.90% |

Five suggestions for six queries: Q1 and Q3 share the first. Each is correct
about its own query in isolation, and that's the problem the next three
scenarios measure.

### B — overlap

Three suggestions lead with `CustomerID`. The DMVs record one suggestion per
shape of missing index and know nothing about the others.

| query | no index | DMV design | hand design (one index for all four) |
|---|---|---|---|
| Q1 | 31,505 | 63 (lookups) | **3** |
| Q2 | 31,505 | 24 | **3** |
| Q3 | 31,505 | 3 | **3** |
| Q4 | 31,505 | 3 | **3** |

One index keyed `(CustomerID, Status, OrderDate)` with `Amount` included
serves all four, and covers them, so it reads less than the three suggestions
did. Suggestions 1–3 asked for no included columns, so Q1 and Q2 still looked
rows up.

### C — the wide INCLUDE

Suggestion 4 is for Q5, which reads every column. It keys on `OrderDate` and
**includes every other column**, the 200-byte `Notes` among them:

| | size |
|---|---|
| the table (clustered index) | 244.6 MB |
| suggestion 4 | **244.3 MB** |

That's a second copy of the table, sorted by date, to be maintained on every
insert, update and delete. The hand design indexes `OrderDate` alone and
accepts a lookup per row instead: Q5 reads 1,461 pages instead of 19, for a
query that touches 457 rows. Whether that's worth 240 MB and the write cost is
a decision; the DMV doesn't present it as one.

### D — ORDER BY is invisible

Q6 wants the 50 most recent `Open` orders. The missing-index machinery records
the `WHERE` clause and the columns read, **not the `ORDER BY`**. Suggestion 5
keys on `Status` and merely includes `OrderDate`:

| index for Q6 | sort | logical reads |
|---|---|---|
| suggestion 5, on its own: `(Status) INCLUDE (OrderDate, Amount)` | **yes**, all 20,000 Open rows | 82 |
| `(Status, OrderDate) INCLUDE (Amount)` | **no**, reads the last 50 and stops | **3** |

With `OrderDate` in the key, the index returns Open rows already in date order.

One more thing turned up here. With all five suggestions in place, Q6 didn't
use its own suggestion. It used suggestion 4, Q5's table copy keyed on
`OrderDate`, read backwards (150 reads). So the indexes interact, and a
suggestion measured alone and the same suggestion inside a design behave
differently. The demo measures suggestion 5 on its own for this scenario.

### E — the bill

| design | nonclustered indexes | their size |
|---|---|---|
| DMV | 5 | **332.1 MB**, more than the 244.6 MB table |
| hand | 3 | **82.1 MB** |

The hand design reads less than or the same as the DMV design for five of the
six queries (Q5 is the exception, by choice). It does that with three indexes
instead of five, at a quarter of the space, which also means a quarter of the
index
maintenance on every write.

## How to read the output

`02-demo.sql` prints five result sets:

1. the suggestions, with the `CREATE INDEX` each one implies
2. every query's reads under each design, which index it used, and whether it
   sorted or looked up
3. index count and size per design
4. the verdicts
5. **anything that didn't behave as predicted, which should be empty.** Your
   suggestions may differ from the tested build's, and result set 1 shows
   exactly what yours were.

## Takeaways

1. **Suggestions overlap.** Three of five led with the same column. Merge them
   by hand.
2. **Suggestions ignore `ORDER BY`.** Put sort columns in the key, after the
   equality columns, and a `TOP ... ORDER BY` stops sorting.
3. **Suggestions include whatever the query reads**, up to a copy of the
   table. Decide whether a lookup is cheaper than a second copy.
4. **The claimed impact is per query, in isolation.** 99.86% for three indexes
   that one index makes redundant.
5. **Capture the DMVs before you change anything.** Creating any index on the
   table discards its suggestions, and a restart discards them all.
6. **Measure the design, not the suggestion.** Indexes interact: Q6 ignored its
   own suggestion when a different one was there.

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
