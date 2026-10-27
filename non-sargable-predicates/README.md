# Non-SARGable predicates: which functions on a column cost a seek

> **The short version:** [Non-SARGable predicates](https://marlonribunal.com/sqlserver-demos/non-sargable-predicates/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

Twenty-one queries that measure the rule everyone half-remembers: "don't wrap
the column in a function." Most of the time it holds, at up to 300× the reads.
`CAST(col AS date)` is the famous exception, and it still pays in a way the
folklore leaves out. And one query that *seeks*, according to its plan, reads
every page of the index.

## The rule these scenarios are built around

**Leave the column bare. Move the function, the arithmetic and the NULL
handling to the other side of the comparison. Then check the reads, not just
the operator.**

A predicate is SARGable (Search ARGument-able) when the optimizer can turn it
into a range on an index. Wrap the column in almost anything and it has to
compute the expression for every row, then compare: a scan. Each wrapped
predicate here is paired with a rewrite that leaves the column bare, and the
demo checks that both return **the same count**. A rewrite that changes the
answer is a bug, not an optimization.

## Prerequisites

- SQL Server 2016 or later. Developed and tested on **2022 CU25
  (16.0.4255.1)**.
- No sample database. `01-setup.sql` creates its own database,
  `SargabilityDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` for the plan cache
  DMVs.
- About 600 MB of free disk. The database reaches about 450 MB.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched
- no plan cache flush of any kind. Cases are found again by a marker comment
  in their text.

`SargabilityDemo` is created with an explicit case-insensitive collation,
`Latin1_General_CI_AS`, because case C4x depends on it. `03-cleanup.sql` drops
the database and confirms that none of its files remain.

## Run order

```
01-setup.sql     ~5 s      creates SargabilityDemo, 2 x 1,000,000 rows, the cases
02-demo.sql      ~2 s      runs every case; prints a summary
03-cleanup.sql   seconds   drops SargabilityDemo
```

Run each file whole (F5). `02-demo.sql` can be re-run without re-running setup.
Through sqlcmd, pass `-I` (`QUOTED_IDENTIFIER` ON, needed by the plan-reading
XML methods).

## How it's built

`Demo.Events` holds 1,000,000 events, about 274 a day from 2016 to 2025, with a
nonclustered index on each searched column: `EventTime`, `Name`, `Discount`
(NULL for 70% of rows) and `Amount`. Every query is a `COUNT`, covered by the
index on the column it filters. So the only question each one answers is
whether the predicate let the optimizer seek, or made it read every entry.

Every case is a row in `Demo.Cases`, sent as `sp_executesql` with parameters
typed to match their columns exactly, so no implicit conversion is involved
([that's a separate topic](../implicit-conversion/)). `Demo.usp_RunCase` runs
each one and records the operator, the index, the estimate, the logical reads
and the count it returned.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25, 8 schedulers.
A one-row seek reports 9 reads here, 6 of them from the harness's own result
sink. Treat 9 as the floor.

### A — dates

| wrapped predicate | operator | reads | rewrite reads | × |
|---|---|---|---|---|
| `YEAR(EventTime) = @y` | Index Scan | 1,996 | 207 | 9.6× |
| `CONVERT(char(8), EventTime, 112) = @s` | Index Scan | 1,996 | 10 | 200× |
| `DATEADD(day, 30, EventTime) >= @d` | Index Scan | 1,996 | 30 | 67× |
| `DATEDIFF(day, EventTime, @d) = 0` | Index Scan | 1,996 | 10 | 200× |
| **`CAST(EventTime AS date) = @d`** | **Index Seek** | **10** | 10 | **1×** |

The rewrites are all half-open ranges on the bare column:

```sql
WHERE EventTime >= @from AND EventTime < @to          -- YEAR, CONVERT, DATEDIFF
WHERE EventTime >= DATEADD(day, -30, @d)              -- DATEADD moved to the parameter
```

`CAST(... AS date)` is the exception: the optimizer turns it into a dynamic
range and seeks. But look at its estimate:

| | estimate | actual |
|---|---|---|
| `CAST(EventTime AS date) = @d` | **1** | 274 |
| `EventTime >= @from AND EventTime < @to` | 274.9 | 274 |

It keeps the seek and loses the histogram. On a one-table count that costs
nothing. Feed that 1-row estimate into a join and it chooses the join
strategy and the memory grant for one row. The half-open range gets both the
seek and the estimate.

### B — NULL handling

| wrapped predicate | operator | reads | rewrite | rewrite reads |
|---|---|---|---|---|
| `ISNULL(Discount, 0) = 0` | Index Scan | 1,755 | `(Discount = 0 OR Discount IS NULL)` | 1,246 |
| `ISNULL(Discount, 0) = 25` | Index Scan | 1,755 | `Discount = 25` | **29** — 60× |

`ISNULL(col, 0) = @v` appears in a lot of code because it reads naturally.
For `@v = 0` the rewrite is the `OR IS NULL` form, a two-range seek. Here it
matches 71% of the table, so the saving is modest. For any other value, the
`ISNULL` does nothing at all except stop the seek. Both pairs returned
identical counts.

### C — strings

| wrapped predicate | operator | reads | rewrite | rewrite reads |
|---|---|---|---|---|
| `LEFT(Name, 5) = @p` | Index Scan | 2,743 | `Name LIKE @p + '%'` | 12 — 229× |
| `LTRIM(RTRIM(Name)) = @p` | Index Scan | 2,743 | `Name = @p` | 9 — 305× |
| `UPPER(Name) = @p` | Index Scan | 2,743 | `Name = @p` | 9 — 305× |
| **`Name LIKE '%' + @p`** | **Index Seek** | **2,743** | — | — |

`UPPER()` under a case-insensitive collation changes nothing about which rows
match. It's pure cost. `RTRIM` is redundant too, because `=` already ignores
trailing spaces. `LTRIM` is the only part that could matter, and only if your
data has leading spaces. If it does, fix the data.

The last row is the trap. A leading-wildcard `LIKE` built from a **parameter**
compiles to an **Index Seek**: the range is worked out at run time from the
pattern. A pattern that starts with `%` has no range, so the "seek" covers the
whole index and reads exactly what the scan reads. **An Index Seek operator is
not proof of a seek. The reads are.** There's no SARGable rewrite for a
leading wildcard. If you need suffix search, store the reversed string and
index it, or use full-text search.

### D — arithmetic

| | operator | reads |
|---|---|---|
| `Amount + 1 = @v` | Index Scan | 1,749 |
| `Amount = @v - 1` | Index Seek | 9 |

Same answer, 194× the reads. Do the arithmetic on the parameter.

### E — fixing it without touching the query

| | operator | reads |
|---|---|---|
| `YEAR(EventTime) = @y` on `Demo.Events` | Index Scan | 1,996 |
| the same text on `Demo.EventsCC` | **Index Seek** on `IX_EventsCC_EventYear` | **184** |

`Demo.EventsCC` has a computed column, `EventYear AS YEAR(EventTime)`, with an
index on it. The query doesn't mention `EventYear`. The optimizer matches the
expression in the `WHERE` clause to the computed column and seeks its index.
That's the fix for code you can't change: a vendor application, an ORM, a
report tool. It needs a deterministic expression written the same way as the
query writes it.

## Estimates

Wrapping the column costs the estimate as well as the seek:

| predicate | estimate | actual |
|---|---|---|
| `LEFT(Name, 5) = @p` | 1 | 1,000 |
| `CONVERT(char(8), EventTime, 112) = @s` | 1 | 274 |
| `YEAR(EventTime) = @y` | 55,557 | 99,577 |
| `CAST(EventTime AS date) = @d` | 1 | 274 |
| every bare-column rewrite | within 7% | |

The scan is the visible cost. The estimate is the one that spreads, into join
choices and memory grants further up the plan.

## How to read the output

`02-demo.sql` prints three result sets:

1. each wrapped predicate against its rewrite: operator, reads, the ratio,
   estimate, answer, and whether the answers matched
2. the rewrites on their own
3. **anything that did not behave as predicted, or a pair that did not return
   the same count. It should be empty.**

## Takeaways

1. **Leave the column bare.** `YEAR()`, `CONVERT()`, `DATEADD()`, `DATEDIFF()`,
   `LEFT()`, `LTRIM()`, `UPPER()`, `ISNULL()` and `col + 1` all scanned here,
   at up to 305× the reads.
2. **Dates: use a half-open range.** `>= @from AND < @to` handles any
   precision and keeps both the seek and the estimate.
3. **`CAST(col AS date)` seeks, but estimated 1 row against 274.** It's the
   exception to rule 1, not a model for it.
4. **`ISNULL(col, 0) = 0` → `(col = 0 OR col IS NULL)`.** For any other value,
   drop the `ISNULL`.
5. **A leading wildcard can look like a seek.** With a parameter, the plan
   says Index Seek and the reads say full scan. Check the reads.
6. **Can't change the query? Index a computed column** that matches its
   expression.
7. **Check that the rewrite returns the same answer.** All of them did here,
   because the demo checks.

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
