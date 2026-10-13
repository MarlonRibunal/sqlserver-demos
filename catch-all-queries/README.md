# Catch-all queries: optional parameters, five ways

Every application has a search screen with optional filters, and every
database behind one has a procedure like this:

```sql
WHERE (@CustomerID IS NULL OR CustomerID = @CustomerID)
  AND (@FromDate   IS NULL OR OrderDate >= @FromDate)
```

This topic writes that search five ways, calls each with four combinations of
arguments, and measures reads, cached plans and whether every version returns
the same answer. One doesn't.

## The rule these scenarios are built around

**A catch-all `WHERE` compiles one plan for every combination, and it's bad
for most of them. Use dynamic SQL with parameters, or `OPTION (RECOMPILE)` if
the statement returns its result rather than assigning it to variables. Never
`COALESCE(@p, col)` on a nullable column.**

## Prerequisites

- SQL Server 2016 or later. Developed and tested on **2022 CU25
  (16.0.4255.1)**, and run in CI on 2019, 2022 and 2025. Scenario A behaves
  differently on 2025 at compatibility level 170; see below.
- No sample database. `01-setup.sql` creates its own database, `CatchAllDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` for the DMVs.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched
- no instance-wide plan cache flush (`sp_recompile` only, object scoped)

`03-cleanup.sql` drops the database and confirms that none of its files remain.

## Run order

```
01-setup.sql     ~5 s      creates CatchAllDemo, 1,000,000 orders, five procedures
02-demo.sql      ~10 s     5 variants x 4 searches; prints a summary
03-cleanup.sql   seconds   drops CatchAllDemo
```

Run each file whole (F5).

## How it's built

`Demo.Orders` holds 1,000,000 orders with an index on each searchable column:
`CustomerID` (20 orders each), `OrderDate` (about 457 a day), and `SalesRepID`,
which is **NULL on 10% of orders**. That NULL is what scenario E needs.

The same search, "orders, optionally by customer, optionally since a date,
optionally by rep", is written five ways:

| variant | the `WHERE` clause |
|---|---|
| `CatchAll` | `(@p IS NULL OR col = @p)` for each filter |
| `Recompile` | the same, plus `OPTION (RECOMPILE)` |
| `RecompileAssign` | the same again, but `SELECT @n = COUNT_BIG(*) ...` into variables |
| `Dynamic` | only the supplied predicates, run with `sp_executesql` and parameters |
| `Coalesce` | `col = COALESCE(@p, col)` for each filter |

Each variant is called four ways: **customer** (one customer, 20 rows),
**date** (the last week, 3,192 rows), **both**, and **none** (no filter, the
whole table). Each call runs twice and the second is measured, so a cached
plan is measured without its compile.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25, 8 schedulers.

| logical reads | customer | date | both | none |
|---|---|---|---|---|
| `CatchAll` | 1,831 | **3,001,773** | 1,833 | **3,001,776** |
| `Recompile` | 122 | 10,262 | 121 | 22,961 |
| `RecompileAssign` | **1,853** | 11,896 | 1,855 | 22,964 |
| `Dynamic` | **96** | **10,218** | **93** | **22,943** |
| `Coalesce` | 5,339 | 18,287 | 5,264 | 2,877,059, and **the wrong answer** |

### A — the catch-all

The catch-all compiles **one plan** that has to be correct for every
combination of NULL and non-NULL arguments. It can't simply seek on
`CustomerID`, because next time `@CustomerID` might be NULL. Here it scanned
the `CustomerID` index and looked up every row it kept. That's tolerable when
there's a customer filter (1,831 reads against 96), and ruinous when there
isn't: the date-only search looked up **every row in the table**, 3,001,773
reads against 10,218. One plan fits none of the four searches well.

**On SQL Server 2025 this changes.** At compatibility level 170, 2025 adds
*optional parameter plan optimization* (OPPO), aimed at exactly this pattern.
In the CI run on 2025, the catch-all's date search read **11,862** pages
against 10,218 for dynamic SQL, and its customer search 107 against 93. On
2025 at level 170, the catch-all is no longer the problem this scenario
shows, and the demo's verdict checks for that instead. On every earlier
version, or a 2025 database at a lower level, it is.

### B — `OPTION (RECOMPILE)`

With `RECOMPILE`, every call is compiled with its actual argument values
embedded (the *parameter embedding optimization*). `@CustomerID IS NULL` is
known to be true or false, the dead branches disappear, and each call gets the
plan the dynamic version would have. The worst search was 1.3× the dynamic
version's reads, mostly the compile itself.

The price is a compile on **every** call: a few dozen reads and a couple of
milliseconds of CPU here. That's invisible on a report and real on a query
that runs thousands of times a second.

### C — `RECOMPILE` with `SELECT @var = ...`

| customer search | logical reads |
|---|---|
| `Recompile`: returns its result | 122 |
| `RecompileAssign`: assigns the result to variables | **1,853** |

One change: the result is assigned to variables instead of returned. On the
tested build that was enough to stop the argument values being embedded. The
plan was compiled fresh on every call and was **still the catch-all scan**.
That was confirmed separately from the actual plans of the same statement
with and without the assignment: Index Seek against Index Scan.

Plenty of real search procedures assign their results to variables or OUTPUT
parameters. If yours does, `RECOMPILE` may not be doing what you think, so
check the plan.

### D — dynamic SQL

Build only the predicates that were supplied and execute with
`sp_executesql` **and parameters**. Each combination is a different statement
text, so each gets its own cached plan, compiled once and reused by every
later call with the same combination. The demo found **4 cached plans**, one
per combination, and the fewest reads on every search. "Fewest" allows 5%
or 10 reads, whichever is more: the small searches read about 95 pages, and
the same plan's count moved by 3 between runs. On 2025 (compatibility level
170) the catch-all gets the same plan on those searches, and CI once
failed this check before the 10-read allowance was added.

Concatenating the *values* into the string instead would cache a plan per
value and open the door to SQL injection. Concatenate predicates, pass
values as parameters.

### E — `COALESCE`

| no filter at all | rows found |
|---|---|
| the other four variants | 1,000,000 |
| `Coalesce` | **900,000** |

`SalesRepID = COALESCE(@SalesRepID, SalesRepID)` reads as "any rep" when
`@SalesRepID` is NULL. It isn't. For a row whose `SalesRepID` is NULL it
becomes `NULL = NULL`, which isn't true, and the row is **silently dropped**.
10% of orders have no rep, and every search through this variant loses them.
On two of the four searches it was slower than even the catch-all. The other
four variants agreed on every search.

## How to read the output

`02-demo.sql` prints four result sets: reads by variant and search, every call
with its row count, the verdicts, and **anything that didn't behave as
predicted, which should be empty.**

## Takeaways

1. **A catch-all `WHERE` caches one plan for every combination of filters.**
   A date search through the customer-shaped plan read 3,001,773 pages
   instead of 10,218. SQL Server 2025 at compatibility level 170 fixes this
   pattern with OPPO: 11,862 pages.
2. **`OPTION (RECOMPILE)` fixes it** by planning each call for its own values,
   at the cost of a compile per call.
3. **Unless the statement assigns to variables.** Then the values weren't
   embedded and the catch-all plan came back, compiled fresh every time.
4. **Dynamic SQL with parameters gets a cached plan per combination**: the
   fewest reads on every search, no compile per call.
5. **`col = COALESCE(@p, col)` silently drops rows where `col` is NULL.**
   900,000 rows instead of 1,000,000.

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
