# Data type traps: wrong answers without an error

> **The short version:** [Data type traps](https://marlonribunal.com/sqlserver-demos/data-type-traps/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

The bugs in this topic don't fail. A total comes out a fraction off; a
report is missing a day; a date is read as the 2nd of January; a Japanese
name is stored as `??`. Each one is a data type doing exactly what it's
documented to do. This topic runs nine of them and prints what SQL Server
returned next to what was wanted, with the fix beside it.

## The rule these scenarios are built around

**Say what you mean in the type: `decimal` for money and quantities, a
length on every string, `N` on every Unicode literal, `date`/`datetime2` and
`'YYYYMMDD'` for dates, half-open ranges (`>= start AND < end`) for time,
and an integer type big enough for the identity's whole life.**

## Prerequisites

- SQL Server 2016 or later. Developed and tested on **2022 CU25
  (16.0.4255.1)**, Linux container, database collation
  `SQL_Latin1_General_CP1_CI_AS`.
- No sample database. `01-setup.sql` creates its own database,
  `TypeTrapsDemo`.
- Permission to `CREATE DATABASE`.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no language or date format changed for anyone. Scenario G sets `British`
  inside one dynamic batch, and the demo checks the session is back to its
  own language afterwards.
- no existing database touched

`03-cleanup.sql` drops the database and confirms that none of its files
remain.

## Run order

```
01-setup.sql     seconds   creates TypeTrapsDemo
02-demo.sql      seconds   nine scenarios; prints what SQL Server returned
03-cleanup.sql   seconds   drops TypeTrapsDemo
```

Run each file whole (F5).

## The scenarios, and what they returned

Every value below is what the tested build returned.

### A — integer arithmetic

| expression | returned | wanted |
|---|---|---|
| `1 / 3` | **0** | 0.333… |
| `7 / 2` | **3** | 3.5 |
| `AVG(Stars)` over 5, 4, 4 (an `int` column) | **4** | 4.33 |
| fix: `AVG(Stars * 1.0)` | 4.33 | 4.33 |

`int / int` is an `int`: the fraction is discarded, not rounded. `AVG` of
an `int` column returns an `int` too, so every product's rating is rounded
down.

### B — float

| | returned | wanted |
|---|---|---|
| `SUM` of a million `float` 0.1s | **100000.0000000133** | 100000 |
| fix: the same as `decimal(12,2)` | 100000.00 | 100000.00 |
| `float`: `0.1 + 0.2 = 0.3`? | **false** | true |
| fix: `decimal`: `0.1 + 0.2 = 0.3`? | true | true |

`0.1` has no exact binary form. Each `float` 0.1 is off by a tiny amount, a
million of them add up to a visible one, and two floats that "should" be
equal often aren't. `float` is for measurements, not money.

### C — decimal × decimal

| | returned | wanted |
|---|---|---|
| `decimal(38,18) * decimal(38,18)` | **1123456.789012** | 1123456.789012345678 |
| … its type | **`decimal(38,6)`** | |
| fix: `decimal(18,2) * decimal(19,18)` | 1123456.789012345678 | 1123456.789012345678 |

Multiplying needs precision `p1 + p2 + 1`. When that's over 38, SQL Server
keeps the integer digits and cuts the scale, as low as 6, rounding the
rest away **without a warning**. An exchange rate with 12 decimal places
quietly became one with 6. Declaring every decimal as `(38, x)` "to be safe"
is what causes it. Size each type for what it holds, and the result fits.

### D — money

| | returned | wanted |
|---|---|---|
| `money`: `100 / 3 * 3` | **99.9999** | 100.0000 |
| … the same value through `CAST(... AS nvarchar)` | **100.00** | 99.9999 |
| fix: `decimal(19,4)`, rounded at the end | 100.00 | 100.00 |

Every `money` result has exactly four decimal places, including each
intermediate one, so `100 / 3` is 33.3333 before it's multiplied back. And
converting `money` to a string by default shows **two** places, which hides
exactly this error in every report that formats it that way.

### E — strings

| | returned | wanted |
|---|---|---|
| `DECLARE @s varchar = 'Hello, world'` | **H** | Hello, world |
| `LEN(CAST(<40 characters> AS varchar))` | **30** | 40 |
| `nvarchar` variable set from `'東京'`, no `N` | **??** | 東京 |
| fix: `N'東京'` | 東京 | 東京 |

`varchar` without a length means `varchar(1)` in a declaration and
`varchar(30)` in `CAST`, and both truncate silently. A literal without `N`
is `varchar`, in the database's code page (here Latin-1). Characters it
doesn't have become `?` *before* they reach the `nvarchar` column. On a
database with a UTF-8 collation, that row reports `INCONCLUSIVE`.

### F — datetime

`Demo.Events` has an event every minute on 31 January (1,440) and 60 more
on 1 February.

| | returned | wanted |
|---|---|---|
| `CAST('2025-01-31 23:59:59.999' AS datetime)` | **2025-02-01 00:00:00.000** | 2025-01-31 23:59:59.999 |
| January events, `BETWEEN '20250101' AND '20250131 23:59:59.999'` | **1,441** | 1,440 |
| January events, `BETWEEN '20250101' AND '20250131'` | **1** | 1,440 |
| fix: `At >= '20250101' AND At < '20250201'` | 1,440 | 1,440 |

`datetime` stores time in steps of 1/300 s, so `.999` rounds **up, to the
next day**, and the "end of January" range picked up 1 February's first
event. A date with no time means midnight, so `BETWEEN ... AND
'20250131'` stopped at the first moment of the 31st and missed the rest of
the day. A half-open range is right for every type and precision.

### G — date literals

| inside `SET LANGUAGE British` | returned | wanted |
|---|---|---|
| `CAST('2025-02-01' AS datetime)` | **02 Jan 2025** | 01 Feb 2025 |
| fix: `CAST('2025-02-01' AS date)` | 01 Feb 2025 | 01 Feb 2025 |
| fix: `CAST('20250201' AS datetime)` | 01 Feb 2025 | 01 Feb 2025 |

`'YYYY-MM-DD'` looks unambiguous, but converted to `datetime` (or
`smalldatetime`) it's read in the session's date order. In British English
that's day-month, so it means YYYY-**DD-MM**. The same code gives different
dates for logins with different default languages. `date` read it as ISO
(tested), and so do `datetime2` and `datetimeoffset`, according to the
documentation. `'YYYYMMDD'` is safe everywhere.

### H — trailing spaces

| | returned | wanted |
|---|---|---|
| `varchar(10) UNIQUE`: insert `'ABC'`, then `'ABC  '` | **error 2627** | two distinct codes |
| `'ABC' = 'ABC  '` | **true** | false |
| `LEN('ABC  ')`, `DATALENGTH('ABC  ')` | **3**, 5 | 5, 5 |

Comparisons ignore trailing spaces, for `varchar` as well as `char`, so
`'ABC'` and `'ABC  '` are the same key. `LEN` ignores them too; `DATALENGTH`
doesn't. Data imported with padding collides with data that wasn't padded,
and `LEN` won't show you why.

### I — the identity runs out

| | returned |
|---|---|
| insert 4 tickets into an `int` identity seeded at 2,147,483,645 | **3 inserted, then error 8115**: *Arithmetic overflow error converting IDENTITY to data type int.* |

An `int` identity stops at 2,147,483,647 and every insert after that fails.
Identity values are never reused, and failed and rolled-back inserts burn
them too, so a busy table gets there sooner than its row count suggests.
Watch `IDENT_CURRENT` against the type's limit. Changing an `int` key to
`bigint` on a big table is a large operation; it's cheaper to choose
`bigint` at the start.

## How to read the output

`02-demo.sql` prints two result sets:

1. **what SQL Server returned**: every expression, what it gave, what was
   wanted, and `TRAP` / `FIXED` / `info`
2. **anything that didn't behave as predicted, which should be empty**

## Takeaways

1. **`int / int` is an `int`**, and `AVG` of `int` columns rounds down.
2. **Don't keep money in `float`**: a million 0.10s summed to
   100000.0000000133.
3. **Oversized decimals lose digits when multiplied**:
   `decimal(38,18) * decimal(38,18)` kept 6 decimal places.
4. **`money` rounds every step to four places**, and shows two.
5. **Give every `varchar` a length, and every Unicode literal an `N`.**
6. **Use half-open ranges for time.** `.999` is the next day in `datetime`.
7. **Write dates as `'YYYYMMDD'`**, or use `date`/`datetime2`.
8. **Trailing spaces don't count** in comparisons or unique keys.
9. **Choose `bigint` for identities that might run long.**

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the single
configuration named under [Prerequisites](#prerequisites), SQL Server 2022 CU25
(16.0.4255.1) in a Linux container, and nowhere else. No other version,
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
