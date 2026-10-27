# MSTVFs and table variables: the fixed guesses, and what replaced them

> **The short version:** [MSTVFs and table variables](https://marlonribunal.com/sqlserver-demos/mstvf-table-variables/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

Multi-statement table-valued functions (MSTVFs) and table variables have no
statistics. For years the optimizer guessed their row counts with a
constant: 1 row, or 100. Plans sized for a handful of rows then met
hundreds of thousands. SQL Server 2017 and 2019 replaced the guesses with
real counts, but only in some situations. This topic measures the guesses,
the fixes, and where each fix stops.

## The rule these scenarios are built around

**Prefer an inline table-valued function to a multi-statement one. Use a
temp table rather than a table variable when the rows will be filtered or
joined on anything but the key, or when the row count varies between
calls.**

## Prerequisites

- SQL Server 2019 or later. Developed and tested on **2022 CU25
  (16.0.4255.1)**, Linux container.
- No sample database. `01-setup.sql` creates its own database, `TvfDemo`.
- Permission to `CREATE DATABASE`.

## What setup changes on your instance

Nothing outside the database it creates. Inside `TvfDemo`, it sets:

- `COMPATIBILITY_LEVEL = 150`, so 2019, 2022 and 2025 all compile the same
  way. Interleaved execution (140+) and table variable deferred compilation
  (150+) are on, and the demo turns each off for one query at a time with
  `USE HINT` to show the older behaviour.
- `LAST_QUERY_PLAN_STATS = ON`, so the demo can read each query's last
  actual plan from `sys.dm_exec_query_plan_stats`.

No instance setting, trace flag or other database is changed.
`03-cleanup.sql` drops the database and confirms that none of its files
remain.

## Run order

```
01-setup.sql     ~10 s     creates TvfDemo: 500,000 orders, the functions, the queries
02-demo.sql      ~10 s     five scenarios; prints a summary
03-cleanup.sql   seconds   drops TvfDemo
```

Run each file whole (F5).

## How it measures

Each query is a procedure. The demo recompiles it, runs it once, and
records from the actual plan the estimated and actual rows where the
function or table variable is read, the join the optimizer chose, and
whether a sort spilled to tempdb. It also records the procedure's logical
reads and CPU. Every query runs at `MAXDOP 1`, so the numbers don't depend
on the number of cores.

Most queries share one shape: take a set of orders, join back to
`Demo.Orders` for the wide columns, and keep each customer's top 3 by
sorting. A wrong estimate hurts twice there: in the join, which chooses
nested loops for a few rows, and in the sort, which gets memory for a few
rows and spills.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25.

### A — an MSTVF's estimate

`Demo.fn_Orders('20230101')` returns 199,697 orders.

| | estimate | join | sort spilled | logical reads |
|---|---|---|---|---|
| MSTVF, legacy CE (compat 110 and below) | **1** | nested loops | yes | 624,815 |
| MSTVF, newer CE (compat 120, 130) | **100** | nested loops | yes | 662,242 |
| MSTVF, interleaved execution (compat 140+) | 199,697 | merge | no | 28,852 |
| inline function | (from statistics) | adaptive | no | **9,172** |

Under the old guesses, 199,697 rows went through a plan built for 1 or
100: a seek into `Orders` per row, and a sort that spilled. Interleaved
execution runs the function *first*, then compiles the rest of the query
with the real count. The inline function did better still. It isn't a
black box: it's expanded into the query like a view, so the optimizer reads
`Orders` directly and uses its statistics.

### B — a filter outside an MSTVF

One customer's orders: `SELECT ... FROM fn(...) WHERE CustomerID = 42`.

| | rows the function built | rows returned | logical reads |
|---|---|---|---|
| MSTVF | **500,000** | 25 | **35,023** |
| inline function | — | 25 | **29** |

An MSTVF runs its body in full and fills its table before the outer query
applies the `WHERE`. Interleaved execution fixes the estimate, not this.
The inline function's `WHERE` was pushed into the query and became a seek
on the `CustomerID` index.

### C — interleaved execution stops at `INSERT`

A's interleaved query, as `INSERT #top3 SELECT ...`:

| | estimate | join | logical reads |
|---|---|---|---|
| MSTVF, `INSERT ... SELECT` | **100** | nested loops | **743,861** |
| inline function, `INSERT ... SELECT` | — | hash | 10,012 |

Interleaved execution only applies when the statement doesn't modify data,
according to the documentation, and here it didn't. The same function that
was estimated correctly in a `SELECT` was back to 100 rows once it fed an
`INSERT`. That makes it fast when tested in SSMS and slow in the ETL job.
The inline function behaved the same either way.

### D — table variables

A table variable holding the same 199,697 orders, then joined to `Orders`:

| | estimate | actual | join | sort spilled | logical reads |
|---|---|---|---|---|---|
| no deferred compilation (compat 140 and below) | **1** | 199,697 | nested loops | yes | 622,809 |
| deferred compilation (compat 150+) | 199,697 | 199,697 | merge | no | 27,225 |
| table variable, `WHERE Status = 'Open'` | **447** | 189,712 | nested loops | yes | **628,229** |
| temp table, `WHERE Status = 'Open'` | 189,712 | 189,712 | merge | no | 21,485 |
| 1st call, compiled for 2 days of orders | 499 | 499 | nested loops | no | 4,723 |
| **2nd call**, 2 years of orders, plan reused | **499** | 199,697 | nested loops | yes | **1,682,454** |

Deferred compilation waits until the table variable has been filled, then
compiles with its row count. It knows **how many** rows there are, not
**what's in them**: a table variable still has no column statistics, so a
filter on one of its columns is a fixed guess (447 here, for 95% of the
rows). A temp table gets statistics automatically.

The count is taken at the first compilation and the plan is cached. The
next call reused the 499-row plan for 199,697 rows and read 1.7 million
pages. This is parameter sniffing, from a table variable. `OPTION
(RECOMPILE)` on the statement avoids it, and so does a temp table, which
the documentation says recompiles when its row count changes enough (not
measured here).

Inserts into a table variable also can't use a parallel plan. The
[parallelism topic](../parallelism/) measures that.

### E — `ROLLBACK`

| rows after `ROLLBACK` | |
|---|---|
| table variable | **3** |
| temp table | 0 |

A table variable isn't part of the transaction, so a `ROLLBACK` doesn't
undo its rows. That's a trap if you expect it to roll back. It's useful
for keeping a log of what happened in a `CATCH` block, after you roll back
the work and before you write the log.

## Traps from building this

- **An MSTVF's plan shows two operators.** The "Table-valued function"
  operator fills the function's table and reports 0 actual rows. The scan
  of that table under it is where the rows come out.
- **That scan's actual rows are counted after the outer `WHERE`**: 25 in
  scenario B. To see the 500,000 rows the function built, the demo reads the
  last execution of the function's own `INSERT` from
  `sys.dm_exec_query_stats`.

## How to read the output

`02-demo.sql` prints three result sets:

1. every measured run: estimate, actual rows, join, spill, reads, CPU
2. the verdicts, each with its evidence
3. **anything that didn't behave as predicted, which should be empty**

## Takeaways

1. **MSTVFs were guessed at 1 or 100 rows.** Interleaved execution fixes
   that, but only in read-only statements. In `INSERT ... SELECT`, the guess
   came back.
2. **An MSTVF builds every row before you filter**: 500,000 rows for 25.
3. **Write inline functions.** They beat the MSTVF even with interleaved
   execution.
4. **Deferred compilation gives table variables a row count, not
   statistics**, and the count is cached with the plan.
5. **Use a temp table** when rows are filtered on non-key columns or the
   count varies.
6. **Table variables ignore `ROLLBACK`.**

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
