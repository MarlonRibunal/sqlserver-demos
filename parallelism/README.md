# Parallelism: what it buys, what it costs, and when it goes wrong

A parallel plan splits one query across several threads. It's why a big
report finishes in a quarter of the time, and why a server full of small
queries runs out of CPU. It's also why `CXPACKET` tops so many wait-stats
lists. This topic measures parallel plans against serial ones, makes one
go badly wrong through data skew, and shows what keeps a plan serial, all
without changing an instance setting.

## The rule these scenarios are built around

**Parallelism trades CPU for elapsed time. It never does less work. Spend it
on queries big enough to deserve it (raise the cost threshold from its
default of 5), and when a parallel query is slow, check whether all the
threads are working or one is doing the job while the others wait.**

## Prerequisites

- SQL Server **2019** or later (`LAST_QUERY_PLAN_STATS`,
  `sys.dm_exec_query_plan_stats`, the `DISALLOW_BATCH_MODE` hint). Developed
  and tested on **2022 CU25 (16.0.4255.1)**, 8 schedulers, Linux container,
  compatibility level 160.
- At least two schedulers. On one, scenarios A–D report `SKIPPED`.
- No sample database. `01-setup.sql` creates its own database,
  `ParallelDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE`.

## What setup changes on your instance

Nothing outside the database it creates:

- no instance setting changed: not `max degree of parallelism`, not `cost
  threshold for parallelism`; the demo reads them, and sets each query's DOP
  with `OPTION (MAXDOP n)`
- no compatibility level changed
- no trace flag set
- no existing database touched
- no instance-wide plan cache flush (`sp_recompile` only, object scoped)

**One database scoped configuration is set, on `ParallelDemo` itself:
`LAST_QUERY_PLAN_STATS = ON`.** It keeps the last *actual* plan of every
cached query, rows per thread included, which is how the demo looks inside a
parallel plan without SSMS. `03-cleanup.sql` drops the database, and the
setting with it.

## Run order

```
01-setup.sql     ~30 s     creates ParallelDemo, 2,000,000 rows
02-demo.sql      ~20 s     five scenarios; prints a summary
03-cleanup.sql   seconds   drops ParallelDemo
```

Run each file whole (F5). Through sqlcmd, pass `-I`.

## How it's measured

Each query is its own procedure. `Demo.usp_Measure` recompiles it, runs it
once to warm up, then runs it N times and reads CPU, elapsed time and DOP
per run from `sys.dm_exec_query_stats`. It also reads this session's
`CXPACKET` + `CXCONSUMER` waits from `sys.dm_exec_session_wait_stats`. Rows
per thread come from the last actual plan
(`sys.dm_exec_query_plan_stats`), and `NonParallelPlanReason` from the
cached plan.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25, 8
schedulers.

### A — a big scan, serial vs parallel

| 2,000,000 rows, scanned and aggregated | elapsed | CPU |
|---|---|---|
| `MAXDOP 1` | 225 ms | 225 ms |
| `MAXDOP 4` | **60 ms** | **233 ms** |

Four threads finished in a quarter of the time and used slightly *more* CPU
than one. Parallelism divides the elapsed time; the work stays the same, plus
the cost of coordinating the threads. That's a good trade for one big
report on an idle server. On a server already short of CPU, it isn't.

### B — skew: one thread does the work

```sql
SELECT MAX(rn) FROM (SELECT rn = ROW_NUMBER() OVER (PARTITION BY SkewKey ORDER BY Amount)
                     FROM Demo.Sales) AS x
OPTION (MAXDOP 4, USE HINT ('DISALLOW_BATCH_MODE'));
```

To number each partition, a row-mode parallel plan sends every row to a
thread chosen by **hashing the partition key** (a Repartition Streams
exchange). `SkewKey` is 1 for 90% of rows, so 90% of rows go to one thread:

| `PARTITION BY` | rows per thread at the Sort | busiest | elapsed | parallelism waits per run |
|---|---|---|---|---|
| `SkewKey`, DOP 4 | 49,200 / **1,851,200** / 49,600 / 50,000 | **92.6%** | **1,214 ms** | **5,834 ms** |
| `SkewKey`, serial | | | 1,294 ms | |
| `EvenKey`, DOP 4 | 499,200 / 500,800 / 500,000 / 500,000 | 25.0% | **316 ms** | 1,245 ms |

At DOP 4 the skewed query was **barely faster than serial**: 1,214 ms
against 1,294. The busy thread did the work while three threads sat idle and
`CXPACKET`/`CXCONSUMER` time piled up, almost 5 seconds of waits per
1.2-second query. The same query on an evenly spread key used all four
threads and ran 4× faster.

