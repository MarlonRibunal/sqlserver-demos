# The json data type and JSON indexes: what SQL Server 2025 changes, and what it doesn't

> **The short version:** [The json data type (SQL Server 2025)](https://marlonribunal.com/sqlserver-demos/json-native-type/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

Since 2016, SQL Server has kept JSON in `nvarchar(max)` and parsed the text
every time a query looks inside it. SQL Server 2025 adds a native **`json`
data type**, stored in a binary format, and the **JSON index**. This topic
puts 200,000 order documents in both types and measures what changes:
what each accepts, what `json` stores, what reading costs, and which
queries a JSON index actually serves.

## The rule these scenarios are built around

**Use `json` for JSON columns: it validates on the way in and costs less to
read. But a JSON index serves `JSON_CONTAINS`, not `JSON_VALUE(...) =`, and
it's big. For an equality filter on one property, the 2016 pattern (a
computed column on `JSON_VALUE` with an ordinary index on it) is still the
better tool.**

## Prerequisites

- **SQL Server 2025 or later.** Developed and tested on **2025 RTM-CU9-GDR
  (17.0.5015.4)**, Linux container. On 2022 and earlier the scripts still
  run, and the demo reports every scenario as `SKIPPED`.
- No sample database. `01-setup.sql` creates its own database, `JsonDemo`.
- Permission to `CREATE DATABASE`.

## What setup and the demo change on your instance

Nothing outside the database they create. The demo's inserts (scenarios A
and E) go into empty tables of their own and are rolled back. `03-cleanup.sql` drops `JsonDemo` and confirms
that none of its files remain.

## Run order

```
01-setup.sql     ~30 s     creates JsonDemo: the same 200,000 documents in four tables
02-demo.sql      ~10 s     six scenarios
03-cleanup.sql   seconds   drops JsonDemo
```

Run each file whole (F5). Creating the computed-column index in setup prints
a warning that its key can be up to 8,000 bytes. That's expected:
`JSON_VALUE` returns `nvarchar(4000)`, and every value here is a few
characters long.

## The data

Each document is one order of about 160 characters:

```json
{"orderId":1,"customer":{"id":1,"name":"Customer 1","country":"PH"},
 "status":"shipped","total":1.25,"lines":[{"sku":"A1","qty":2},{"sku":"B1","qty":1}]}
```

One order in 1,000 is `"held"`: 200 of them. The same documents are in
four tables:

| table | column | index on `$.status` |
|---|---|---|
| `Demo.OrdersText` | `nvarchar(max)` | none |
| `Demo.OrdersJson` | `json` | none |
| `Demo.OrdersJsonIndex` | `json` | a JSON index, `FOR ('$.status')` |
| `Demo.OrdersComputed` | `nvarchar(max)` | a computed column `JSON_VALUE(doc, '$.status')`, indexed |

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2025 RTM-CU9-GDR.

### A — validation

| inserted | into `nvarchar(max)` | into `json` |
|---|---|---|
| truncated JSON: `{"orderId": 1, "status": ` | **accepted** | error 13609 |
| a bare string: `"shipped"` | — | error 13609 |

`nvarchar(max)` takes anything. The usual protection is a
`CHECK (ISJSON(doc) = 1)` constraint, and plenty of tables don't have one.
**`json` validates every value on the way in**, and it holds an object or
an array, not a bare scalar.

### B — what json stores

```
in:   { "status" : "held",   "qty": 2, "status": "shipped" }
out:  {"status":"held","qty":2}
```

