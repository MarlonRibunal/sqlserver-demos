# Query Store: catching a plan regression, forcing the fix, and watching it break

A query that ran fine for months is suddenly slow, and nothing was deployed.
Usually a plan was recompiled at an unlucky moment. Query Store records every
plan a query has used and what each one cost, which makes this the one kind of
performance problem you can diagnose after the fact. This topic causes a
regression, finds it in Query Store, forces the good plan back, breaks the
forcing, and on SQL Server 2022 fixes the query with a hint and no code
change.

## The rule these scenarios are built around

**Use Query Store to prove the regression and to force the good plan. Then
watch the forced plan, because forcing fails silently when the schema
changes, and it trades away the cases the forced plan is bad at.**

## Prerequisites

- SQL Server 2016 or later for scenarios A–D. Scenario E (Query Store hints)
  needs **2022** and reports `SKIPPED` on older versions. Developed and tested
  on **2022 CU25 (16.0.4255.1)**, compatibility level 160.
- No sample database. `01-setup.sql` creates its own database,
  `QueryStoreDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` and `VIEW DATABASE
  STATE` for the DMVs and Query Store views.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched
- no instance-wide plan cache flush (`sp_recompile` only, object scoped)

Setup turns Query Store **on for `QueryStoreDemo`** with demo-friendly
settings: `QUERY_CAPTURE_MODE = ALL` (the default, `AUTO`, can skip queries it
considers too cheap) and one-minute intervals. The demo clears that Query
Store at its start, and leaves the index, forcing and hints as setup left
them. `03-cleanup.sql` drops the database and confirms that none of its files
remain.

## Run order

```
01-setup.sql     ~5 s      creates QueryStoreDemo, 1,000,000 skewed orders
02-demo.sql      ~5 s      five scenarios; prints a summary
03-cleanup.sql   seconds   drops QueryStoreDemo
```

Run each file whole (F5). Through sqlcmd, pass `-I`.

## How it's built

The same skewed table as the [slow-in-app topic](../slow-in-app-fast-in-ssms/):
customer 1 owns 300,000 of the 1,000,000 orders, and every other customer
owns about 15. `Demo.usp_CustomerSummary @CustomerID` is best as a seek plus
lookups for a small customer and a scan for customer 1. Which plan gets
cached depends on which customer is asked for first after a compile.

`Demo.usp_QsSnapshot` reads every Query Store plan for the query: its shape,
executions, execution-weighted average reads, and forcing state. Query
Store's catalog views include statistics still held in memory, so nothing
needs flushing first.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25.

| step | customer 45 (15 orders), avg reads | customer 1 (300,000 orders) |
|---|---|---|
| A: good plan, compiled for customer 45 | **51** | |
| B: recompiled with customer 1 first | **21,915** | 21,939 |
| C: good plan forced, recompiled with customer 1 first again | **51** | **968,510** |
| D: the forced plan's index dropped | 22,282 | |
| E: no forcing; `OPTION (RECOMPILE)` as a Query Store hint (2022) | **78** | 21,975 |

### A — the good plan

Compiled for a small customer: seek on `IX_Orders_CustomerID`, then a lookup
per row. 51 reads a call.

### B — the regression

The plan is evicted (here by `sp_recompile`; in real life by a restart, memory
pressure or a statistics update), and the next call happens to be for
customer 1. That call compiles a scan, right for customer 1, and every small
customer after it gets the scan too: **21,915 reads instead of 51**.

Query Store now holds two plans for the same query, with the evidence side by
side:

| plan | shape | executions | avg reads |
|---|---|---|---|
| the first plan | seek + lookups | 20 | 48 |
| the new plan | scan | 21 | 21,915 |

That comparison is what the *Regressed Queries* report in SSMS makes for you.

### C — forcing the good plan

```sql
EXEC sys.sp_query_store_force_plan @query_id = <q>, @plan_id = <good plan>;
```

After forcing, the procedure was recompiled with **customer 1 asked for first
again**, the call that caused the regression, and still got the good plan.
Small customers were back at 51 reads.

That's the trade forcing makes. Customer 1 now pays for a seek plus 300,000
lookups, **968,510 reads** against a scan's 21,939. Forcing fixes the common
case at the expense of the rare one. The
[parameter-sniffing](../parameter-sniffing/) topic covers the alternatives,
and so does scenario E.

**A detail you'll see in Query Store:** the forced executions were recorded
under a **new `plan_id`** with the same shape, not under the forced plan's own
id. The plan was recompiled under forcing rather than reused byte for byte.
Look for the forced plan's *shape* in the runtime statistics, not just its
id.

### D — forcing breaks

| after `DROP INDEX IX_Orders_CustomerID` | |
|---|---|
| the 5 calls | **all succeeded**, as scans |
| the forced plan's `force_failure_count` | **1** |
| `last_force_failure_reason_desc` | **`NO_INDEX`** |

A forced plan is a recipe that names specific objects. Drop the index it uses
and the recipe can't be followed. The query doesn't fail: SQL Server compiles
a plan of its own and runs it. But **forcing has silently stopped working**,
and the only record is in Query Store. Check `force_failure_count` after any
index change on a database that forces plans.

### E — a Query Store hint (SQL Server 2022+)

```sql
EXEC sys.sp_query_store_set_hints @query_id = <q>, @query_hints = N'OPTION (RECOMPILE)';
```

Hints attached by `query_id`, with no change to the procedure, which matters
when the code belongs to a vendor. With `RECOMPILE`, every call is compiled
for its own customer. Customer 1 got its scan (21,975 reads), customer 45 its
seek (78), and nothing had to be forced. The price is a compile on every
call. The demo removes the hint afterwards.

## How to read the output

`02-demo.sql` prints four result sets: the Query Store plans at each step,
average reads per call, the verdicts, and **anything that didn't behave as
predicted, which should be empty.** On 2019 and earlier, scenario E appears
there as `SKIPPED`.

## Takeaways

1. **Query Store turns "it got slow" into evidence**: two plans for one query,
   48 reads against 21,915.
2. **Forcing a plan survives the recompile that caused the regression.**
   Small customers went back to 51 reads.
3. **Forcing trades away the cases the forced plan is bad at.** Customer 1
   went from 21,939 reads to 968,510.
4. **Forcing fails silently** when an object it depends on changes. Watch
   `force_failure_count` and `last_force_failure_reason_desc`.
5. **Forced executions can appear under a new `plan_id`.** Identify them by
   shape.
6. **On 2022, Query Store hints fix a query without touching its code**, and
   without forcing anything.

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the single
configuration named under [Prerequisites](#prerequisites), SQL Server 2022 CU25
(16.0.4255.1) at compatibility level 160, and nowhere else. No other version,
edition, compatibility level, or configuration has been exercised, and the
measured numbers throughout this README are from that one instance rather
than a general result.

Run them only on a scratch instance you can afford to lose, and read every
script before you run it. You alone are responsible for reviewing, testing,
and deciding whether to run anything here.

To the fullest extent permitted by law, the author provides these scripts
WITHOUT WARRANTY OF ANY KIND, express or implied, and shall not be liable for
any claim, damages, data loss, service interruption, or other liability arising
from or in connection with their use. See the
[full disclaimer](../README.md#disclaimer).
