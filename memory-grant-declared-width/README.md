# Memory grants sized by declared width

"Make it `varchar(4000)`, storage is the same anyway." For storage, that's
true. This topic sorts the same 500,000 seventeen-character names stored
under four declarations and measures the memory each sort is granted: 68 MB
for `varchar(50)`, 1.4 GB for `varchar(4000)`, and capped at about 1.4 GB for
the two that asked for nearly 3 GB.

## The rule these scenarios are built around

**The optimizer sizes memory grants from the declared width of a
variable-length column, assuming it's half full. Declare columns as wide as
the data, not as wide as you can imagine.**

## Prerequisites

- SQL Server 2016 or later for scenarios A, B and E. Row-mode memory grant
  feedback (C) needs **2019+** at compatibility level 150 or higher. Feedback
  persistence (D) needs **2022** with Query Store on. Developed and tested on
  **2022 CU25 (16.0.4255.1)**, compatibility level 160.
- No sample database. `01-setup.sql` creates its own database,
  `GrantWidthDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` for the plan cache.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched
- no instance-wide plan cache flush (`sp_recompile` only, object scoped)

`02-demo.sql` clears **`GrantWidthDemo`'s own Query Store** at its start, if
Query Store is on. On SQL Server 2022, memory grant feedback is persisted
there and survives a recompile, so without the clear a re-run would start from
what the previous run learned. `03-cleanup.sql` drops the database and
confirms that none of its files remain.

## Run order

```
01-setup.sql     ~5 s      creates GrantWidthDemo, 4 x 500,000 names
02-demo.sql      ~10 s     five scenarios; prints a summary
03-cleanup.sql   seconds   drops GrantWidthDemo
```

Run each file whole (F5). Through sqlcmd, pass `-I`.

## How it's built

500,000 names like `Customer 00042137`, 17 characters each, stored four times:
`varchar(50)`, `varchar(4000)`, `nvarchar(4000)` and `varchar(max)`. Each query
sorts the whole table by name, keeping the top half and returning only an
aggregate, at `MAXDOP 1`.

`Demo.usp_Run` recompiles a query procedure and runs it one or more times. For
each execution it records, from `sys.dm_exec_query_stats`, the grant
(`last_grant_kb`), what was used (`last_used_grant_kb`) and what the optimizer
asked for (`last_ideal_grant_kb`), plus the Sort's estimated row size from the
plan.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25,
compatibility level 160, in a container with about 9.6 GB of memory.

### A — the first execution

| declared as | estimated row size | granted | used |
|---|---|---|---|
| `varchar(50)` | 40 bytes | **68 MB** | 24 MB |
| `varchar(4000)` | **2,015 bytes** | **1,456 MB** | 24 MB |
| `nvarchar(4000)` | 4,015 bytes | 1,472 MB (capped) | 32 MB |
| `varchar(max)` | 4,039 bytes | 1,472 MB (capped) | 45 MB |

Same data, same rows, same sort. The optimizer can't know how long the
strings in a variable-length column really are, so it assumes they're **half
the declared length**. A `varchar(4000)` value is costed at about 2,000 bytes,
whatever it holds, and the grant follows: 21× the honest one, 60× what was
used.

### B — the cap

| declared as | wanted | granted |
|---|---|---|
| `nvarchar(4000)` | 2,887 MB | 1,472 MB |
| `varchar(max)` | 2,726 MB | 1,472 MB |

The two widest declarations asked for more than one query may have. The
default Resource Governor pool caps a single grant at 25% of available query
memory. On this instance that's about 1.4 GB, and it scales with the
instance's memory.

The cost of these grants isn't this query's speed: it ran fine. It's every
other query on the instance. Memory granted is reserved for the query's
whole execution, used or not. Two or three of these at once and other
queries queue for memory, waiting on `RESOURCE_SEMAPHORE`, behind
reservations that are 98% empty.

### C — memory grant feedback

| `varchar(4000)` sort | granted | used |
|---|---|---|
| execution 1 | 1,456 MB | 24 MB |
| execution 2 | **36 MB** | 24 MB |
| execution 3 | 36 MB | 24 MB |

Row-mode memory grant feedback (SQL Server 2019+, compatibility level 150+)
notices an execution that used far less than it was granted and cuts the next
grant. From the second execution on, the over-grant is gone. **The first
execution after every compile still pays.**

### D — feedback persists

| | granted |
|---|---|
| `varchar(4000)` sort, first execution **after `sp_recompile`** | **36 MB** |

On SQL Server 2022 with Query Store on, the default for new databases, the
learned grant is stored in Query Store and survives the recompile. Without
Query Store it would be lost, and the next compile would start from 1.4 GB
again. The demo reports `INCONCLUSIVE` here if Query Store is off.

### E — the fix in the query

| | estimated row size | granted |
|---|---|---|
| `varchar(4000)` column, `ORDER BY CAST(Name AS varchar(50))` | **40 bytes** | **68 MB** |

When the column can't be changed, `CAST` it to an honest width before the
sort, and the estimate and the grant follow. The real fix is the column
declaration. A `CAST` is only as good as the guarantee that no value is longer
than it.

## How to read the output

`02-demo.sql` prints three result sets: every execution's grant, used and
ideal memory with the estimated row size, the verdicts, and **anything that
didn't behave as predicted, which should be empty.** On an instance without
Query Store the scenario D row appears there as `INCONCLUSIVE`.

## Takeaways

1. **The grant follows the declared width, not the data.** `varchar(4000)`
   holding 17 characters was costed at 2,015 bytes a row and granted 1.4 GB
   for a 24 MB sort.
2. **`nvarchar` doubles it, and `varchar(max)` is costed as about 4,000
   bytes.** Both hit the per-query cap.
3. **Over-grants hurt the other queries**: memory reserved and unused, with
   `RESOURCE_SEMAPHORE` waits as the symptom.
4. **Memory grant feedback fixes it from the second execution**, and on 2022
   Query Store keeps the fix through a recompile. The first execution after a
   compile still pays unless feedback was persisted.
5. **Declare columns as wide as the data.** Where you can't, `CAST` before the
   sort.

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the single
configuration named under [Prerequisites](#prerequisites), SQL Server 2022 CU25
(16.0.4255.1) at compatibility level 160, and nowhere else. No other version,
edition, compatibility level, memory size, or configuration has been
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