**`json` stores the document, not the text.** Whitespace is gone, and the
duplicate `status` key was **dropped without an error**: the first value
won. (`JSON_VALUE` on the original text also returns the first, `held`, so
queries agree. But if anything downstream relied on the text exactly as
sent, it won't get it back.)

The binary format was a little smaller: **8,461 pages** against 8,949 for
the same documents in `nvarchar(max)`.

### C — reading

The same filter over all 200,000 rows, `WHERE JSON_VALUE(doc, '$.status') =
N'held'`, serial, best of three:

| | CPU |
|---|---|
| `nvarchar(max)` | 346 ms |
| `json` | **248 ms** |

Every `JSON_VALUE` on `nvarchar(max)` parses the text again. On `json` the
value is found in the binary document. The gap was about 30% here, and
wider on a parallel plan in early tests.

### D — which predicates a JSON index serves

The 200 held orders, found four ways (logical reads, warm cache):

| query | table | reads |
|---|---|---|
| `JSON_VALUE(doc, '$.status') = N'held'` | with the JSON index | **8,869**: a full scan |
| `JSON_CONTAINS(doc, N'held', '$.status') = 1` | with the JSON index | **644** |
| the same `JSON_CONTAINS` | no JSON index | 8,869 |
| `JSON_VALUE(doc, '$.status') = N'held'` | `nvarchar(max)`, computed-column index | **4** |

**The JSON index is used by `JSON_CONTAINS`, and ignored by `JSON_VALUE`
equality** on the very path it indexes. Most existing code filters with
`JSON_VALUE`, so adding a JSON index changes nothing for it until the
queries are rewritten.

Even when it's used, the JSON index finds rows and then looks each one up
in the table: 644 reads for 200 rows. The computed-column index answered the
count from the index alone, in 4.

And it's big:

| | pages |
|---|---|
| the table | 8,461 |
| JSON index on `$.status` alone | **2,746** |
| computed-column index on the same path | 699 |

### E — what the JSON index costs on insert

Inserting 20,000 documents into an empty table, both rolled back:

| | log written |
|---|---|
| json table, no JSON index | 706,972 bytes |
| json table, JSON index on one path | **1,086,684 bytes (+53%)** |

### F — json can't be compared

Comparing two `json` values, `ORDER BY` and `GROUP BY` on a `json` column all
failed with **error 13636**: "The JSON data type cannot be compared or
sorted, except when using the IS NULL operator." Comparing it with a string
fails too (error 402), and so does `SELECT DISTINCT` (error 421). Code that
did any of these on an `nvarchar(max)` column breaks when the column type
changes. Compare a
property (`JSON_VALUE`), or cast to text first, which ran:
`GROUP BY CAST(doc AS nvarchar(max))`.

## How to read the output

`02-demo.sql` prints three result sets:

1. every measurement
2. the verdicts, each with its evidence
3. **anything that didn't behave as predicted, which should be empty**
   on 2025 (on 2022 and earlier, the `SKIPPED` rows)

## Traps from building this

- **The first read of a query isn't its cost.** The first run of each
  search in D included compiling and creating statistics, and read more
  than four times the pages of the second. The demo runs each search twice and
  keeps the second.
- **A computed column validates.** In a prototype, an `nvarchar(max)` table
  with an indexed `JSON_VALUE` computed column rejected the broken JSON
  that scenario A expects `nvarchar(max)` to accept: computing the column
  for the index parsed it. `Demo.OrdersText` has no computed column for
  that reason.

- **A rolled-back insert still leaves pages behind.** An early version
  inserted 20,000 rows into the measured tables and rolled back. The
  second run found the json table 677 pages bigger and the insert's log
  ten times larger, and failed its own checks. The demo now writes to empty
  tables of its own and truncates them afterwards.

## Takeaways

1. **`json` validates on the way in**; `nvarchar(max)` doesn't, without a
   `CHECK (ISJSON(...))` constraint.
2. **`json` keeps the document, not the text.** Whitespace goes, and a
   duplicate key is dropped silently.
3. **Reading is cheaper**: 248 ms against 346 ms of CPU for one
   `JSON_VALUE` over every row.
4. **A JSON index serves `JSON_CONTAINS`, not `JSON_VALUE(...) =`.** Adding
   one to existing queries changes nothing until they're rewritten.
5. **For one property, the computed column still wins**: 4 reads against
   644, and an index a quarter of the size.
6. **A JSON index on one path added 53% to the log** an insert wrote.
7. **`json` can't be compared, sorted, grouped or made `DISTINCT`.** Check for
   that before changing a column's type.

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
