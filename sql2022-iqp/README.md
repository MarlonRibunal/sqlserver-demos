# SQL Server 2022 query processing: plans that fix themselves, and how to tell

SQL Server 2022 added features that change a query's plan with no change
to its code: more than one cached plan for one statement, hints attached by
the engine, memory grants corrected across restarts. When they work, a
regression disappears. When you're troubleshooting, the plan you see may
not be the plan you'd expect. This topic triggers three of them and shows
where each leaves its evidence.

## The rule these scenarios are built around

**At compatibility level 160 with Query Store on, the engine adjusts plans
by itself. Before you tune a query, check
`sys.query_store_query_variant`, `sys.query_store_query_hints` and
`sys.query_store_plan_feedback`: the engine may already be acting on it.**

## Prerequisites

- **SQL Server 2022 or later.** Developed and tested on **2022 CU25
  (16.0.4255.1)**, Linux container. CI also runs it on 2025. On 2019 and
  earlier the scripts still run, and the demo reports every scenario as
  `SKIPPED`.
- No sample database. `01-setup.sql` creates its own database, `IqpDemo`.
- Permission to `CREATE DATABASE`.

## What setup and the demo change on your instance

Nothing outside the database they create. Inside `IqpDemo`:

- compatibility level **160**, set explicitly so that 2025 (whose default
  is 170) compiles like 2022. Scenario A moves it to 150 and back.
- **Query Store** on, `READ_WRITE`, capture mode `ALL`. The demo clears it
  at the start and the end.
- the demo **restarts `IqpDemo`** (`OFFLINE`, then `ONLINE`) at the start.
  Anyone else connected to it is disconnected.
