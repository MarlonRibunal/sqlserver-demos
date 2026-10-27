# Regular expressions in SQL Server 2025: REGEXP_LIKE against LIKE

> **The short version:** [Regular expressions (SQL Server 2025)](https://marlonribunal.com/sqlserver-demos/regex-functions/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

SQL Server 2025 adds regular expressions to T-SQL: `REGEXP_LIKE`,
`REGEXP_REPLACE`, `REGEXP_SUBSTR`, `REGEXP_INSTR`, `REGEXP_COUNT`, and the
table-valued `REGEXP_MATCHES` and `REGEXP_SPLIT_TO_TABLE`. They can
express what `LIKE` can't. This topic runs the same searches both ways on
500,000 rows and measures where the new functions behave differently:
case, index seeks, row estimates, CPU, the pattern syntax, and the
compatibility level.

## The rule these scenarios are built around

**Use `LIKE` where `LIKE` can say it, and `REGEXP_LIKE` where it can't.
`REGEXP_LIKE` is case-sensitive whatever the collation, seeks only for some
patterns, gets a fixed 9% row estimate, and costs about ten times the CPU of
`LIKE` per row.**

## Prerequisites

- **SQL Server 2025 or later**, at compatibility level 170 for `REGEXP_LIKE`.
  Developed and tested on **2025 RTM-CU9-GDR (17.0.5015.4)**, Linux
  container. On 2022 and earlier the scripts still run, and the demo reports
  every scenario as `SKIPPED`.
- No sample database. `01-setup.sql` creates its own database, `RegexDemo`,
  with a case-insensitive collation (`SQL_Latin1_General_CP1_CI_AS`)
  whatever the server's default.
- Permission to `CREATE DATABASE`.

## What setup and the demo change on your instance

Nothing outside the database they create. Inside `RegexDemo`, the demo
clears the database's plan cache (`ALTER DATABASE SCOPED CONFIGURATION
CLEAR PROCEDURE_CACHE`: this database's plans only), and scenario F moves
its compatibility level to 160 and back to 170. `03-cleanup.sql` drops the
database and confirms that none of its files remain.

## Run order

```
01-setup.sql     ~15 s     creates RegexDemo: 500,000 codes and email addresses
02-demo.sql      ~10 s     six scenarios
03-cleanup.sql   seconds   drops RegexDemo
```

Run each file whole (F5).

## The data

`Demo.Codes` has 500,000 rows. `Code` is a product code like `QZ-12345`:
676 two-letter prefixes, about 740 rows each, with an index on it. `Email` is
an address like `user1@example.com`, and one row in 100 is malformed:
`user100@@bad`.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2025 RTM-CU9-GDR.

### A — case

The database is case-insensitive. Codes starting with lower-case `qz`:

| | rows |
|---|---|
| `Code LIKE 'qz%'` | 739 |
| `REGEXP_LIKE(Code, '^qz')` | **0** |
| `REGEXP_LIKE(Code, '^qz', 'i')` | 739 |

**`REGEXP_LIKE` is case-sensitive by default, whatever the collation.**
Replacing a `LIKE` with a regular expression in a case-insensitive database
silently loses rows, without an error. Add the `'i'` flag.

### B — which patterns can seek

The codes starting `QZ` (logical reads, warm cache; the index is 1,431
pages):

| predicate | reads |
|---|---|
| `Code LIKE 'QZ%'` | 6 |
| `REGEXP_LIKE(Code, '^QZ')` | **6** |
| `REGEXP_LIKE(Code, @p)`, `@p = '^QZ'` | **6** |
| `Code LIKE 'QZ-[0-9]%'` | 6 |
| `REGEXP_LIKE(Code, '^QZ-\d')` | **1,423** |
| `REGEXP_LIKE(Code, '^QZ.*')` | **1,423** |

An anchored literal prefix seeks, even from a variable: the plan derives a
range from the pattern and checks `REGEXP_LIKE` on the rows in it. But
`'^QZ-\d'` and even `'^QZ.*'` read the whole index, where the `LIKE` that
means the same thing seeks.

Probing further while building this, `'^QZ[0-9]'` sought and `'^QZ\d'`
scanned, and an unescaped `-` stopped the seek where `'\-'` didn't. There's
no rule here that's simple enough to rely on. **Check the plan for each
pattern** before putting it on a big table.

### C — estimates

The same `QZ` prefix, 739 rows:

| | estimated rows |
|---|---|
| `Code LIKE 'QZ%'` | 886 |
| `REGEXP_LIKE(Code, '^QZ')` | **45,000**: 9% of the table |

`LIKE` with a literal prefix is estimated from the statistics histogram.
`REGEXP_LIKE` got a fixed **9%** of the table, 61 times the real count. In a
bigger query that guess sets the join types and the memory grant, and a
selective pattern's rows are overestimated every time.

### D — CPU

The malformed addresses, `'@@'` anywhere: a scan either way, so the
difference is the cost of the test on each row. Serial, best of three:

| | CPU |
|---|---|
| `Email LIKE '%@@%'` | 34 ms |
| `REGEXP_LIKE(Email, '@@')` | **378 ms** |
| `NOT REGEXP_LIKE(Email, '^[a-z0-9._]+@[a-z0-9-]+(\.[a-z0-9-]+)+$')` | 433 ms |

For a plain substring, `REGEXP_LIKE` cost **11 times** the CPU of `LIKE`. A
full address pattern cost little more than the trivial one, and it found the
same 5,000 bad rows. That's the regular expression's real value: one
predicate that checks the whole format, which `LIKE` can't express.

### E — the pattern language is RE2

| pattern | result |
|---|---|
| backreference `'^(.)\1'` | **error 19300** |
| lookahead `'^QZ(?=-)'` | **error 19300** |
| alternation `'^(QZ\|QY)-'` | ran |

SQL Server uses the RE2 syntax. Backreferences and lookarounds, which .NET,
Perl and PCRE patterns use freely, are errors. A pattern copied from
application code needs testing before it goes in a query.

### F — compatibility level

At level 160:

| | result |
|---|---|
| `REGEXP_LIKE` | **error 195**: "not a recognized built-in function name" |
| `REGEXP_SPLIT_TO_TABLE` | **error 208**: "Invalid object name" |
| `REGEXP_REPLACE` | ran |

`REGEXP_LIKE` and the table-valued functions need level 170. The scalar
functions don't. A database restored from 2022, or kept at 160 for plan
stability, has some of the functions and not others.

## How to read the output

`02-demo.sql` prints three result sets:

1. every measurement
2. the verdicts, each with its evidence
3. **anything that didn't behave as predicted, which should be empty**
   on 2025 (on 2022 and earlier, the `SKIPPED` rows)

## Traps from building this

- **Reading `STATISTICS IO` output with a regular expression.** The first
  probe of scenario B reported 0 reads for every pattern: the `sed`
  expression took the last "logical reads" on the line, which is the LOB
  count. Ironically apt.
- **Which patterns seek isn't predictable from the outside.** Scenario B
  first assumed that anything after a literal prefix would still seek, as
  it does for `LIKE`. Measured, most of them didn't.

## Takeaways

1. **`REGEXP_LIKE` is case-sensitive in a case-insensitive database.** Add
   `'i'`, or rows go missing without an error.
2. **Some anchored patterns seek and some don't.** `'^QZ'` sought;
   `'^QZ-\d'` and `'^QZ.*'` read the whole index. Check the plan.
3. **The estimate is a fixed 9% of the table**: 45,000 rows for 739.
4. **Per row, `REGEXP_LIKE` cost 11 times the CPU of `LIKE`.** Use it
   for what `LIKE` can't express, such as validating a whole format.
5. **RE2 has no backreferences or lookarounds** (error 19300).
6. **`REGEXP_LIKE` and the table functions need compatibility level 170**;
   `REGEXP_REPLACE` doesn't.

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the single
configuration named under [Prerequisites](#prerequisites), SQL Server 2025
RTM-CU9-GDR (17.0.5015.4) in a Linux container, and nowhere else. No other
version, edition, platform, or configuration has been exercised, and the
measured numbers throughout this README are from that one instance rather than
a general result.

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