This is the case that gives `CXPACKET` its reputation. The wait isn't the
problem, it's the symptom: a parallel query's threads waiting for the
slowest one. **Look at rows per thread before lowering MAXDOP.** The fix is
in the data or the query (a different partitioning, a pre-aggregation, or
batch mode), not in a server-wide setting.

### C — the same query in batch mode

With the hint removed, the 2022 optimizer used **batch mode on rowstore**
(compatibility level 150+, Enterprise or Developer edition). Batch mode's
sort and window aggregate don't repartition rows by the key:

| | rows per thread | elapsed |
|---|---|---|
| row mode (B) | 49,200 / 1,851,200 / 49,600 / 50,000 | 1,214 ms |
| **batch mode** | 505,800 / 500,600 / 494,100 / 499,500 | **205 ms** |

Same data, same skew, **6× faster**. On an edition or level without batch
mode on rowstore, this scenario reports `SKIPPED`.

### D — a query just over the cost threshold

A query whose serial plan costs **6.56**, just over the default cost
threshold of 5, run 50 times each way:

| | per run, elapsed | per run, CPU |
|---|---|---|
| `MAXDOP 1` | 20.2 ms | 20.2 ms |
| `MAXDOP 4` | **6.0 ms** | 21.4 ms |
| no hint (this instance: threshold 5, MAXDOP 0) | 6.8 ms, at **DOP 8** | **25.3 ms** |

With no hint, this instance ran a 20-millisecond query **on 8 threads**,
using 25% more CPU to save 13 ms. A cost threshold of 5 was set in the
1990s, for the hardware of the 1990s. On a busy server, thousands of such
queries a minute is where the CPU goes. Most guidance starts at **50** and
adjusts from there. Raising it changes which queries can go parallel, not
how the big ones run.

(The demo doesn't change the setting. It's instance-wide. The verdict checks
that the unhinted query did what your instance's settings say it should.)

### E — why a plan stayed serial

Four queries that asked for DOP 4 and didn't get it. The cached plan says
why, in `NonParallelPlanReason`:

| query | DOP | `NonParallelPlanReason` |
|---|---|---|
| calls a scalar UDF that reads `GETDATE()` (can't be inlined) | 1 | `TSQLUserDefinedFunctionsNotParallelizable` |
| `INSERT` into a table variable | 1 | `TableVariableTransactionsDoNotSupportParallelNestedTransaction` |
| `OPTION (MAXDOP 1)` | 1 | `MaxDOPSetToOne` |
| cost 0.003, under the threshold | 1 | *(none)* |

The last row is the one people miss. A cheap plan isn't considered for
parallelism at all, so the plan gives **no reason**. Compare its cost with
the threshold instead. The exact reason strings vary by version: on 2019, a
scalar UDF can show as `CouldNotGenerateValidParallelPlan`, and the demo
accepts both. See also [scalar-udf-inlining](../scalar-udf-inlining/) and
[tempdb](../tempdb/) for table variables.

## How to read the output

`02-demo.sql` prints four result sets:

1. this instance: schedulers, MAXDOP, cost threshold, compatibility level
2. each measured query, per run: DOP, CPU, elapsed, parallelism waits
3. the verdicts
4. **anything that didn't behave as predicted, which should be empty**

## Traps from building this

- **Batch mode hides the skew problem.** The first version of scenario B
  showed no skew on 2022, because batch mode on rowstore was quietly doing
  the work. Row mode needs `USE HINT ('DISALLOW_BATCH_MODE')`.
- **Hash aggregation hides it too.** A `GROUP BY` on the skewed key
  aggregated locally on every thread before repartitioning, so the hot key
  was already one row per thread. Window functions can't do that.
- **`ActualExecutionMode` isn't on the operator.** It sits on each thread's
  counters; the operator itself carries `EstimatedExecutionMode`.

## Takeaways

1. **Parallel is faster, not cheaper.** 225 ms became 60 ms; CPU went from
   225 to 233.
2. **Skew makes a parallel plan serial in all but name**: 92.6% of rows on
   one thread, 1,214 ms against 1,294 serial, and 5.8 s of `CXPACKET` per
   run.
3. **`CXPACKET` is a symptom.** Check rows per thread before you touch
   MAXDOP.
4. **Batch mode doesn't repartition by the key**: the same skewed query ran
   in 205 ms.
5. **The default cost threshold of 5 is too low.** A 20 ms query went to 8
   threads for 25% more CPU.
6. **The plan says why it's serial**, except when it's too cheap to be
   considered; then compare its cost with the threshold.

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