- the demo empties **`IqpDemo`'s plan cache** with `ALTER DATABASE SCOPED
  CONFIGURATION CLEAR PROCEDURE_CACHE`, which affects that database's
  plans only. It never runs `DBCC FREEPROCCACHE`.
- scenario C turns `MEMORY_GRANT_FEEDBACK_PERSISTENCE` off and back on.

`03-cleanup.sql` drops the database and confirms that none of its files
remain.

## Run order

```
01-setup.sql     ~20 s     creates IqpDemo: 1,000,000 orders, the queries, the harness
02-demo.sql      ~10 s     three scenarios; prints a summary
03-cleanup.sql   seconds   drops IqpDemo
```

Run each file whole (F5).

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25.

### A — parameter-sensitive plan (PSP) optimization

`Demo.q_ByCustomer @CustomerID`. Customer 1 has 500,000 orders; every
other customer has one. Customer 600042 runs first, so the plan is
compiled for 1 row:

| | customer 600042 (1 order) | then customer 1 (500,000 orders) |
|---|---|---|
| compatibility level 150 | 77 reads | **1,500,880 reads**: the 1-row plan, reused |
| compatibility level 160 | 103 reads | **17,124 reads**: a plan of its own |

| Query Store, at 160 | |
|---|---|
| `sys.query_store_query_variant` | 2 variant queries under 1 dispatcher plan |

Before 2022, a statement had one cached plan, compiled for the first
parameter value it saw. This is parameter sniffing (see
[that topic](../parameter-sniffing/)). With PSP, the statement gets a
**dispatcher plan** that checks the parameter against the statistics
histogram and picks one of up to three **variants**, each compiled for its
own range of row counts. In the plan cache the statement's text ends in
`option (PLAN PER VALUE(...))`. Query Store records each variant as a query
of its own, linked to the parent through `sys.query_store_query_variant`.

PSP only kicks in when the data is skewed enough. The first version of
this data had 500,000 rows for customer 1 and 50 for every other customer.
PSP didn't trigger, and the
`parameter_sensitive_plan_optimization_skipped_reason` extended event gave
the reason as `SkewnessThresholdNotMet`. At 500,000 against 1 it did.
That's what worked on the tested build, not a documented threshold.

### B — cardinality estimation (CE) feedback

`Demo.q_RegionArea`: `WHERE Region = 7 AND Area = 75`, two correlated
filters (area 75 is in region 7), with an index on each. The demo runs it
until feedback appears, up to 61 times:

| | returned |
|---|---|
| `sys.query_store_plan_feedback` | `CE Feedback`, **`VERIFICATION_REGRESSED`** |
| Query Store hint from CE feedback, afterwards | none |
| reads, first execution / after the feedback | 16,144 / 16,053 |

CE feedback watches a repeating query's estimates against its actual rows.
When one of the estimator's assumptions looks wrong, it tries a hint that
changes that assumption, as a Query Store hint. Then it checks the result:
it keeps the hint if the query got better, and removes it if not. Here the
engine analysed the query with no setting changed. The hint it tried
didn't help, and it took the hint back off. In an earlier prototype of the
same query, the feedback verified (`VERIFICATION_PASSED`) and left
`ASSUME_JOIN_PREDICATE_DEPENDS_ON_FILTERS` attached. So the demo's verdict
is only that the analysis happened. The outcome is reported as it comes
out.

Two other shapes were tried while building this, and neither produced a
recommendation:

- a `TOP` whose row goal was badly wrong. The engine's own telemetry
  event, `query_ce_feedback_telemetry`, did record a row goal misestimate of
  466×
- three correlated filters

### C — memory grant feedback, kept in Query Store

`Demo.q_Grant` sorts a customer's orders. It's compiled for customer 1
(500,000 rows) and run for customer 600042 (1 row):

| | persistence ON | persistence OFF |
|---|---|---|
| execution 1 | **110,152 KB** granted | 110,152 KB |
| execution 2 | **3,016 KB** | 3,016 KB |
| execution 5 | 3,016 KB | 3,016 KB |
| first execution after the plan cache is cleared | **3,016 KB** | **110,152 KB** again |

Memory grant feedback (row mode, from 2019) corrects a grant after it's
seen what the query actually used. Before 2022, the correction lived only
with the cached plan. Anything that removed the plan threw the correction
away, and the next execution reserved 110 MB to sort one row again: the
OFF column shows that. In 2022,
with Query Store on, the correction is saved in
`sys.query_store_plan_feedback` and applied to the plan when it's compiled
again.

### Not demonstrated: DOP feedback

DOP feedback (2022) lowers a repeating query's degree of parallelism when
the extra threads don't pay for themselves. It's off by default
(`DOP_FEEDBACK` in `sys.database_scoped_configurations` reads 0). With it
turned on, an 8-core container ran a parallel aggregate 40 times, and
none of the `dop_feedback_*` extended events fired. Why wasn't
established, so it's left out rather than shown unreliably.

## Traps from building this

- **A compatibility level changed inside a procedure didn't apply** to the
  queries that procedure ran next. At "150", the first version still got
  PSP. The demo changes each setting in a batch of its own.
- **Query Store outlives a demo run.** Hints, feedback and variants from the
  first run would steer the second. The demo clears Query Store first and
  checks that nothing is left.
- **The feedback is saved in the background, and only once.** On 2025 in
  CI, the second demo run's correction was lost when the cache was cleared.
  Locally, a second run's feedback never reached Query Store at all:
  `QUERY_STORE CLEAR` emptied Query Store, but the engine still remembered
  in memory that it had saved that feedback. The demo now restarts
  `IqpDemo` (`OFFLINE`, `ONLINE`) at the start, and waits until the
  feedback row is in Query Store before clearing the cache.
- **Looking for a feedback row that isn't there was slow**: about 20 s per
  query of `sys.query_store_plan_feedback` on the tested build, so the wait
  is bounded by the clock.
- **A sort that keeps only a few rows never spills.** `TOP` with `ORDER BY`
  uses a top-N sort, which holds just those rows. The first version of C
  waited for a spill that couldn't happen. Shrinking an oversized grant is
  the reliable direction to show.

## How to read the output

`02-demo.sql` prints three result sets:

1. every measurement: reads, grants, and what Query Store holds
2. the verdicts, each with its evidence
3. **anything that didn't behave as predicted, which should be empty**
   on 2022 and later (on 2019, the three `SKIPPED` rows)

## Takeaways

1. **PSP gives a skewed parameter more than one plan.** At 150, the big
   customer read 1.5 million pages. At 160, 17,124.
2. **CE feedback tries hints by itself, and takes them back** when they
   don't help. Look in `sys.query_store_query_hints` (`source_desc = 'CE
   feedback'`) and `sys.query_store_plan_feedback`.
3. **Memory grant corrections now survive** a cleared plan cache (tested
   here), and according to the documentation a restart or failover too,
   when Query Store is on.
4. **All of it needs compatibility level 160, and most of it needs Query
   Store.** A database restored from an older server keeps its old level.

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
