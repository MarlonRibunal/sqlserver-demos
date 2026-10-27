# New T-SQL syntax in SQL Server 2025: `||`, PRODUCT, and the traps in them

> **The short version:** [New T-SQL syntax traps (SQL Server 2025)](https://marlonribunal.com/sqlserver-demos/tsql-2025-syntax/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

SQL Server 2025 adds syntax that other databases have had for years: the
`||` string operator, a `PRODUCT()` aggregate, `CURRENT_DATE`, `SUBSTRING`
without a length, `UNISTR`, `BASE64_ENCODE`, and `DATEADD` with a `bigint`.
Most of it does what you'd guess. This topic tests the parts that don't:
where `||` behaves like `+`, where it doesn't, and what `PRODUCT()` does
with zero, negatives, NULLs and big numbers.

## The rule these scenarios are built around

**`||` is not `CONCAT`: one NULL makes the whole result NULL. It converts
numbers to strings, where `+` converts strings to numbers, but it has the
same precedence as `+`, so `'total=' || 1 + 2` fails. It truncates at 8,000
characters exactly like `+`. `PRODUCT()` is exact where `EXP(SUM(LOG()))`
wasn't, but it returns the column's type, so an `int` column overflows.**

## Prerequisites

- **SQL Server 2025 or later.** Developed and tested on **2025 RTM-CU9-GDR
  (17.0.5015.4)**, Linux container. On 2022 and earlier the scripts still
  run, and the demo reports every scenario as `SKIPPED`.
- No sample database. `01-setup.sql` creates its own database,
  `SyntaxDemo`, with the collation `SQL_Latin1_General_CP1_CI_AS`.
- Permission to `CREATE DATABASE`.

## What setup and the demo change on your instance

Nothing outside the database they create. Inside `SyntaxDemo`, scenario G
sets the **compatibility level** to 160 and back to 170. `03-cleanup.sql`
drops the database and confirms that none of its files remain.

## Run order

```
01-setup.sql     seconds   creates SyntaxDemo: the harness only
02-demo.sql      seconds   seven scenarios
03-cleanup.sql   seconds   drops SyntaxDemo
```

Run each file whole (F5).

## How it's built

Every statement that uses the new syntax runs as dynamic SQL through
`Demo.usp_Eval`, which records the value it returned or the error it raised.
That way the files compile on any version, and a syntax error is a result,
not a failed batch.

## The scenarios, and what they showed

The results below come from the tested run: SQL Server 2025 RTM-CU9-GDR.

### A — `||` and NULL

`@n` is an `int` holding NULL:

| expression | result |
|---|---|
| `'id=' \|\| @n` | **NULL** |
| `'id=' + CAST(@n AS varchar(10))` | NULL |
| `CONCAT('id=', @n)` | `id=` |
| `SET @s \|\|= NULL` (`@s` was `'x'`) | **NULL** |

`||` follows the same NULL rule as `+`, not `CONCAT`'s. Rewriting
`CONCAT(a, b, c)` as `a || b || c` changes the result whenever one of them
is NULL.

### B — implicit conversion

| expression | result |
|---|---|
| `'n=' \|\| 5` | `n=5` |
| `'n=' + 5` | **error 245**: SQL Server tries to turn `'n='` into an int |
| `1 \|\| 2` | **error 402**: int and int are incompatible in the concat operator |
| `'d=' \|\| CAST('2026-10-29' AS date)` | `d=2026-10-29` |

`||` is a string operator, so it converts the other side to a string, as
long as one side already is one.

### C — precedence

| expression | result |
|---|---|
| `'total=' \|\| 1 + 2` | **error 245** |
| `1 + 2 \|\| ' items'` | `3 items` |
| `'total=' \|\| (1 + 2)` | `total=3` |

`||` and `+` have the same precedence and run left to right. With the string
first, `'total=' || 1` runs first and gives `'total=1'`; then `+ 2` tries to
turn `'total=1'` into a number. With the number first, the sum runs first.
Use parentheses.

### D — truncation

| expression | `LEN` |
|---|---|
| `REPLICATE('x', 8000) \|\| 'y'` | **8000** |
| `REPLICATE('x', 8000) + 'y'` | 8000 |
| `REPLICATE(CAST('x' AS varchar(max)), 8000) \|\| 'y'` | 8001 |

No error, no warning: the last character is gone. That's the old `+` rule,
not something new in `||`, but it carries straight over. When the result
can pass 8,000 bytes, make one side `varchar(max)`.

### E — `PRODUCT()` against `EXP(SUM(LOG()))`

Before 2025, the usual way to multiply a column's values was
`EXP(SUM(LOG(x)))`:

| input | `PRODUCT(x)` | `EXP(SUM(LOG(x)))` |
|---|---|---|
| 1 to 10 | **3628800** | 3628800.0000000084 |
| 0, 3 | **0** | error 3623: invalid floating point operation |
| -2, 3 | **-6** | error 3623 |

And `PRODUCT()` on its own:

| input | result |
|---|---|
| 2, NULL, 4 | 8: NULLs are ignored, like `SUM` |
| no rows | **NULL**, not 1 |
| 100000, 100000 as `int` | **error 8115**: arithmetic overflow |
| the same as `bigint` | 10000000000 |
| `decimal(5,2)` 1.10 × 3 | 1.331000, type `decimal(38,6)` |

The result has the column's type. On an `int` column, ten values of 10 are
enough to overflow, so cast to `bigint` or `decimal` first.

### F — the small ones

| expression | result |
|---|---|
| `CURRENT_DATE` | type **`date`**, equal to `CAST(GETDATE() AS date)` |
| `SUBSTRING('abcdef', 3)` | `cdef`: the length is now optional |
| `DATEADD(second, CAST(3000000000 AS bigint), '2000-01-01')` | `2095-01-24 05:20:00` (on 2022: error 8115) |
| `UNISTR('caf\00E9')`, varchar, `Latin1_General_100_CI_AS` | **error 9844** |
| the same with `Latin1_General_100_CI_AS_SC_UTF8` | `café` |
| `UNISTR(N'caf\00E9')` | `café` |
| `BASE64_ENCODE(CAST('abc' AS varbinary(max)))` | `YWJj` |
| `BASE64_ENCODE(CAST(N'abc' AS varbinary(max)))` | **`YQBiAGMA`** |

`UNISTR` on a `varchar` needs a UTF-8 collation; use an `N''` literal
instead. `BASE64_ENCODE` encodes bytes, and `varchar` and `nvarchar` are
different bytes, so the same text gives two different strings. Encode and
decode with the same type.

### G — compatibility level

At compatibility level **160**, `||`, `PRODUCT`, `CURRENT_DATE` and
two-argument `SUBSTRING` all ran. `REGEXP_LIKE` at the same level raised
**error 195**: the [regular expression functions](../regex-functions/) need
170, this syntax doesn't.

## How to read the output

`02-demo.sql` prints three result sets:

1. every attempt
2. the verdicts, each with its evidence
3. **anything that didn't behave as predicted, which should be empty**
   on 2025 (on 2022 and earlier, the `SKIPPED` rows)

## Traps from building this

- **`LTRIM` and `RTRIM` with a characters argument aren't new.** They
  worked on the 2022 container, so they aren't in this topic.
- **The new syntax can't appear in the scripts outside dynamic SQL.** A
  bare `CURRENT_DATE` or `||` is a syntax error on 2022 and earlier, and it
  fails the whole batch before the version check runs.

## Takeaways

1. **`||` returns NULL if either side is NULL.** Keep `CONCAT` where NULLs
   are possible.
2. **`||` converts numbers to strings; `+` converts strings to numbers.**
   Two numbers with `||` don't compile (402).
3. **`||` and `+` have the same precedence.** Parenthesise arithmetic inside
   a concatenation.
4. **`||` truncates at 8,000 characters**, silently, like `+`.
5. **`PRODUCT()` is exact and handles zero and negatives**, but returns the
   column's type: cast `int` to `bigint` or `decimal` first.
6. **`UNISTR` on `varchar` needs a UTF-8 collation**, and
   **`BASE64_ENCODE` depends on the type**.
7. **None of this needs compatibility level 170.**

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
