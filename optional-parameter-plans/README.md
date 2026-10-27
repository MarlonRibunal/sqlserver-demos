# Optional parameter plans: SQL Server 2025's answer to the catch-all query

> **The short version:** [Optional parameter plans (SQL Server 2025)](https://marlonribunal.com/sqlserver-demos/optional-parameter-plans/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

`WHERE (@p IS NULL OR col = @p)` is the most common way to write a search
screen, and for years it has meant one plan for every combination of
supplied and missing parameters (see [catch-all queries](../catch-all-queries/)).
SQL Server 2025 adds **optional parameter plan optimization (OPPO)** at
compatibility level 170: the engine keeps one plan for "the parameter was
given" and another for "it was NULL", and picks per call. This topic
measures what it fixes, and finds where it stops.

## The rule these scenarios are built around

**At level 170, write optional filters as `(@p IS NULL OR col = @p)` and
use the parameter directly. OPPO doesn't recognise `COALESCE` or `ISNULL`,
or a parameter copied into a local variable. With two or more optional
parameters it can still reuse a bad plan, so a search screen with many
filters still wants dynamic SQL or `OPTION (RECOMPILE)`.**

## Prerequisites

- **SQL Server 2025 or later.** Developed and tested on **2025 RTM-CU8
  (17.0.4075.5)**, Linux container. On 2022 and earlier the scripts still
  run, and the demo reports every scenario as `SKIPPED`.
- No sample database. `01-setup.sql` creates its own database, `OppoDemo`.
- Permission to `CREATE DATABASE`.

## What setup and the demo change on your instance

Nothing outside the database they create. Inside `OppoDemo`:

- setup turns on **Query Store**, where the plan variants are recorded
- the demo clears Query Store and **`OppoDemo`'s plan cache**
  (`ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE`: this
  database's plans only)
- it moves the **compatibility level** between 160 and 170, and turns the
  **`OPTIONAL_PARAMETER_OPTIMIZATION`** database setting off and back on.
  It leaves `OppoDemo` at 170 with the setting on.

`03-cleanup.sql` drops the database and confirms that none of its files
remain.

## Run order

```
01-setup.sql     ~20 s     creates OppoDemo: 1,000,000 orders, six versions of one search
02-demo.sql      ~15 s     five scenarios at compatibility level 160 and 170
03-cleanup.sql   seconds   drops OppoDemo
```

Run each file whole (F5).

## How it measures

Every search runs with an empty plan cache, in the same order: one
customer first, which compiles the plan, then all customers. The demo
records each call's logical reads. It runs everything at level 160 (before
OPPO), then at 170.

`Demo.Orders` has 1,000,000 orders: 20 per customer and 500 per date, with
an index on each column. Reading every order takes about 16,300 reads as a
scan, or about 3 million as a lookup per row.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2025 RTM-CU8.

### A — one optional parameter

`WHERE (@CustomerID IS NULL OR CustomerID = @CustomerID)`

| logical reads | one customer, first | then all customers |
|---|---|---|
| compatibility level 160 | 1,870 | **3,001,752**: the one-customer plan, a lookup per row |
| compatibility level 170 | 150 | **16,286**: a scan, its own plan |

Query Store records the two plans as **variants** of the one query
(`sys.query_store_query_variant`, the same mechanism as 2022's
[parameter-sensitive plans](../sql2022-iqp/)). One customer also got
cheaper: 150 reads instead of 1,870. With no NULL case to allow for, the
plan can seek directly.

### B — two optional parameters

`(@CustomerID IS NULL OR CustomerID = @CustomerID) AND (@OrderDate IS NULL OR OrderDate = @OrderDate)`,
at level 170, called in this order:

| search | logical reads |
|---|---|
| customer only | 141 |
| date only | 3,269 |
| **neither** | **3,189,131** |

Two variants were recorded, not one per combination. "Date only" and
"neither" both have `@CustomerID` NULL. "Neither" read every order at about
3 reads each, the cost of a lookup per row. That's most likely the plan
compiled for "date only" (a date seek and lookups), reused. It's parameter
sniffing again, one level down. The demo only runs this one order, so it
doesn't show which combination pays when the order changes.

### C — `COALESCE` and `ISNULL`

The same search as A, written `CustomerID = COALESCE(@CustomerID, CustomerID)`
or with `ISNULL`:

| logical reads, level 170 | one customer | all customers |
|---|---|---|
| `COALESCE` | **16,288** | 16,270 |
| `ISNULL` | **16,288** | 16,270 |
| the `OR` form (A) | 150 | 16,286 |

Neither got variants. Each compiled to one scan and used it for every
call, 100 times the reads of the `OR` form for one customer. (These forms
also give wrong answers when the column allows NULL. The catch-all topic
shows that.)

### D — changing the parameter, or copying it

| logical reads, level 170 | one customer | all customers |
|---|---|---|
| `SET @CustomerID = NULLIF(@CustomerID, 0)` first | 117 | 16,286 |
| `DECLARE @c int = @CustomerID`, then filter on `@c` | **16,290** | 16,270 |

Changing the parameter before the query didn't stop OPPO on the tested
build: two variants, both fast. Copying it into a local variable, an old
habit for dodging parameter sniffing, did stop it. The optimizer can't
sniff a local variable, so it compiled one plan for an unknown value: a
scan for every search, the one-customer search included.

The extended event `optional_parameter_optimization_skipped_reason` gives
the engine's reason when it passes over a query. In a prototype of this
topic it reported `HasLocalVar`, `OtherThresholdNotMet`,
`CompatLevelBelow170` and `UnsupportedStatementType`. The demo doesn't
create an event session, which would be an instance-level object.

### E — the off switch

`ALTER DATABASE SCOPED CONFIGURATION SET OPTIONAL_PARAMETER_OPTIMIZATION = OFF`,
at level 170: all customers after one read **3,001,752**, the same as at
160. Use it if OPPO causes a regression, without giving up the rest of level
170.

## Traps from building this

- **A predicate that didn't hold.** The first version predicted that
  modifying the parameter would switch OPPO off. That came from an
  `OutputOrModifiedParam` skip reason seen in the prototype, which belonged
  to another statement. Measured, OPPO handled the modified parameter
  fine.
- **`sys.database_scoped_configurations.value` is `sql_variant`.** Casting
  it to `int` in a `WHERE` failed with error 245 on another setting's text
  value: filtering on the name first doesn't guarantee the order. Compare
  it as text.

## How to read the output

`02-demo.sql` prints three result sets:

1. every call: configuration, search, arguments, logical reads
2. the verdicts, each with its evidence
3. **anything that didn't behave as predicted, which should be empty**
   on 2025 (on 2022 and earlier, the `SKIPPED` rows)

## Takeaways

1. **At level 170 the single-parameter catch-all is fixed**: 3,001,752
   reads became 16,286, and one customer went from 1,870 to 150.
2. **Two optional parameters can still reuse a bad plan.** "Neither" read
   3.2 million pages through the date search's plan.
3. **Write the `OR` form.** `COALESCE` and `ISNULL` get no variants.
4. **Don't copy parameters into local variables.** That switches OPPO off.
5. **`OPTIONAL_PARAMETER_OPTIMIZATION = OFF`** turns it off for one
   database, if it ever makes things worse.

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the single
configuration named under [Prerequisites](#prerequisites), SQL Server 2025
RTM-CU8 (17.0.4075.5) in a Linux container, and nowhere else. No other version,
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
