# Statistics sampling and skew

Statistics are built from a sample unless you say otherwise, and a histogram
has at most 200 steps no matter what. This topic measures, on 5,000,000 rows
with deliberately skewed data, which estimates each of those limits gets
wrong, and shows the automatic update that quietly undoes your `FULLSCAN`.

## The rule these scenarios are built around

**A sample is good at frequent values and bad at rare and absent ones.
`FULLSCAN` fixes those but can't beat 200 steps. And an automatic update goes
back to sampling unless you persist the rate.**

## Prerequisites

- SQL Server 2016 SP1 CU4 or later for `PERSIST_SAMPLE_PERCENT`. Developed
  and tested on **2022 CU25 (16.0.4255.1)**, compatibility level 160.
- No sample database. `01-setup.sql` creates its own database,
  `StatsSamplingDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` for the plan cache.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched
- no instance-wide plan cache flush (`sp_recompile` only, object scoped)

`02-demo.sql` adds and removes rows and changes the statistic's persisted
sample rate, all in its own table, and puts both back at the end.
`03-cleanup.sql` drops the database and confirms that none of its files remain.

## Run order

```
01-setup.sql     ~10 s     creates StatsSamplingDemo, 5,000,000 skewed orders
02-demo.sql      ~15 s     six estimates under four statistics states
03-cleanup.sql   seconds   drops StatsSamplingDemo
```

Run each file whole (F5). Through sqlcmd, pass `-I`.

## How it's built

`Demo.Orders` holds 5,000,000 orders whose `CustomerID` is skewed in four
tiers, stored in an order unrelated to `CustomerID`, the best case for
sampling:

| tier | customers | orders each | orders |
|---|---|---|---|
| the whale | 1 | 1,000,000 | 1,000,000 |
| big | 20 | 50,000 | 1,000,000 |
| medium, **jagged** | 1,000 | **1,900 for even ids, 100 for odd** | 1,000,000 |
| tail | 1,000,000 | 2 | 2,000,000 |

Six equality estimates (one value from each tier, a second medium value, and a
customer who doesn't exist) are compiled together and read per statement from
the plan, under four states of the `IX_Orders_CustomerID` statistic.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25. The default
sample is random, so its numbers move a little between runs. The verdicts
allow for that.

| value (actual rows) | default sample (9.7%) | `FULLSCAN` | auto update, not persisted | auto update, persisted |
|---|---|---|---|---|
| customer 1, the whale (1,000,000) | 997,580 | 1,000,000 | 1,000,760 | 1,000,000 |
| customer 7, big (50,000) | 49,369 | 50,000 | 49,509 | 50,000 |
| customer 50500, medium even (**1,900**) | 1,051 | **957** | 951 | **957** |
| customer 50501, medium odd (**100**) | 1,051 | **957** | 951 | **957** |
| customer 600000, tail (**2**) | **9.5** | 2 | **9.7** | 2 |
| customer 2000000, nobody (**0**) | **23.6** | 1 | **9.7** | 1 |

### A — the default sample

The default update sampled **9.7%** of the rows. The whale and the big
customers came out within about 1%: frequent values are well represented in
any reasonable sample. The trouble is at the other end:

- **The tail.** A sample sees few of the million two-order customers, so it
  underestimates how many distinct customers exist, and every customer
  without its own step is estimated at **9.5 rows instead of 2**.
- **Values that don't exist** came out at **23.6 rows** instead of the 1 a
  full scan gives. That's the "no rows" lookup a query planned for 24.

### B — FULLSCAN

Exact for the whale, the big customer and the tail, and 1 for the customer
who doesn't exist (the optimizer's floor). For every value that has its own
histogram step, or sits in a uniform range, a full scan is as good as
statistics get.

### C — the 200-step limit

| | actual | `FULLSCAN` estimate |
|---|---|---|
| customer 50500 | 1,900 | **957** |
| customer 50501 | 100 | **957** |

A histogram has **at most 200 steps**. The full scan used 92 for a column with
over a million distinct values. A value that isn't a step is estimated from
the **average** of its step's range. These two neighbours, one 19× bigger than
the other, get the same estimate, half too low for one and nearly ten times
too high for the other. More sampling can't fix this. Filtered statistics on
the important range can, as in the
[correlated-predicates](../correlated-predicates/) topic.

### D — the automatic update

| after `FULLSCAN`, then 80,000 new rows | rows sampled by the automatic update |
|---|---|
| not persisted | **9.56%** |
| `WITH FULLSCAN, PERSIST_SAMPLE_PERCENT = ON` | **100%** |

80,000 new rows is over the automatic-update threshold for a 5,000,000-row
table (about 70,711; see the [ascending-key](../ascending-key/) topic). The
next compile updated the statistic **at the default sample rate**, whatever
the last manual update used. The nightly `FULLSCAN` is undone by the first
busy morning, and the tail and phantom-row estimates come back.

`PERSIST_SAMPLE_PERCENT = ON` (2016 SP1 CU4+) records the rate on the
statistic, and automatic updates then use it: 100% here.

## How to read the output

`02-demo.sql` prints four result sets: estimates by state, the statistics
header at each state (rows, rows sampled, steps, persisted rate), the
verdicts, and **anything that didn't behave as predicted, which should be
empty.**

## Takeaways

1. **Default sampling is fine for frequent values.** The whale and the big
   customers were within about 1%.
2. **It overestimates the long tail and invents rows for absent values**: 9.5
   rows for a 2-row customer, 23.6 for a customer who doesn't exist.
3. **`FULLSCAN` fixes both**, for every value with a step of its own.
4. **No sample rate beats 200 steps.** Neighbours of 1,900 and 100 rows were
   both estimated at 957. Use filtered statistics where it matters.
5. **Automatic updates go back to the default sample.** Persist the rate with
   `PERSIST_SAMPLE_PERCENT = ON`, or the next automatic update undoes your
   `FULLSCAN`.

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
