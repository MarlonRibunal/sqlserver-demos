# The ascending-key problem: estimates for rows the statistics haven't seen

> **The short version:** [The ascending-key problem](https://marlonribunal.com/sqlserver-demos/ascending-key/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

Five scenarios about the most ordinary way statistics go wrong. New rows land
past the end of the histogram, the query that asks about them gets a guess,
and the automatic update that should fix it is waiting for a threshold that a
normal week never reaches.

## The rule these scenarios are built around

**Statistics can be healthy and still blind. On an ascending key, refresh them
on your load schedule, not your fragmentation schedule.**

Any column that only grows has this problem: a load date, an identity, a
sequence, an `OrderDate`. Every new row is later than the last histogram step.
The queries that care most about recent rows ("today", "this week", "since the
last load") ask about nothing else. Scenarios A and B show the blind spot. C
shows why automatic updates don't cover it, D what it costs, and E which
maintenance actually fixes it. That last scenario is the other half of the
[index-fragmentation](../index-fragmentation/) topic.

## Prerequisites

- SQL Server 2016 SP2 or later. Developed and tested on **2022 CU25
  (16.0.4255.1)**, database compatibility level 160.
- No sample database. `01-setup.sql` creates its own database,
  `AscendingKeyDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` for the DMVs.
- About 700 MB of free disk. `AscendingKeyDemo` reaches about 650 MB by the
  end of the demo (390 MB of data, 260 MB of log). Cleanup releases all of it.
- `AUTO_UPDATE_STATISTICS` ON and `AUTO_UPDATE_STATISTICS_ASYNC` OFF on the new
  database. Those are the defaults it inherits from `model`. Scenario C checks
  them and reports `INCONCLUSIVE` rather than a false result if they differ.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed. The legacy cardinality estimator is reached
  with `USE HINT ('FORCE_LEGACY_CARDINALITY_ESTIMATION')`, a query hint.
- no database scoped configuration changed
- no trace flag set. The histogram amendment that trace flag 4139 used to
  provide is reached with `USE HINT ('ENABLE_HIST_AMENDMENT_FOR_ASC_KEYS')`.
- no existing database touched
- no instance-wide plan cache flush (`sp_recompile` only, object scoped)

`03-cleanup.sql` drops `AscendingKeyDemo`, confirms that none of its files
remain, and prints `DBCC TRACESTATUS(-1)` so you can see that the flags this
README mentions were never turned on.

## Run order

```
01-setup.sql     ~5 s      creates AscendingKeyDemo, 1,021,000 orders, the procedures
02-demo.sql      ~10 s     the five scenarios; prints a summary
03-cleanup.sql   seconds   drops AscendingKeyDemo
```

Run each file whole (F5). `02-demo.sql` records its own evidence into
`Demo.DemoResults` and `Demo.ReportRuns`, so you don't have to read any plans.
It resets the statistics between steps with `Demo.usp_MakeStale`, so it can be
re-run without re-running setup.

Not on SSMS? Everything works through sqlcmd. Pass `-I`: it turns on
`QUOTED_IDENTIFIER`, which the plan-reading XML methods need.

```
sqlcmd -S <server> -I -i 01-setup.sql -o setup.txt
sqlcmd -S <server> -I -i 02-demo.sql  -o demo.txt
sqlcmd -S <server> -I -i 03-cleanup.sql
```

## The data

`Demo.Orders` holds 1,000,000 orders spread evenly over 2025, about 2,740 a
day. It is clustered on `OrderID`, with a nonclustered index on `OrderDate`.
The statistics on that index are the subject of the whole topic.

`Demo.usp_MakeStale` produces the state the topic is about, on demand:

1. Remove any 2026 rows.
2. `UPDATE STATISTICS ... WITH FULLSCAN`. The histogram now ends on
   2025-12-31, and the modification counter is zero.
3. Load one busy week of 2026, 3,000 orders a day: 21,000 rows.

The statistics are now as good as SQL Server knows how to make them, applied
to a table that has changed by 2%. They just don't know 2026 exists.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25, 8 schedulers,
MAXDOP 0, cost threshold for parallelism 5, compatibility level 160. Your
magnitudes will differ. The *ratios* and the *verdicts* are the point.

### A — what the statistics know

| | |
|---|---|
| rows when the statistics were built | 1,000,000 — **full scan** |
| modifications since | 21,000 |
| last histogram step | **2025-12-31** |
| latest `OrderDate` in the table | **2026-01-07** |
| rows past the last step | **21,000 — every new row** |

### B — the estimate for rows the histogram has never seen

| question | estimator | estimated | actual |
|---|---|---|---|
| since 2026-01-01 | new | **6,300** | 21,000 |
| since 2026-01-01 | legacy | **1** | 21,000 |
| on 2026-01-03 | new | **1,010** | 3,000 |
| on 2026-01-03 | legacy | **1** | 3,000 |
| last week of 2025 (control) | new | 19,581 | 19,178 |
| last week of 2025 (control) | legacy | 19,523 | 19,178 |

The **legacy** estimator treats the last histogram step as the end of the
world. Past it there is one row: its minimum estimate.

The **new** estimator (compatibility level 120 and up) assumes rows do exist
out there and guesses. On the tested build the range guess was exactly 30% of
the modification counter (0.3 × 21,000 = 6,300). The single-day guess was the
square root of the table's row count (√1,021,000 = 1,010). That's better than
1, but still a third of the truth.

The control week is accurate under both, so the statistics themselves are
fine. They are out of date, not wrong.

### C — why the automatic update never fired

| | modifications |
|---|---|
| threshold under compatibility level < 130: 500 + 20% of rows | 200,500 |
| threshold in force at 130+: MIN(that, √(1000 × rows)) | **31,623** |
| a busy week | 21,000 — **below threshold** |
| compile with 100 changes **under** the threshold | statistics **not updated** |
| compile with 100 changes **over** the threshold | statistics **auto-updated** |

The threshold check runs when a query that *uses* the statistics compiles, not
when the rows are written. The demo moves the modification counter to 100
below and then 100 above the computed threshold, compiles the report each
time, and watches `last_updated`. The boundary is exact.

The square-root formula is what trace flag 2371 used to enable, and it's the
default from compatibility level 130. It's far better than 20% on large tables,
but it still grows with the table: 316,228 changes at 100 million rows, a
million at a billion. A daily load into a big fact table can go weeks without
crossing it, and every one of those days has the blind spot.

### D — what the bad estimate costs

The morning report: top 100 customers by spend since 2026-01-01.

| statistics | estimator | estimate | plan | logical reads | DOP | grant |
|---|---|---|---|---|---|---|
| stale | legacy | **1** | **Index Seek + lookups** | **63,447** | **1** | **1,088 KB** |
| stale | new | 6,300 | Clustered Index Scan | 23,525 | 8 | 10,944 KB |
| fresh | legacy | 21,000 | Clustered Index Scan | 23,525 | 8 | 11,200 KB |
| fresh | new | 21,000 | Clustered Index Scan | 23,525 | 8 | 11,200 KB |

With the **legacy** estimator and stale statistics, the optimizer planned one
lookup and got 21,000 of them: **2.7× the reads** of the scan it would have
chosen, run serially, with a memory grant sized for one row. On this
million-row table that's tens of milliseconds. The ratio is what scales.

With the **new** estimator, the 6,300-row guess was already large enough to
pick the scan, so it got the same plan as fresh statistics. That's a real
result, not a pass. The guess is still 3× short, and a query whose tipping
point falls between 6,300 and 21,000 would get the wrong plan. Plenty of
databases still run the legacy estimator after an upgrade, because
`LEGACY_CARDINALITY_ESTIMATION = ON` is a common way to undo upgrade
regressions. Those databases get row 1.

That 6,300 sits close to this query's tipping point. In one CI run on SQL
Server 2025 RTM-CU10, the new estimator with stale statistics chose the seek
instead. The demo reports that as `INTERMITTENT`, not as a failure.

### E — what actually refreshes the statistics

Each step starts from the same stale state, applies one operation, then
compiles the report under the legacy estimator. That estimator is the sharp
instrument: it says 1 row until the histogram includes 2026.

| operation | `IX_Orders_OrderDate` statistics | legacy estimate | |
|---|---|---|---|
| `ALTER INDEX PK_Orders REBUILD` (the clustered index) | **untouched** | **1** | still stale |
| `ALTER INDEX IX_Orders_OrderDate REORGANIZE` | untouched | 1 | still stale |
| `ALTER INDEX IX_Orders_OrderDate REBUILD` | refreshed, 1,021,000 rows sampled | 21,000 | fixed |
| `UPDATE STATISTICS ... IX_Orders_OrderDate` | refreshed, ~79,000 rows sampled | 20,657–22,579 | fixed |
| `UPDATE STATISTICS ... WITH FULLSCAN` | refreshed, 1,021,000 rows sampled | 21,000 | fixed |
| no maintenance; `USE HINT ('ENABLE_HIST_AMENDMENT_FOR_ASC_KEYS')` | untouched | 18,391 | fixed |

The first row is the one to remember. A fragmentation job most often flags the
**clustered** index, and rebuilding it refreshes the clustered index's own
statistics. The statistics the query needed belong to a different index, so
nothing changed.

"We rebuilt the fragmented index and the query got fast" is very often a
statistics refresh in disguise. It happens only when the rebuild hits the
index whose statistics were stale. If that's the effect you want, a targeted
`UPDATE STATISTICS` gets it without rewriting the index. Even the default
sample (about 8% of rows here) put the new week into the histogram.

The hint is the one fix that needs no maintenance at all. It is the query-level
form of trace flag 4139: at compile time the optimizer reads the column's
current maximum from an index that leads on it, and extends the histogram to
that value. It needs such an index. `IX_Orders_OrderDate` is one. It belongs in a query
you control and can't schedule around, not as a blanket setting.

Trace flags 2389 and 2390 were the legacy estimator's own ascending-key fixes.
They only take effect once a column has been *branded* ascending over several
consecutive statistics updates, and they are trace flags, so this demo leaves
them out. The hint above does the same job without either condition.

## How to read the output

`02-demo.sql` prints six result sets. Sets 1–5 are the scenarios above. Set 4
has two parts: the four report runs side by side, then the verdicts drawn from
them.

**Result set 6 should be empty.** It collects every row whose verdict was
`unexpected` or `INCONCLUSIVE`, or whose plan differed where the README
predicts the same one. Anything in it is either a real difference on your build
or a database setting the scenario couldn't work around. Read it before
trusting the rest.

## Spills: why they are not in the evidence

The legacy plan's one-row memory grant looks like an obvious spill. It was the
first thing tried here, and it doesn't hold up as evidence:

- the actual plan marked the sort `SpillToTempDb` with `WritesToTempDb="0"`
- `sys.dm_exec_query_stats.last_spills` read 0
- `sys.dm_db_session_space_usage` showed no tempdb allocation for the session

Three sources, two answers. So the demo reports the grant itself (1,088 KB
against 11,200 KB) and draws no conclusion about spilling. Evidence that
contradicts itself stays out of the verdicts.

## Takeaways

1. **Healthy statistics can still be blind.** A full-scan histogram knows
   nothing past its last step, and on an ascending key that is exactly where
   the interesting rows are.
2. **Legacy estimator: 1 row. New estimator: a guess.** On the tested build
   that was 30% of modifications for a range and √rows for one value. Neither
   is the answer.
3. **Automatic updates wait for a threshold, not a calendar.** At
   compatibility level 130+ it's √(1000 × rows), which is 31,623 for a million
   rows and grows with the table. A normal load stays under it.
4. **The cost is the plan.** One-row estimates mean seeks and lookups where a
   scan was cheaper, serial plans, and memory grants sized for one row.
5. **Rebuilding an index refreshes that index's statistics, and nothing else.**
   Rebuilding the clustered index did nothing here. `REORGANIZE` never
   refreshes statistics.
6. **Refresh the ascending column's statistics after each load.** A targeted
   `UPDATE STATISTICS` is cheap, and even a default sample captured the new
   range. Tie it to the load, not to index maintenance.
7. **For a query you can't schedule around,
   `ENABLE_HIST_AMENDMENT_FOR_ASC_KEYS`** extends the histogram at compile
   time, with no trace flag and no setting change.

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the single
configuration named under [Prerequisites](#prerequisites), SQL Server 2022 CU25
(16.0.4255.1) on 8 schedulers at compatibility level 160, and nowhere else. No
other version, edition, compatibility level, or configuration has been
exercised, and the measured numbers throughout this README are from that one
instance rather than a general result. The new estimator's guesses in
particular are observations of one build, not documented behaviour.

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
