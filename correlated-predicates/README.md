# Correlated predicates: when two columns aren't independent

> **The short version:** [Correlated predicates](https://marlonribunal.com/sqlserver-demos/correlated-predicates/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

`WHERE City = 'Paris' AND Country = 'France'` matches every Paris row, because
Paris is in France. The optimizer doesn't know that. It sees two predicates
and has to guess how they overlap. This topic measures the guesses of both
cardinality estimators against the truth, then the three fixes, including
what each does to a query whose true answer is zero.

## The rule these scenarios are built around

**The optimizer assumes your columns are unrelated (legacy) or only partly
related (new CE). Where they're hierarchical, tell it: multi-column statistics
for the common case, filtered statistics for the important values, and a hint
where nothing else fits. And know that each fix has a blind spot.**

## Prerequisites

- SQL Server 2016 SP1 or later (for `USE HINT`). Developed and tested on
  **2022 CU25 (16.0.4255.1)**, compatibility level 160.
- No sample database. `01-setup.sql` creates its own database,
  `CorrelationDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` for the plan cache.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed. The legacy estimator is reached with
  `USE HINT ('FORCE_LEGACY_CARDINALITY_ESTIMATION')`.
- no database scoped configuration changed
- no trace flag set
- no existing database touched
- no instance-wide plan cache flush (`sp_recompile` only, object scoped)

The extra statistics `02-demo.sql` creates are dropped again by the demo.
`03-cleanup.sql` drops the database and confirms that none of its files remain.

## Run order

```
01-setup.sql     ~5 s      creates CorrelationDemo, 1,000,000 addresses
02-demo.sql      seconds   eight estimates under three statistics states
03-cleanup.sql   seconds   drops CorrelationDemo
```

Run each file whole (F5). Through sqlcmd, pass `-I`.

## How it's built

`Demo.Addresses` holds 1,000,000 rows with a strict hierarchy:

| | values | rows each |
|---|---|---|
| City | 200 (city 1 is Paris) | 5,000 |
| Country | 20, ten cities each (France has Paris; Japan doesn't) | 50,000 |
| Continent | 5, four countries each (France is in Europe) | 200,000 |

Each column has a full-scan statistic, and the data is perfectly uniform. The
**only** thing the estimator can get wrong is the relationship between the
columns.

Eight `COUNT` queries live in one procedure, so all eight estimates come from a
single compile. They're captured under three statistics states: single-column
only; plus `CREATE STATISTICS ... (City, Country, Continent)`; plus
`CREATE STATISTICS ... (City) WHERE Country = 'France'`. Every estimate is read
per statement from the plan XML.

## The scenarios, and what they showed

The numbers below come from the tested run. Every one matched the arithmetic
in the right-hand column exactly.

### A — two correlated predicates

`City = 'Paris' AND Country = 'France'`. The truth is **5,000**.

| estimator | estimate | the arithmetic |
|---|---|---|
| legacy | **250** | 1,000,000 × 1/200 × 1/20: independence, so multiply |
| new (2014+) | **1,118** | 1,000,000 × 1/200 × (1/20)^½: exponential backoff |

Legacy is 20× short and the new estimator 4.5× short. Exponential backoff
assumes *some* correlation: it takes the most selective predicate in full,
then the square root of the next. For a strict hierarchy that still isn't
enough.

### B — a contradiction

`City = 'Paris' AND Country = 'Japan'`. The truth is **0**.

| estimator | estimate |
|---|---|
| legacy | 250 |
| new | 1,118 |

The same numbers as France. Single-column statistics can't tell a
combination that's everywhere from one that never happens.

### C — three predicates

Add `AND Continent = 'Europe'`. The truth is still **5,000**.

| estimator | estimate | the arithmetic |
|---|---|---|
| legacy | **50** | × 1/5 |
| new | **748** | × (1/5)^¼ |

Every extra correlated predicate takes the estimate further from the truth,
100× short for legacy.

### D — the fixes

| query (truth) | single-column | + multi-column stats | + filtered stats | `ASSUME_MIN_SELECTIVITY` hint |
|---|---|---|---|---|
| Paris, France (5,000), new CE | 1,118 | **5,000** | **5,000** | **5,000** |
| Paris, France (5,000), legacy | 250 | **5,000** | 5,000 | |
| **Paris, Japan (0)**, new CE | 1,118 | **5,000** ⚠ | 1,118 | |
| Paris, France, Europe (5,000), new CE | 748 | **5,000** | **1,000** | **5,000** |

- **Multi-column statistics** on `(City, Country, Continent)` carry a density
  for each leading prefix: 1/200 for `(City, Country)` and for all three.
  Both estimators use it, so France is exact. But a density is an **average**:
  it knows how many distinct combinations exist, not which ones. "Paris,
  Japan" also estimates 5,000, worse than before, when the truth is zero.
  Column order matters too: only leading prefixes get a density.
- **Filtered statistics** on `City WHERE Country = 'France'` know Paris has
  5,000 rows in France, exactly, and nothing about Japan, which stays at
  1,118. With a third predicate they fix only the two columns they cover.
  Continent is treated as independent again: 5,000 × 1/5 = 1,000. They're for
  the specific values that matter, one statistic per value.
- **`ASSUME_MIN_SELECTIVITY_FOR_FILTER_ESTIMATES`** tells the new estimator to
  assume full correlation: the most selective predicate alone, 5,000, for two
  predicates or three. It's a query hint, so it fixes exactly the query it's
  on, and it's wrong in the other direction for columns that really are
  independent.

An index on `(City, Country)` creates the same density vector as the
multi-column statistic, with the same blind spot.

## How to read the output

`02-demo.sql` prints three result sets: every estimate under each statistics
state side by side, the verdicts against the arithmetic above, and **anything
that didn't behave as predicted, which should be empty.**

## Takeaways

1. **Legacy multiplies selectivities; the new CE backs off.** For a strict
   hierarchy both underestimate, by 20× and 4.5× with two predicates.
2. **Each extra correlated predicate makes it worse.** Three predicates:
   legacy 100× short.
3. **Single-column statistics can't tell "always together" from "never
   together".** Paris-France and Paris-Japan got the same estimate.
4. **Multi-column statistics (or an index) fix the common case and make
   impossible combinations look common.** Paris-Japan went from 1,118 to
   5,000.
5. **Filtered statistics are exact for the value they filter on, and only
   that value.**
6. **`ASSUME_MIN_SELECTIVITY_FOR_FILTER_ESTIMATES` is a scalpel**, for a
   query you know filters on correlated columns.

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

These scripts and this README were written with the help of AI. The results
come from running the scripts on SQL Server, not from the AI. See
[how this was made](../README.md#how-this-was-made).
