# tempdb: when to reach for a `#temp` table, and when to refuse

Six scenarios that measure what a `#temp` table actually buys you, what it
costs, and which of the folklore around it survives contact with a running
instance.

## The rule these scenarios are built around

**Materialize when you need statistics or reuse. Don't when the optimizer
already has both.**

A `#temp` table buys exactly two things a CTE or a table variable cannot give
you: a **histogram** the optimizer can use for cardinality estimation, and a
**single evaluation** you can reference many times. Everything else — indexes,
constraints, parallel inserts — follows from those two. Scenarios A and B
measure them directly. Scenarios C through F are the bill.

## Prerequisites

- SQL Server 2016 or later. Developed and tested on **2022 CU25 (16.0.4255.1)**.
- No sample database. `01-setup.sql` creates its own database, `TempdbDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` for the DMVs and the
  performance counter.
- **A scratch instance.** Scenario D reads an instance-wide performance counter;
  see [Reading scenario D honestly](#reading-scenario-d-honestly).

## What setup changes on your instance

Nothing. This is the one topic in this repo where the "what setup mutates"
section is empty:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched
- no instance-wide plan cache flush (`sp_recompile` only, object scoped)

Every scenario was chosen so it demonstrates its point without changing engine
settings. That is why `03-cleanup.sql` is short: it drops `TempdbDemo` and then
prints the tempdb settings the demo talked about so you can confirm for yourself
they were never written to.

An earlier draft compared table variable estimates across compatibility levels
140/150/160 and across `DEFERRED_COMPILATION_TV`. It was cut: on 2022 CU25 all
six combinations produced an identical result, so it required scoped changes and
a restore path in exchange for four copies of the same row. Scenario B gets the
same lesson across with skew instead, and needs no configuration at all.

## Run order

```
01-setup.sql     ~1 min    creates TempdbDemo, 1,000,000 + 10,000 rows, the procedures
02-demo.sql      2-4 min   the six scenarios; prints a summary
03-cleanup.sql   seconds   drops TempdbDemo
```

Run each file whole (F5). `02-demo.sql` records its own evidence into
`Demo.DemoResults` — you should not have to read a single execution plan.

Not on SSMS? Everything works through sqlcmd:

```
sqlcmd -S <server> -i 01-setup.sql -o setup.txt
sqlcmd -S <server> -i 02-demo.sql  -o demo.txt
sqlcmd -S <server> -i 03-cleanup.sql
```

## The scenarios, and what they showed

Numbers below are from the tested run: SQL Server 2022 CU25, 8 schedulers,
MAXDOP 0, cost threshold for parallelism 5. Yours will differ in magnitude. The
*ratios* and the *verdicts* are the point.

### A — a CTE is a macro, not a materialisation

A common table expression is a naming construct. Reference it twice, and the
optimizer expands it twice.

| | logical reads |
|---|---|
| CTE referenced once | 8,416 |
| **CTE referenced twice** | **16,832** — exactly 2× |
| `#temp` referenced twice | 8,867 — back to the once figure |

This is the most common legitimate reason to reach for a `#temp` table, and the
easiest to prove. Ten references, ten scans.

### B — estimates under skew

`Demo.Skewed` holds 10,000 rows: `grp = 1` has 9,000, `grp = 2` has 10. The
same procedure asks the same two questions of a `#temp` table and of a table
variable holding identical data, **both carrying the same non-clustered index**.

| source | predicate | estimated | true |
|---|---|---|---|
| `#temp` | `grp = 1` | **9,000** | 9,000 |
| `#temp` | `grp = 2` | **10** | 10 |
| `@tablevar` | `grp = 1` | **100** | 9,000 |
| `@tablevar` | `grp = 2` | **100** | 10 |

The table variable returns the *same* number for both predicates while the true
answers differ by a factor of 900. Because both tables have the same index, this
is not a "the table variable had no index" result: an index gives the optimizer
something to seek on, not a distribution to reason about.

Note that 100 is √10,000 — a guess derived from the row count. Without an index
on the table variable the guess is 1 instead. Either way it is unrelated to the
data.

### C — parallelism

| statement | DOP |
|---|---|
| control: plain `SELECT ... GROUP BY` | 8 |
| `INSERT INTO #temp ... SELECT` | 8 |
| `INSERT INTO @tablevar ... SELECT` | **1** |
| `SELECT` joining `@tablevar` | **8** |

"Table variables are serial" is the usual shorthand and it is half wrong. The
restriction is on **modification**, not on reading. A write-once/read-many table
variable holding a handful of rows may cost you nothing; loading a million rows
into one costs you the whole parallel plan.

The control row exists so the scenario can tell "table variables are serial"
apart from "this instance never goes parallel." If the control comes back
serial, every row is marked `INCONCLUSIVE` rather than left to be misread.

### D — what actually breaks temp table caching

Creations per 50 procedure calls. 0 means the table was cached and reused; 50
means a new one was built on every single call.

| pattern | creations | |
|---|---|---|
| plain `CREATE TABLE #t` | 0 | cached |
| plain + **explicit `DROP TABLE`** | 0 | **cached — the DROP is harmless** |
| unnamed `PRIMARY KEY` | 0 | cached |
| **inline** `INDEX` in the `CREATE TABLE` | 0 | cached |
| `SELECT INTO #t` | 0 | **cached** |
| **named** constraint | 50 | **NOT cached** |
| `CREATE INDEX` **after** the `CREATE TABLE` | 50 | **NOT cached** |
| `ALTER TABLE` after the `CREATE TABLE` | 50 | **NOT cached** |
| temp table in **dynamic SQL** | 50 | **NOT cached** |
| large table (~12 MB) | 47 | **NOT cached** — see E |

Two of these contradict widely repeated advice, which is why the demo measures
rather than asserts. Explicitly dropping your temp table does **not** break
caching, and `SELECT INTO` **is** cached.

Two more catch habits carried over from permanent tables: **naming a
constraint** breaks caching, and so does `CREATE INDEX` after the fact — while
an **inline** index does not. Move indexes inline and leave constraints unnamed
and you keep the cache.

### E — the 8 MB cliff

| rows | data size | creations / 20 calls | |
|---|---|---|---|
| 4,000 | 7.66 MB | 0-1 | cached |
| **4,200** | **8.04 MB** | **13-19** | **INTERMITTENT / NOT cached** |
| 4,500 | 8.62 MB | 20 | NOT cached |
| 6,000 | 11.49 MB | 20 | NOT cached |

The boundary sits right at 8 MB. Nothing in your code changes when a
procedure's temp table crosses it — the procedure simply starts rebuilding its
temp table on every call and gets slower, with no plan regression to find.

The 8.04 MB row is the only figure in this topic that moves between runs. It has
come back 13, 14 and 19 out of 20 across three runs, flipping between
`INTERMITTENT` and `NOT cached`. That is not noise to be tidied away — it sits
directly on the boundary, and a row that cannot make up its mind is exactly what
a threshold looks like from the inside. Expect it to appear in result set 7.

### F — collation, and the two hard stops

`CREATE TABLE #t` takes **tempdb's** collation for character columns.
`SELECT INTO` inherits the **source column's**. On a development box whose
database collation matches tempdb's, both behave identically and you never find
out.

| | column collation | join to a `Latin1_General_BIN2` table |
|---|---|---|
| `CREATE TABLE #t (code varchar(20))` | `SQL_Latin1_General_CP1_CI_AS` | **Msg 468 collation conflict** |
| `SELECT code INTO #t FROM ...` | `Latin1_General_BIN2` | succeeds |
| `CREATE TABLE #t (code varchar(20) COLLATE DATABASE_DEFAULT)` | matches the database | succeeds |

`01-setup.sql` picks `TempdbDemo`'s collation *dynamically* so that it differs
from whatever tempdb uses on your instance. Hardcoding one would be the worst
kind of bug here: on an instance already using that collation the scenario would
run green and demonstrate nothing. If no differing candidate is available, the
scenario reports `SKIPPED` instead of passing.

The fix is one clause: put `COLLATE DATABASE_DEFAULT` on every character column
in every `#temp` you hand-create.

And the two categorical rules, the ones that are not tradeoffs:

- **No temp table can be referenced inside a function**, at all —
  `Cannot access temporary tables from within a function.`
- **A table variable survives `ROLLBACK`; a `#temp` table does not.** Measured:
  0 rows vs 1 row. This is the one case where a table variable is not a weaker
  `#temp` — it is the only thing that works. If you are collecting diagnostics
  inside a transaction you intend to roll back, use a table variable.

## How to read the output

`02-demo.sql` prints seven result sets. The first six are the scenarios above.

**Result set 7 should be empty.** It collects every row whose verdict was
`unexpected`, `INTERMITTENT`, `INCONCLUSIVE`, `FAILED`, or `SKIPPED`. Anything
in it is either a genuine difference on your build or an instance setting a
scenario could not work around — read it before trusting the rest.

## Reading scenario D honestly

Scenario D measures `Temp Tables Creation Rate` from
`sys.dm_os_performance_counters`. That counter is **instance-wide**, and there
is no per-session equivalent. Another session creating temp tables during the
run inflates the deltas and can make a genuinely cached variant report as
`NOT cached`.

The verdict thresholds allow a small amount of slack (≤5 creations per 50 calls
still reads as `CACHED`), but the real control is isolation. Run this on a
scratch instance.

## One trap worth stealing

Scenario B reads estimated row counts out of a procedure's plan. The obvious
way to do it is wrong:

```sql
-- WRONG inside a multi-statement procedure
SELECT p.query_plan.value('(//RelOp/@EstimateRows)[1]', 'float')
FROM   sys.dm_exec_query_stats AS s
CROSS APPLY sys.dm_exec_query_plan(s.plan_handle) AS p
WHERE  ...;
```

`sys.dm_exec_query_plan` returns the plan for an entire **plan handle** — for a
stored procedure, that is every statement in one XML document. An XQuery
starting `//RelOp` matches the first qualifying operator in the *whole
procedure*, no matter which statement's DMV row you filtered down to. Every row
comes back carrying the same number, and the result looks stable and
authoritative while being completely wrong. It is a quiet failure: nothing
errors.

The fix is to select the statement node first, then use a relative path:

```sql
;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT  StatementText = n.value('@StatementText', 'nvarchar(400)'),
        EstimateRows  = n.value('(.//RelOp[IndexScan or TableScan]/@EstimateRows)[1]', 'float')
FROM    @plan.nodes('//StmtSimple') AS x(n);
```

`.//RelOp[IndexScan or TableScan]` also matters: it picks the operator that
actually touches the table, rather than a Compute Scalar or the aggregate above
it, both of which carry an `EstimateRows` of their own.

Two smaller ones from building this, both of which silently swallow evidence:

- **An `EXEC` argument must be a variable or a constant, never an expression.**
  `EXEC p @Value = @a - @b` and `EXEC p @Verdict = CASE ... END` are syntax
  errors. Compute into a variable first. (Same rule that bites people with
  `RAISERROR` arguments.)
- **A collation conflict is a compile-time error, so `TRY`/`CATCH` cannot catch
  it inline.** The statement is bound in the same batch as the `TRY` block, so
  it aborts the batch instead of transferring to `CATCH`. Push it through
  `sp_executesql` and the outer `CATCH` handles it. Dynamic SQL runs in a child
  scope, so it still sees your session's temp tables.

## Takeaways

1. The question is not "temp table or not." It is **"do I need a histogram, or
   do I need this set more than once?"** Yes to either → `#temp`. No to both →
   don't materialize.
2. **A CTE is a macro.** Referenced twice, it does the work twice.
3. **Table variables have no distribution.** Same estimate for a 9,000-row
   predicate and a 10-row one.
4. **Table variable writes are serial; reads are not.**
5. **Two hard stops:** no temp tables in functions; only table variables survive
   rollback.
6. **Keep the cache:** indexes inline, constraints unnamed, stay under 8 MB.
   Explicitly dropping is fine.
7. **`COLLATE DATABASE_DEFAULT`** on every character column in a hand-created
   `#temp`.

## A note on TF 1117 and TF 1118

They are not in these scripts because they have been **baked into tempdb since
SQL Server 2016**. `03-cleanup.sql` prints the proof on your own instance:

```
tempdb  is_mixed_page_allocation_on = 0     (TF 1118 behaviour)
PRIMARY is_autogrow_all_files       = 1     (TF 1117 behaviour)
DBCC TRACESTATUS(-1)                        (empty — no flags enabled)
```

For contrast, `master` still shows `is_mixed_page_allocation_on = 1`. The
tempdb-only default is deliberate. If you find these flags in a startup
parameter list, they are cargo cult.
