# Parameter sniffing on WideWorldImporters

A stored procedure that reliably produces parameter sniffing — both the wrong
plan shape and the wrong memory grant — plus a demo harness that runs
unattended and records its own evidence.

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
that setting you will be timing the client grid rather than the server, and the
elapsed times in the summary are meaningless.

Azure Data Studio and the VS Code mssql extension have no equivalent setting —
run the file through `sqlcmd` instead and throw the output away:

```
sqlcmd -S <server> -d WideWorldImporters -i 02-demo.sql -o out.txt
```

## What each script does

**`01-setup.sql`** — creates a `Demo` schema containing:

- `Demo.OrderLinesSkewed` — real WideWorldImporters order lines plus one
  deliberately enormous customer (500,000 rows).
- `Demo.usp_CustomerLinesByPrice` — **the procedure**. One equality predicate on
  the skewed column, `ORDER BY` on unindexed columns.
- `Demo.usp_CustomerLinesByPrice_Recompile` — same query with `OPTION (RECOMPILE)`.
- `Demo.DemoResults` + `Demo.usp_Capture` — the evidence collector.
- `Demo_ParamSniffing` — an Extended Events session for sort spills and memory
  grant feedback adjustments. Optional; needs `ALTER ANY EVENT SESSION`, and the
  demo falls back to DMV evidence if you don't have it.

It also changes two things, both recorded in `Demo.DemoState` and both restored
by `03-cleanup.sql`: it raises the compatibility level (WWI ships at 130; row
mode memory grant feedback needs 150), and on SQL Server 2022+ it turns
`PARAMETER_SENSITIVE_PLAN_OPTIMIZATION` off.

**`02-demo.sql`** — five scenarios, evidence captured after every execution:

| | Scenario | Shows |
|---|---|---|
| A | Sniff minnow, run whale | Plan built for ~300 rows reused for 500,000. Half a million key lookups, sort spills to tempdb. |
| B | Sniff whale, run minnow | Hundreds of MB of grant reserved to return a handful of rows. |
| C | Memory grant feedback | The grant self-corrects across six executions. **The plan shape never does.** |
| D | `OPTION (RECOMPILE)` | Correct grant in both directions — and nothing left in cache for feedback to attach to. |
| E | Parameter Sensitive Plan optimization | 2022+ only. The engine caches multiple variants and handles it itself. |

The three result sets at the bottom are the payoff: a full summary with
`LIKELY SPILLED` / `GRANT WASTED` flags, the scenario C grant trajectory, and
the Extended Events output.

**`03-cleanup.sql`** — restores the compatibility level and scoped
configurations from `Demo.DemoState`, drops the event session, drops the schema.
Prints a before/after so you can check it against `01-setup.sql`'s opening output.

## Design notes

**Why a new table rather than stock WWI tables?** WideWorldImporters is
generated with near-uniform distributions. No equality predicate on the stock
OLTP tables has enough skew to flip a plan hard. The skew here is built
deliberately and in the open rather than hunted for, so the demo is
deterministic. The whale and minnow `CustomerID`s are *selected from your data*
and printed, not hardcoded — WWI ships in more than one shape.

**Why no `TOP` and no `ROW_NUMBER()` in the procedure?** Either can give you a
Top N Sort, whose memory grant is sized from *n* rather than from the input row
count. That would silently delete the memory-grant half of the demo. The capture
proc records the plan shape, and flags `Top N Sort` as a broken demo if it ever
appears.

**Why a narrow non-clustered index with no `INCLUDE`s?** It forces the optimizer
to choose between seek+key-lookup and clustered scan. That choice is the
plan-shape half of parameter sniffing. Make the index covering and the choice
disappears, leaving only the grant half.

**`sp_recompile`, never `DBCC FREEPROCCACHE`.** There is no reason to flush an
entire instance's plan cache to reset one procedure.

**Scenario D cannot show you a plan shape.** `OPTION (RECOMPILE)` leaves nothing
in the plan cache, so the harness has no plan to read and reports
`(no cached plan …)`. That absence *is* the finding — it is why memory grant
feedback has nothing to attach to. To watch the shape flip, turn on the actual
execution plan and run scenario D's two `EXEC` statements by hand.

## Caveat

**None of this has been executed.** It was written without access to a SQL Server
instance. Run it against a scratch copy of WideWorldImporters before relying on
it, and expect a few hundred MB of data plus transaction log for the 500,000-row
load.

If a scenario refuses to misbehave, the bottom of `02-demo.sql` has a diagnostic
checklist ordered by likelihood.
