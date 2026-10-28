# Filtered indexes: when they're used, when they're ignored, and the writes they break

> **The short version:** [Filtered indexes: why yours isn't used](https://marlonribunal.com/sqlserver-demos/filtered-index/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

A filtered index holds only the rows that match its `WHERE` clause: the 500
open orders out of 500,000. It's small, cheap to maintain, and a query for
open orders reads a few pages instead of the table. Then the same query is
sent from the application with the status as a parameter, and it scans the
table. Or a nightly job starts failing with error 1934. This topic measures
when the optimizer can use a filtered index, and the settings every write to
its table now depends on.

## The rule these scenarios are built around

**A cached plan must be correct for any parameter value, so the optimizer
can only use a filtered index when the query's filter is written in the
text, not passed as a parameter. And once a table has a filtered index,
every write to it needs `QUOTED_IDENTIFIER` and `ANSI_NULLS` on.**

## Prerequisites

- **SQL Server 2016 or later.** Developed and tested on **2025 RTM-CU10
  (17.0.5035.5)** and **2022 RTM-CU25 (16.0.4255.1)**, Linux containers;
  CI also runs it on 2019.
- No sample database. `01-setup.sql` creates its own database,
  `FilteredDemo` (about 120 MB).
- Permission to `CREATE DATABASE`.
- Run the scripts with **`QUOTED_IDENTIFIER ON`**: the default in SSMS and
  Azure Data Studio. With `sqlcmd`, pass `-I`.

## What setup and the demo change on your instance

Nothing outside the database they create. Inside `FilteredDemo`, the demo
switches the database to **forced parameterization** and back, and clears
the database's plan cache (`ALTER DATABASE SCOPED CONFIGURATION CLEAR
PROCEDURE_CACHE`: this database's plans only). `03-cleanup.sql` drops the
database and confirms that none of its files remain.

## Run order

```
01-setup.sql     seconds   creates FilteredDemo: 500,000 orders, a filtered index on the 500 open ones
02-demo.sql      seconds   five scenarios
03-cleanup.sql   seconds   drops FilteredDemo
```

Run each file whole (F5).

## How it's built

```sql
CREATE INDEX IX_Open ON Demo.Orders (CustomerID) INCLUDE (Amount) WHERE Status = 1;

SELECT SUM(Amount) FROM Demo.Orders WHERE Status = 1 AND CustomerID = 42;
```

`Demo.usp_Measure` runs each version of the query twice and measures the
second run: its logical reads, and from its cached plan, whether it used
`IX_Open` and whether the plan carries an `UnmatchedIndexes` warning. The
table is about 14,000 pages.

## The scenarios, and what they showed

The results below come from the tested run on SQL Server 2025 RTM-CU10. 2022
gave the same results, except for the estimates in E.

### A — the value written in

`WHERE Status = 1 AND CustomerID = 42`: **an index seek on `IX_Open`, 31
logical reads.**

### B — the filtered value as a parameter

| how `Status` arrives | uses `IX_Open` | `UnmatchedIndexes` warning | logical reads |
|---|---|---|---|
| a local variable, `@s = 1` | **no** | yes | **14,598** |
| an `sp_executesql` parameter | **no** | yes | **14,598** |
| written in, under **forced parameterization** | **no** | yes | **14,618** |

A plan is compiled once and reused for any value. A plan that reads
`IX_Open` would return wrong results for `@s = 4`, so the optimizer can't
choose it, even when the value is 1 every time. The plan says so: the
`UnmatchedIndexes` element in the plan XML (the warning on the root operator
in SSMS) names the filtered index it couldn't use.

**Forced parameterization** turns every literal into a parameter, so a
query that used the index in A no longer does.

### C — what works

| | uses `IX_Open` | logical reads |
|---|---|---|
| `Status = 1` written in, `CustomerID` as a parameter | **yes** | 31 |
| local variable with `OPTION (RECOMPILE)` | (not cached) | **55**, compilation included |

Only the filter's own column has to be written in. Parameters on other
columns are fine. `OPTION (RECOMPILE)` compiles for the current value, at
the cost of a compilation every run.

### D — SET options

| | result |
|---|---|
| `INSERT` a **closed** order (outside the filter), `QUOTED_IDENTIFIER OFF` | **error 1934** |
| `UPDATE` an order, `ANSI_NULLS OFF` | **error 1934** |
| a procedure **created** with `QUOTED_IDENTIFIER OFF`, called from a session with it ON | **error 1934** |
| query A with `QUOTED_IDENTIFIER OFF` | 14,615 logical reads: **a scan** |

Error 1934: "INSERT failed because the following SET options have incorrect
settings: 'QUOTED_IDENTIFIER'." The index is maintained on every write to
the table, so every write needs the settings, even for rows the index
doesn't hold.

The third row is the surprising one. **A procedure keeps the
`QUOTED_IDENTIFIER` setting it was created with**, whatever the caller's
session uses. A procedure deployed with the classic ODBC `sqlcmd` (which defaults to
`QUOTED_IDENTIFIER OFF` unless given `-I`) fails the day someone adds a
filtered index to a table it writes to.

### E — the filtered index's statistics

10,000 open orders were added for customer 42, so `IX_Open` grew from 500
rows to 10,500.

| | result |
|---|---|
| `IX_Open` statistics: rows / modifications since the update | **500 / 10,000**: not updated automatically |
| estimated rows for customer 42, before `UPDATE STATISTICS` | 124 on the first run; 9,778 on the next |
| after `UPDATE STATISTICS` | 9,900 |
| actual | 10,000 |

The automatic update threshold for a filtered index's statistics is based on
the whole table, 500,000 rows here, not on the rows in the index. A 20-fold
change in the index wasn't enough.

What that did to the estimate varied. On a freshly built database, the
optimizer relied on the stale statistics: 124 rows estimated (102 on 2022).
On the next run, the column statistics SQL Server had auto-created on
`Status` and `CustomerID` gave it a better source, and the estimate was
close. So the demo reports the estimates as `INFO`. Don't count on the
second case: update filtered statistics yourself.

## How to read the output

`02-demo.sql` prints three result sets:

1. every measurement
2. the verdicts, each with its evidence
3. **anything that didn't behave as predicted, which should be empty**

## Traps from building this

- **Changing `PARAMETERIZATION` clears the database's plan cache.** The
  first version of scenario B measured every query and then looked for the
  plans, and found only the ones that ran after the last `ALTER DATABASE`.
  Each plan is now read straight after its query.
- **The stale-statistics estimate wasn't repeatable**, as E describes. The
  first version asserted it, and failed on the second run.

## Takeaways

1. **Write the filtered column's value into the query text.** As a
   parameter, a local variable, or under forced parameterization, the
   filtered index isn't used.
2. **Look for `UnmatchedIndexes`** in the plan: it names the filtered index
   that couldn't be used.
3. **Parameters on other columns are fine.**
4. **Every write to the table needs `QUOTED_IDENTIFIER` and `ANSI_NULLS`
   on**, and procedures keep the setting they were created with. Check old
   procedures before adding a filtered index.
5. **Update a filtered index's statistics yourself.** The automatic update
   counts against the whole table.

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the
configurations named under [Prerequisites](#prerequisites), SQL Server 2025
RTM-CU10 (17.0.5035.5) and 2022 RTM-CU25 (16.0.4255.1) in Linux containers,
and nowhere else. No other version, edition, platform, or configuration has
been exercised, and the measured numbers throughout this README are from
those instances rather than a general result.

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
