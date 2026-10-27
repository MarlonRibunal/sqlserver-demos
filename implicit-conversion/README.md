# Implicit conversions: when a type mismatch costs a scan, and when it doesn't

> **The short version:** [Implicit conversions](https://marlonribunal.com/sqlserver-demos/implicit-conversion/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

Fifteen queries that check one of the most repeated pieces of performance
advice: "a `CONVERT_IMPLICIT` in the plan means an index scan." Sometimes it
does, 300 times over. Usually it doesn't. The difference comes down to which
side gets converted, and, in the classic case, to the column's collation.

## The rule these scenarios are built around

**A mismatch costs a scan only when the *column* is converted and no seekable
range exists through the conversion. Look for `ConvertIssue="Seek Plan"`, not
for `CONVERT_IMPLICIT`.**

When two types meet, the one with lower
[data type precedence](https://learn.microsoft.com/sql/t-sql/data-types/data-type-precedence-transact-sql)
is converted. If that's the value, the conversion happens once and the index
works normally. If it's the column, every row would need converting. Even
then, the optimizer can often seek through the conversion. The exception is a
`varchar` column under a **SQL collation** compared with `nvarchar`: there is
no range to seek, so it scans.

## Prerequisites

- SQL Server 2016 or later. Developed and tested on **2022 CU25
  (16.0.4255.1)**.
- No sample database. `01-setup.sql` creates its own database,
  `ImplicitConversionDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` for the plan cache
  DMVs.
- About 500 MB of free disk. The database reaches about 400 MB.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched
- no plan cache flush of any kind. Cases are found again by a marker comment
  in their text, so stale entries from earlier runs don't interfere.

`ImplicitConversionDemo` is created with an explicit collation,
`SQL_Latin1_General_CP1_CI_AS`, the default for a US-English install. The two
columns that scenario A compares carry their **own** explicit collations, so
the results don't depend on your server's default. `03-cleanup.sql` drops the
database and confirms that none of its files remain.

## Run order

```
01-setup.sql     ~5 s      creates ImplicitConversionDemo, 1,000,000 customers, the cases
02-demo.sql      ~1 s      runs every case; prints a summary
03-cleanup.sql   seconds   drops ImplicitConversionDemo
```

Run each file whole (F5). `02-demo.sql` can be re-run as often as you like
without re-running setup.

Not on SSMS? Everything works through sqlcmd. Pass `-I`: it turns on
`QUOTED_IDENTIFIER`, which the plan-reading XML methods need.

```
sqlcmd -S <server> -I -i 01-setup.sql -o setup.txt
sqlcmd -S <server> -I -i 02-demo.sql  -o demo.txt
sqlcmd -S <server> -I -i 03-cleanup.sql
```

## How it's built

Every query the demo runs is a row in `Demo.Cases`: its text, its marker, and
the operator the README predicts. Nearly all of them are `sp_executesql` calls
with an explicitly typed parameter, because that's what a client driver sends.
Hand `AddWithValue` a string in .NET, for instance, and the parameter goes out
as `nvarchar` whatever the column is.

`Demo.usp_RunCase` runs one case, then finds its plan in the cache by marker
and records:

- the operator that read `Demo.Customers`
- that operator's estimate
- the logical reads
- whether the plan carried either kind of conversion warning
- whether the seek went through `GetRangeThroughConvert`

A case passes when its operator matches the prediction. For A4, B2 and C4,
where the README also claims the estimate survives the conversion, the
estimate must also land within 10% of the true row count.

`Demo.Customers` holds the same customer code three ways, each indexed:

| column | type | collation |
|---|---|---|
| `CodeSql` | `varchar(20)` | `SQL_Latin1_General_CP1_CI_AS` |
| `CodeWin` | `varchar(20)` | `Latin1_General_CI_AS` |
| `CodeN` | `nvarchar(20)` | database default |

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25, 8 schedulers.
Every one-row lookup reads 9 pages when it seeks. That includes a few reads
from the harness's own sink, so treat 9 as the baseline rather than as the
cost of the seek itself.

### A — varchar column, nvarchar value: the classic, decided by collation

| case | | operator | logical reads | vs control | warning |
|---|---|---|---|---|---|
| A0 | control: `varchar` = `varchar` | Index Seek | 9 | 1× | none |
| A1 | **SQL collation**, `nvarchar` parameter | **Index Scan** | **2,713** | **301×** | Seek Plan |
| A2 | SQL collation, `N'...'` literal | **Index Scan** | **2,713** | **301×** | Seek Plan |
| A3 | **Windows collation**, `nvarchar` parameter | Index Seek | 9 | 1× | **none** |
| A4 | Windows collation, 50,000-row value | Index Seek (est. 50,000) | 115 | | none |

Same column type, same parameter type, same query. A1 scans the whole index to
find one row, and A3 seeks.

Under a **Windows** collation, `varchar` and `nvarchar` data sort by the same
rules, so the optimizer can turn the `nvarchar` value into a range of
`varchar` values and seek on it (`GetRangeThroughConvert`). The estimate even
survives: 50,000 estimated, 50,000 actual in A4. Under a **SQL** collation,
`varchar` and `nvarchar` sort by *different* rules, no such range exists, and
every row has to be converted and compared.

A2 needs no parameter at all: an `N` prefix on a literal is enough. So is a
stored procedure parameter declared `nvarchar` against a `varchar` column.

### B — nvarchar column, varchar value: the direction that costs nothing

| case | | operator | logical reads |
|---|---|---|---|
| B1 | `nvarchar` column = `varchar` parameter | Index Seek | 9 |
| B2 | same, 50,000-row value | Index Seek (est. 50,000) | 134 |

Same two types, the other way round. `nvarchar` still wins on precedence, but
now the `nvarchar` side is the column, so the **value** is converted, once, and
the index works normally. That's why "make everything `nvarchar`" is a valid
fix as well as "match the parameter to the column".

### C — other type pairs

| case | column | value | operator | logical reads |
|---|---|---|---|---|
| C1 | `int` | `bigint` | Index Seek | 9 |
| C2 | `int` | `decimal(10,0)` | Index Seek | 9 |
| C3 | `int` | `varchar` | Index Seek | 9 |
| C4 | `date` | `datetime` | Index Seek (est. 274, actual 274) | 9 |
| C5 | `varchar` | `int` | — | **Msg 245** |

For the common numeric and date pairs, the optimizer converts the value or
seeks through a dynamic range. None of them scanned, and none raised a
warning.

C5 is worse than a scan. `int` outranks `varchar`, so every code in the column
gets converted to `int`, and the first one that isn't a number stops the query:

```
Msg 245: Conversion failed when converting the varchar value 'C0050001' to data type int.
```

On a column where every value happens to be numeric, the same query runs,
scans, and returns the right answer, until the day someone inserts `'N/A'`.

### D — the warning is not the cost

| | warning | logical reads |
|---|---|---|
| D1: `CONVERT` in the `SELECT` list of a 10-row seek | **Cardinality Estimate** | **27** |
| A3: column converted, Windows collation | **none** | 9 |
| A1: column converted, SQL collation | **Seek Plan** | 2,713 |

Plans flag conversions with a `PlanAffectingConvert` warning, and it comes in
two kinds:

- `ConvertIssue="Seek Plan"`: the conversion prevented a seek. This is the
  one to act on.
- `ConvertIssue="Cardinality Estimate"`: the conversion *might* affect an
  estimate. D1 raises it for a `CONVERT` in the select list, which can't
  affect anything.

A3 converts the column and is not flagged at all, because under that collation
it was never expensive. Treat the yellow triangle as a prompt, not a verdict.

### E — joins: the mismatch between two columns

| case | | operator on Customers | logical reads |
|---|---|---|---|
| E0 | control: `nvarchar` = `nvarchar` | Index Seek, per order | 68 |
| E1 | `Orders.CustCode` (`nvarchar`) = `Customers.CodeSql` (`varchar`, SQL collation) | **Index Scan** | **2,715** — 40× |

This is the same problem with no application parameter involved. The join
converts the `varchar` column, so instead of one seek per order it scans every
customer code and hash-joins. Look for it in schemas that grew over time: two
tables holding the same key with different types, joined in every report.

### F — finding them in your own plan cache

```sql
WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT  st.text,
        Expression = w.n.value('@Expression', 'nvarchar(400)'),
        qs.execution_count,
        AvgReads   = qs.total_logical_reads / NULLIF(qs.execution_count, 0)
FROM    sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
CROSS APPLY qp.query_plan.nodes('//PlanAffectingConvert[@ConvertIssue="Seek Plan"]') AS w(n)
CROSS APPLY (SELECT dbid = CAST(pa.value AS int)
             FROM   sys.dm_exec_plan_attributes(qs.plan_handle) AS pa
             WHERE  pa.attribute = 'dbid') AS pdb
WHERE   pdb.dbid = DB_ID();   -- drop to search the whole instance
```

Against the demo's cache it returns exactly A1, A2 and E1: the three scans,
and none of the cheap conversions. A2 appears twice, as the original
statement with its literal and as the form simple parameterization rewrote
it into (`= [@1]`).

Shredding the XML of every cached plan is expensive on a large plan cache.
Run it off-peak, or add `TOP` and `ORDER BY qs.total_logical_reads DESC` to
look at the costliest plans first.

## How to read the output

While it runs, scenario F prints the raw output of its plan cache search.
Then the summary prints five result sets:

1. every case, with its operator, estimate, reads, warnings, and the predicted
   operator
2. the reads of each case against its control
3. the error from C5
4. the verdicts from scenarios D and F
5. **anything that did not behave as predicted. It should be empty.**

## Traps worth stealing

- **`sys.dm_exec_sql_text.dbid` is NULL for ad hoc statements and for anything
  sent through `sp_executesql`**, which covers nearly every query an
  application sends. Scope a plan cache search with that column and it
  returns nothing, with no error. The first version of scenario F did exactly
  that. Use the plan's `dbid` attribute from `sys.dm_exec_plan_attributes`
  instead.
- **A nested comment followed by an apostrophe breaks sqlcmd's batch
  splitting.** SQL Server nests `/* ... */` comments, but sqlcmd doesn't:
  it ends the outer comment at the inner `*/`. An apostrophe after that point
  (as in "the demo's sink") then reads to sqlcmd as the start of a string, so
  the next `GO` is swallowed and the batch fails with
  `Incorrect syntax near 'GO'`. Reproduced with a four-line script. A block
  comment that mentions a marker like `/*A1*/` should spell it without the
  slashes.
- **Returning rows into an `INSERT ... EXEC` sink adds the sink's writes to the
  query's logical reads.** A 50,000-row case reported more than 100,000 reads
  that way. The cases return a `COUNT` instead, and are checked against a true
  row count computed with matching types.

## Takeaways

1. **`CONVERT_IMPLICIT` is not a scan.** Of the twelve mismatched comparisons
   here, three scanned and one failed outright. The other eight seeked.
2. **What matters is which side is converted.** Converting the value is free.
   Converting the column *may* cost a scan.
3. **`varchar` column against `nvarchar` value: the collation decides.** Under
   a SQL collation it scans, 301× the reads for a one-row lookup. Under a
   Windows collation it seeks, with an exact estimate.
4. **Numeric and date mismatches seek.** `int`/`bigint`, `int`/`decimal`,
   `int`/`varchar` value, and `date`/`datetime` all seeked here.
5. **A `varchar` column against an `int` value is a bug, not a slowdown.** It
   fails on the first non-numeric row.
6. **Act on `ConvertIssue="Seek Plan"`, not on every warning.** "Cardinality
   Estimate" fires for harmless select-list conversions, and a converted
   column under a Windows collation fires nothing.
7. **The fix is matching types**: in the driver (set the parameter type
   instead of letting `AddWithValue` infer it), in procedure parameters, and
   between columns that join to each other.

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the single
configuration named under [Prerequisites](#prerequisites), SQL Server 2022 CU25
(16.0.4255.1) on 8 schedulers, and nowhere else. No other version, edition,
collation, or configuration has been exercised, and the measured numbers
throughout this README are from that one instance rather than a general
result.

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
