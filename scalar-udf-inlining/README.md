# Scalar UDF inlining: what SQL Server 2019 changed, and what it didn't

> **The short version:** [Scalar UDF inlining](https://marlonribunal.com/sqlserver-demos/scalar-udf-inlining/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

For twenty years the advice was "don't put scalar functions in queries": they
run once per row and force the whole plan serial. SQL Server 2019 added
**inlining**, which rewrites a function into the calling query as if its body
had been typed there. Four scenarios run the same functions with inlining on
and off and measure the difference, including one place where it's the
*hand-written* replacement that gets the answer wrong.

## The rule these scenarios are built around

**On 2019+, a simple scalar UDF can cost nothing. Check that yours is
inlineable instead of assuming it either way. And if you rewrite one by hand,
check the answer, not just the speed.**

## Prerequisites

- **SQL Server 2019 or later**, with the database at compatibility level 150
  or higher. Developed and tested on **2022 CU25 (16.0.4255.1)** at level 160.
  On an older instance, `01-setup.sql` stops at its first step and says so.
- No sample database. `01-setup.sql` creates its own database,
  `UdfInliningDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` for the DMVs.
- An instance that will run a 500,000-row aggregate in parallel. The demo
  checks this and reports `INCONCLUSIVE` rather than misreading DOP 1.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed. The new database takes the instance
  default.
- no database scoped configuration changed. `TSQL_SCALAR_UDF_INLINING` stays
  at its default, ON. The comparison is made **per function**, with
  `WITH INLINE = ON` and `WITH INLINE = OFF` on otherwise identical bodies.
- no trace flag set
- no existing database touched
- no instance-wide plan cache flush (`sp_recompile` only, object scoped)

`03-cleanup.sql` drops the database and confirms that none of its files remain.

## Run order

```
01-setup.sql     seconds   creates UdfInliningDemo, 500,000 orders, the functions
02-demo.sql      ~15 s     seven queries; prints a summary
03-cleanup.sql   seconds   drops UdfInliningDemo
```

Run each file whole (F5). Almost all of the 15 seconds is the three
non-inlined queries. Through sqlcmd, pass `-I`.

## How it's built

Two functions, each created twice with identical bodies:

```sql
CREATE FUNCTION Demo.fn_TaxInline (@amount decimal(10,2)) RETURNS decimal(12,2)
WITH INLINE = ON          -- the twin, fn_TaxNoInline, says WITH INLINE = OFF
AS BEGIN
    RETURN CASE WHEN @amount >= 100 THEN @amount * 0.2 ELSE @amount * 0.1 END;
END
```

- `fn_Tax*` is pure arithmetic.
- `fn_Region*` looks a customer's region up in `Demo.Customers`.
- `fn_TaxNow` calls `GETDATE()`, which makes it not inlineable at all.

Each query lives in its own procedure. `Demo.usp_Run` recompiles it, runs it
twice, and records the second run from `sys.dm_exec_query_stats`, the
function's own call count and reads from `sys.dm_exec_function_stats`, and from
the plan whether a UDF call survived and why the plan went serial.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25, 8 schedulers,
compatibility level 160.

### A — a calculation

`SUM(Demo.fn_Tax*(Amount))` over 500,000 orders:

| | elapsed | CPU | DOP | function calls | UDF in plan |
|---|---|---|---|---|---|
| logic typed into the query (baseline) | 9 ms | 27 ms | 8 | — | — |
| `WITH INLINE = ON` | **11 ms** | 28 ms | **8** | **0** | **no** |
| `WITH INLINE = OFF` | **2,231 ms** | 2,231 ms | **1** | **1,000,000** | yes |

Inlined, the function disappears from the plan and the query runs like the
hand-written baseline: in parallel, in about the same time. Not inlined, it's
called for every row, twice per row here (1,000,000 calls for 500,000 rows),
and the plan is forced serial:

```
NonParallelPlanReason="TSQLUserDefinedFunctionsNotParallelizable"
```

On SQL Server 2019 the plan is just as serial, but the reason is reported
as `CouldNotGenerateValidParallelPlan` instead.

**200× slower**, for an identical function body. Before 2019 this was the only
way a scalar UDF could run.

### B — a lookup

`WHERE Demo.fn_Region*(CustomerID) = 'EU'`, where the function reads
`Demo.Customers`:

| | elapsed | DOP | query reads | function calls | function reads |
|---|---|---|---|---|---|
| hand-written `JOIN` | 26 ms | 8 | 8,272 | — | — |
| `WITH INLINE = ON` | **9 ms** | 8 | **8,272** | **0** | — |
| `WITH INLINE = OFF` | **3,278 ms** | 1 | **1,007,834** | **500,000** | **1,000,000** |

Inlined, the function becomes a join, with the same reads as the hand-written
one. Not inlined, every order row calls the function and every call is a seek
into `Demo.Customers`: half a million calls and a million reads, one row at a
time.

A note on where those reads show up. On the tested build,
`sys.dm_exec_query_stats` **did** charge the function's million reads to the
calling query. `SET STATISTICS IO` is the tool known for leaving them out. The
demo reports both rather than claiming they're hidden.

### C — not inlineable

| | `is_inlineable` | DOP | elapsed |
|---|---|---|---|
| `fn_TaxNow` (calls `GETDATE()`) | **0** | 1 | 2,292 ms |

A function that calls a time-dependent function can't be inlined, whatever
`WITH INLINE` says. That's one of several documented restrictions; referencing
a table variable is another. It runs exactly like `WITH INLINE = OFF`.
`sys.sql_modules.is_inlineable` says which of your functions qualify. Result
set 3 is that query, ready to run against your own databases.

### D — the same answer?

| | `SUM` returned |
|---|---|
| `fn_Tax`, inlined | 24,499,600.00 |
| `fn_Tax`, not inlined | 24,499,600.00 |
| the "same" logic typed into the query | **24,499,550.00** |

`fn_Tax` returns `decimal(12,2)`, so every call **rounds its result to two
places** before `SUM` adds it up. Inlining keeps that: it's a rewrite that must
give the function's answer, rounding included. The hand-written version, which
looks equivalent, computes `Amount * 0.2` at full precision and sums that,
and comes out 50.00 lower.

So if you've been replacing scalar UDFs by hand to get the performance that
inlining now gives you for free, compare the answers. `fn_Region`'s three
versions all returned 165,600, as expected for a lookup with no arithmetic.

## How to read the output

`02-demo.sql` prints four result sets:

1. every query: answer, time, DOP, reads, function calls
2. the verdicts
3. **the functions in this database and whether each is inlineable**, the
   query to take away
4. **anything that didn't behave as predicted, which should be empty**

## Takeaways

1. **An inlined scalar UDF costs about what the same logic typed into the
   query costs.** 11 ms vs 9 ms here, in parallel.
2. **A non-inlined one runs once per row and forces the plan serial.** 200×
   slower for the arithmetic, 360× for the lookup.
3. **Inlining isn't guaranteed.** `GETDATE()`, table variables and other
   documented constructs prevent it. Check `sys.sql_modules.is_inlineable`.
4. **`WITH INLINE = OFF` exists** for the rare function whose inlined plan is
   worse, and it lets you compare the two, as this demo does, without
   touching any database setting.
5. **Inlining keeps the function's semantics. A hand rewrite might not.** The
   function's return type rounded each row, and the hand-written "equivalent"
   was 50.00 off.

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the single
configuration named under [Prerequisites](#prerequisites), SQL Server 2022 CU25
(16.0.4255.1) on 8 schedulers at compatibility level 160, and nowhere else. No
other version, edition, compatibility level, or configuration has been
exercised, and the measured numbers throughout this README are from that one
instance rather than a general result.

Run them only on a scratch instance you can afford to lose, and read every
script before you run it. You alone are responsible for reviewing, testing,
and deciding whether to run anything here.

To the fullest extent permitted by law, the author provides these scripts
WITHOUT WARRANTY OF ANY KIND, express or implied, and shall not be liable for
any claim, damages, data loss, service interruption, or other liability arising
from or in connection with their use. See the
[full disclaimer](../README.md#disclaimer).
