# Parameter sniffing, `RECOMPILE`, and memory grant feedback

**Sample database:** WideWorldImporters · **Min. version:** SQL Server 2017
(2019+ for full effect) · **Status:** ⚠️ Untested — [see below](#status)

A stored procedure that reliably produces parameter sniffing, and a harness that
demonstrates it unattended.

The point of the demo is that parameter sniffing is **two** failures, not one — a
wrong **plan shape** and a wrong **memory grant**. They have different symptoms
and different fixes, and memory grant feedback only ever fixes one of them.

## Prerequisites

| | Requirement | Why |
|---|---|---|
| Engine | SQL Server 2017+ | 2019+ for row-mode memory grant feedback (scenario C); 2022 for PSP (scenario E) |
| Edition | Developer / Enterprise / Standard | Developer is free for non-production |
| Permissions | `db_owner` on the database | Create objects, `ALTER DATABASE` |
| | `ALTER ANY EVENT SESSION` (server) | Optional — without it the demo falls back to DMV evidence |
| Disk | ~1.5 GB free | ~1 GB for the sample database, a few hundred MB for the demo table |

**Do not run this against production.** `01-setup.sql` changes database-level
settings by design — see [What setup changes](#what-setup-changes-on-your-database).

### Getting WideWorldImporters

Download `WideWorldImporters-Full.bak` from
[sql-server-samples releases](https://github.com/microsoft/sql-server-samples/releases/tag/wide-world-importers-v1.0).
`WideWorldImporters-Standard.bak` works too — this demo only touches
`Sales.Orders`, `Sales.OrderLines`, `Sales.Customers`, and
`Warehouse.StockItems`, all plain rowstore in both variants.

Get the logical file names first; they differ between the two backups:

```sql
RESTORE FILELISTONLY FROM DISK = N'C:\temp\WideWorldImporters-Full.bak';
```

Then restore:

```sql
RESTORE DATABASE WideWorldImporters
FROM DISK = N'C:\temp\WideWorldImporters-Full.bak'
WITH  MOVE N'WWI_Primary'         TO N'C:\SQLData\WideWorldImporters.mdf',
      MOVE N'WWI_UserData'        TO N'C:\SQLData\WideWorldImporters_UserData.ndf',
      MOVE N'WWI_Log'             TO N'C:\SQLLog\WideWorldImporters.ldf',
      MOVE N'WWI_InMemory_Data_1' TO N'C:\SQLData\WideWorldImporters_InMemory_Data_1',
      RECOVERY, STATS = 5;
```

Two things that trip people up: the In-Memory filegroup's `MOVE` target is a
**directory**, not a file — no extension — and it's absent from the Standard
backup, so drop that line if `FILELISTONLY` didn't list it. On Docker, `docker cp`
the backup into the container first and use Linux paths.

## Run order

| # | Script | When | Runs the demo? | Roughly |
|---|--------|------|----------------|---------|
| 1 | `01-setup.sql` | Once, first | No | A few minutes |
| 2 | `02-demo.sql` | After setup. Re-runnable. | **Yes** | A few minutes |
| 3 | `03-cleanup.sql` | Last | No | Seconds |

Each file is safe to run top to bottom in one go (F5). Nothing needs stepping
through.

## Before you run `02-demo.sql`

Turn on **SSMS → Query Options → Results → Grid → "Discard results after
execution"**.

The procedure returns 500,000 wide rows about ten times during the demo. Without
that setting you are timing the client grid rather than the server, and the
elapsed times in the summary are meaningless.

Azure Data Studio and the VS Code mssql extension have no equivalent setting —
run the file through `sqlcmd` instead and throw the output away:

```
sqlcmd -S <server> -d WideWorldImporters -i 02-demo.sql -o out.txt
```

Worth checking first, since a low ceiling caps grants and flattens the contrast
between scenarios:

```sql
SELECT name, value_in_use FROM sys.configurations
WHERE name = 'max server memory (MB)';
```

## What each script does

**`01-setup.sql`** — creates a `Demo` schema containing:

- `Demo.OrderLinesSkewed` — real WideWorldImporters order lines plus one
  deliberately enormous customer (500,000 rows).
- `Demo.usp_CustomerLinesByPrice` — **the procedure**. One equality predicate on
  the skewed column, `ORDER BY` on unindexed columns.
- `Demo.usp_CustomerLinesByPrice_Recompile` — same query with `OPTION (RECOMPILE)`.
- `Demo.DemoResults` + `Demo.usp_Capture` — the evidence collector.
- `Demo.vw_GrantStats` / `Demo.vw_CachedPlan` — for poking around afterwards.
- `Demo_ParamSniffing` — an Extended Events session for sort spills and memory
  grant feedback adjustments. Optional, as noted in the prerequisites.

**`02-demo.sql`** — five scenarios, evidence captured after every execution:

| | Scenario | Shows |
|---|---|---|
| A | Sniff minnow, run whale | Plan built for a few hundred rows reused for 500,000. Key lookups by the half million, sort spills to tempdb. |
| B | Sniff whale, run minnow | Hundreds of MB of grant reserved to return a handful of rows. No spill, no slow query — invisible to a duration-based monitor. |
| C | Memory grant feedback | The grant self-corrects across six executions. **The plan shape never does.** |
| D | `OPTION (RECOMPILE)` | Correct grant in both directions — and nothing left in cache for feedback to attach to. |
| E | Parameter Sensitive Plan optimization | 2022+ only. The engine caches multiple variants and handles it without recompiling. |

**`03-cleanup.sql`** — restores the compatibility level and scoped configurations
from `Demo.DemoState`, drops the event session, drops the schema. Prints a
before/after you can check against `01-setup.sql`'s opening output.

## How to read the output

Three result sets at the bottom of `02-demo.sql`:

1. **The summary** — one row per execution, with two computed flag columns:
   `LIKELY SPILLED` when the ideal grant far exceeds what was granted, and
   `GRANT WASTED` when the grant far exceeds what was used. Those two flags are
   the two failure modes.
2. **Scenario C trajectory** — `GrantDeltaMB` and `MGFeedbackState` across six
   executions. `MGFeedbackState` should move through `NoFirstExecution` →
   `YesAdjusting` → `YesStable`. `PlanShape` should be identical on all six rows;
   that is the whole point of the scenario.
3. **Extended Events** — `sort_warning` and `memory_grant_updated_by_feedback`,
   shredded as name/value pairs.

Raw data stays in `Demo.DemoResults` until cleanup, so you can query it
afterwards.

If a scenario refuses to misbehave, the bottom of `02-demo.sql` has a diagnostic
checklist ordered by likelihood — usually PSP still being on, a compatibility
level below 150, or a plan going parallel.

## What setup changes on your database

Both recorded in `Demo.DemoState` before being changed, both restored by
`03-cleanup.sql`:

| Change | Why |
|---|---|
| Compatibility level raised to the engine's maximum | WideWorldImporters ships at 130. Row-mode memory grant feedback needs 150; PSP needs 160. |
| `PARAMETER_SENSITIVE_PLAN_OPTIMIZATION` set `OFF` (2022+) | PSP targets exactly this query shape and would fix scenarios A and B before you saw them fail. Scenario E turns it back on for the contrast. |

Everything else is additive: one schema, one table of demo data, two procedures,
two views, a results table, a capture proc, and one server-level Extended Events
session.

## Design notes

**Why a new table rather than stock WWI tables?** WideWorldImporters is generated
with near-uniform distributions. No equality predicate on the stock OLTP tables
has enough skew to flip a plan hard. The skew here is built deliberately and in
the open rather than hunted for, so the demo is deterministic. The whale and
minnow `CustomerID`s are *selected from your data* and printed, not hardcoded —
WWI ships in more than one shape.

**Why no `TOP` and no `ROW_NUMBER()` in the procedure?** Either can give you a
Top N Sort, whose memory grant is sized from *n* rather than from the input row
count. That would silently delete the memory-grant half of the demo while still
looking correct. The capture proc records the plan shape and flags `Top N Sort`
as a broken demo if it ever appears.

**Why a narrow non-clustered index with no `INCLUDE`s?** It forces the optimizer
to choose between seek+key-lookup and clustered scan. That choice is the
plan-shape half of parameter sniffing. Make the index covering and the choice
disappears, leaving only the grant half.

**Scenario D cannot show you a plan shape.** `OPTION (RECOMPILE)` leaves nothing
in the plan cache, so the harness has no plan to read and reports
`(no cached plan …)`. That absence *is* the finding — it is why memory grant
feedback has nothing to attach to. To watch the shape flip, turn on the actual
execution plan and run scenario D's two `EXEC` statements by hand.

**`sp_recompile`, never `DBCC FREEPROCCACHE`.** There is no reason to flush an
entire instance's plan cache to reset one procedure.

## Status

⚠️ **Untested.** These scripts were written without access to a SQL Server
instance. Nothing here has been executed, and no output has been verified. Run
them against a scratch copy of WideWorldImporters before relying on anything, and
expect a few hundred MB of data plus transaction log for the 500,000-row load.
