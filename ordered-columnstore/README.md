# Ordered columnstore indexes: what ORDER buys a range query, and when it stops

> **The short version:** [Ordered columnstore indexes (SQL Server 2022 and 2025)](https://marlonribunal.com/sqlserver-demos/ordered-columnstore/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

A columnstore index skips a rowgroup when the query's range falls outside
that rowgroup's minimum and maximum: segment elimination. When rows were
loaded in no particular order, every rowgroup holds every date, and nothing
is skipped. SQL Server 2022 added `ORDER` to clustered columnstore indexes.
SQL Server 2025 extends it to nonclustered columnstore indexes and to online
builds. This topic measures how many segments one month's query reads, and
what undoes the ordering.

## The rule these scenarios are built around

**`ORDER` sorts the rows once, when the index is built or rebuilt. Built at
MAXDOP 1, one month of four years sat in one rowgroup and the rest were
skipped. A parallel build overlaps the ranges, and rows loaded afterwards
aren't sorted in, until the next `REBUILD`.**

## Prerequisites

- **SQL Server 2022 or later.** Developed and tested on **2025 RTM-CU10
  (17.0.5035.5)** and **2022 RTM-CU25 (16.0.4255.1)**, Linux containers
  with 8 CPUs. Scenarios A to C run on both; scenario D shows what 2025
  added, and the errors 2022 raises instead. On 2019 and earlier the scripts
  still run, and the demo reports every scenario as `SKIPPED`.
- No sample database. `01-setup.sql` creates its own database,
  `OrderedCsDemo` (about 250 MB).
- Permission to `CREATE DATABASE`.

## What setup and the demo change on your instance

Nothing outside the database they create. `03-cleanup.sql` drops the
database and confirms that none of its files remain.

## Run order

```
01-setup.sql     ~1 min    creates OrderedCsDemo: 4,000,000 rows, plus 1,048,576 to add later
02-demo.sql      ~2 min    four scenarios; rebuilds Demo.CS for each
03-cleanup.sql   seconds   drops OrderedCsDemo
```

Run each file whole (F5).

## How it's built

`Demo.Source` holds 4,000,000 sales rows with `OrderDate` spread over 2022
to 2025, in no particular order. Each scenario copies it into `Demo.CS` and
builds a columnstore index there. The query is one month's total:

```sql
SELECT SUM(CAST(Amount AS bigint)) FROM Demo.CS
WHERE OrderDate BETWEEN '2023-03-01' AND '2023-03-31';
```

The measure is `last_columnstore_segment_reads` and
`last_columnstore_segment_skips` from `sys.dm_exec_query_stats`: the counts
`SET STATISTICS IO` prints as "Segment reads N, segment skipped M", in a form
the script can keep. The query is in a procedure, so its entry is easy to
find.

## The scenarios, and what they showed

The numbers below come from the tested runs. 2022 and 2025 matched except
where shown.

### A — unordered against ordered

| index on `Demo.CS` | rowgroups | segments read / skipped |
|---|---|---|
| `CREATE CLUSTERED COLUMNSTORE INDEX` | 5 | **5 / 0** |
| `... ORDER (OrderDate) WITH (MAXDOP = 1)` | 4 | **1 / 3** |

Unordered, March 2023 is in every rowgroup, so all five are read. Ordered,
it's in one.

### B — an ordered index built in parallel

| index on `Demo.CS` | rowgroups | segments read / skipped |
|---|---|---|
| `... ORDER (OrderDate) WITH (MAXDOP = 4)` | 6–7 | **4–5 / 2–3** |

Each thread sorts its own share of the rows, so the rowgroups' date ranges
overlap and the month spans several of them. Run to run the count varied by
one. **For the full benefit, build ordered indexes at `MAXDOP = 1`**, and
accept the longer build.

### C — new rows, and REBUILD

| `Demo.CS`, ordered at MAXDOP 1 | rowgroups | segments read / skipped |
|---|---|---|
| as built | 4 | 1 / 3 |
| after a `TABLOCK` load of 1,048,576 rows | 10 | **7 / 3** |
| after `ALTER INDEX ... REBUILD WITH (MAXDOP = 1)` | 5 | **1 / 4** |

The load was parallel, and became six new compressed rowgroups. Each one
holds every date, because the new rows aren't merged into the existing
order. The query went from one segment read to seven. `REBUILD` sorted
everything again.

### D — what SQL Server 2025 added

| | 2022 | 2025 |
|---|---|---|
| `CREATE NONCLUSTERED COLUMNSTORE INDEX ... ORDER (OrderDate)` on a rowstore table | **error 35342**: "specifying ORDER is not a valid option for creating the non-clustered columnstore index" | created; 1 read / 1 skipped |
| `CREATE CLUSTERED COLUMNSTORE INDEX ... ORDER (OrderDate) WITH (ONLINE = ON)` | **error 10679**: "Online columnstore index is not supported with ORDER clause" | created; 1 read / 3 skipped |

On 2025 a rowstore table with a primary key can have an ordered
nonclustered columnstore index for analytics, and an ordered index can be
built or rebuilt without taking the table offline.

## How to read the output

`02-demo.sql` prints three result sets:

1. every measurement
2. the verdicts, each with its evidence
3. **anything that didn't behave as predicted, which should be empty**
   on 2022 and later (on 2019 and earlier, the `SKIPPED` rows)

The verdicts claim directions, not exact counts: the rowgroup counts depend
on how many CPUs build and load the data. Scenario B reports `INCONCLUSIVE`
on a server with one CPU.

## Traps from building this

- **`OPTION (RECOMPILE)` hides the measurement.** A recompiled query isn't
  cached, so `sys.dm_exec_query_stats` has no row for it. The query is in a
  procedure instead.
- **The load into the ordered index was parallel**, so 1,048,576 rows made
  six rowgroups, not one. Each held the full date range.

## Takeaways

1. **`ORDER` turned a five-segment read into one** for a one-month query.
2. **Build ordered indexes at `MAXDOP = 1`.** At MAXDOP 4, four or five
   segments were read.
3. **New rows aren't sorted in.** After a load, seven segments were read;
   schedule a `REBUILD` after big loads.
4. **SQL Server 2025 allows `ORDER` on nonclustered columnstore indexes and
   with `ONLINE = ON`**; 2022 raises errors 35342 and 10679.

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the
configurations named under [Prerequisites](#prerequisites), SQL Server 2025
RTM-CU10 (17.0.5035.5) and SQL Server 2022 RTM-CU25 (16.0.4255.1) in Linux
containers, and nowhere else. No other version, edition, platform, or
configuration has been exercised, and the measured numbers throughout this
README are from those instances rather than a general result.

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
