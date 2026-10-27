# Blocking a query with ABORT_QUERY_EXECUTION: SQL Server 2025's kill switch

> **The short version:** [Blocking a query with ABORT_QUERY_EXECUTION (SQL Server 2025)](https://marlonribunal.com/sqlserver-demos/abort-query-execution/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

A report that takes the server down every morning, from an application you
can't change. Before 2025 the options were to kill the session each time,
or to throttle it with Resource Governor. SQL Server 2025 adds a Query Store
hint, **`ABORT_QUERY_EXECUTION`**: set it on one query, and that query fails
immediately whenever it runs. This topic sets it and measures what it
blocks, what it doesn't, what it does to a transaction, and when it stops
working.

## The rule these scenarios are built around

**`ABORT_QUERY_EXECUTION` blocks one Query Store `query_id`, not a piece of
text. It holds while Query Store is read-write or read-only, and it lifts
when Query Store is turned off. A blocked query dooms the caller's
transaction, so the work before it is rolled back.**

## Prerequisites

- **SQL Server 2025 or later.** Developed and tested on **2025 RTM-CU9-GDR
  (17.0.5015.4)**, Linux container. On 2022 and earlier the scripts still
  run, and the demo reports every scenario as `SKIPPED`.
- No sample database. `01-setup.sql` creates its own database, `AbortDemo`,
  with Query Store on.
- Permission to `CREATE DATABASE`.

## What setup and the demo change on your instance

Nothing outside the database they create. Inside `AbortDemo`, the demo sets
and clears a Query Store hint, switches **Query Store** to `READ_ONLY`, `OFF`
and back to `READ_WRITE`, and clears the database's plan cache (`ALTER
DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE`: this database's plans
only). It leaves Query Store on, with no hints. `03-cleanup.sql` drops the
database and confirms that none of its files remain.

## Run order

```
01-setup.sql     seconds   creates AbortDemo: one table, two procedures
02-demo.sql      seconds   five scenarios
03-cleanup.sql   seconds   drops AbortDemo
```

Run each file whole (F5).

## How it's built

`Demo.p_Runaway` is the query to block: a cross join that counts 4,000,000
combinations. Here it takes milliseconds; it stands in for the report that
doesn't. `Demo.p_Other` is an unrelated query. The demo runs `p_Runaway` once
so Query Store records it, finds its `query_id` by the procedure's
`object_id`, and sets the hint:

```sql
EXEC sys.sp_query_store_set_hints @query_id = @q,
     @query_hints = N'OPTION (USE HINT (''ABORT_QUERY_EXECUTION''))';
```

## The scenarios, and what they showed

The results below come from the tested run: SQL Server 2025 RTM-CU9-GDR.

### A — block the runaway query

| | result |
|---|---|
| `EXEC Demo.p_Runaway` | **error 8778**: "Query execution has been aborted because the ABORT_QUERY_EXECUTION hint was specified." |
| `EXEC Demo.p_Other` | ran |

The hint took effect at the next execution, with no cache clear, and nothing
else was affected.

### B — what counts as "the same query"

The same `SELECT`, character for character, sent as an ad hoc batch instead
of from the procedure: **it ran.** Query Store identifies a query by its text
*and* its context: inside a procedure, it's a different `query_id` from the
same text outside it. The block covers exactly one `query_id`. If the
application sends the query several ways, each needs its own hint.

### C — inside a transaction

`p_Runaway` called inside a transaction, after an `UPDATE`, in `TRY`/`CATCH`:

| | `XACT_STATE()` in the `CATCH` block |
|---|---|
| `XACT_ABORT OFF` | **-1** |
| `XACT_ABORT ON` | -1 |

**The abort dooms the transaction, even with `XACT_ABORT OFF`.** The update
before it can't be committed, only rolled back. Blocking a query in the
middle of a business transaction rolls back the whole transaction, not just
the report.

### D — removing the block

`sp_query_store_clear_hints` lifted it at once, and setting the hint again
restored it at once: no cache clear either way.

### E — Query Store READ_ONLY, and OFF

| Query Store | `EXEC Demo.p_Runaway` |
|---|---|
| `READ_ONLY` | **error 8778**: still blocked |
| `OFF` | **ran** |

Query Store fills up and switches itself to `READ_ONLY` on busy servers, and
the block survives that. But **turning Query Store off lifts every block**,
and someone troubleshooting Query Store's own overhead might do exactly
that.

## How to read the output

`02-demo.sql` prints three result sets:

1. every attempt
2. the verdicts, each with its evidence
3. **anything that didn't behave as predicted, which should be empty**
   on 2025 (on 2022 and earlier, the `SKIPPED` rows)

## Traps from building this

- **Turning Query Store back on didn't reliably restore the block.** In
  prototypes, after Query Store went off and on, the blocked query sometimes
  ran and sometimes failed: once even after clearing the plan cache, once
  only after it. The hint was still stored each time. The demo doesn't make
  a claim it can't repeat, so it now turns Query Store off last and back on
  at the start of the next run. If you turn Query Store off and on, **test
  the blocked query afterwards**.
- **`INSERT ... EXEC` dooms a transaction by itself.** The first version of
  scenario C captured the procedure's output with `INSERT ... EXEC`, which
  dooms the transaction on any error. It now calls the procedure directly.

## Takeaways

1. **One hint blocks one `query_id`** with error 8778, from the next
   execution, without touching the code.
2. **The same text from another context is another query.** It ran.
3. **A blocked query dooms the caller's transaction**, even with
   `XACT_ABORT OFF`.
4. **The block holds when Query Store is `READ_ONLY`, and lifts when it's
   `OFF`.** Check it after any Query Store maintenance.
5. **`sp_query_store_clear_hints` removes it at once.**

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
