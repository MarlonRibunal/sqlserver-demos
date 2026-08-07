# Parameter sniffing, `RECOMPILE`, and memory grant feedback

**Sample database:** WideWorldImporters · **Min. version:** SQL Server 2017
(2019+ for scenario C, 2022+ for E and F) · **Status:** tested in a limited,
controlled environment — [see below](#status)

A stored procedure that reliably produces parameter sniffing, and a harness that
demonstrates it unattended.

The point of the demo is that parameter sniffing is **two** failures, not one — a
wrong **plan shape** and a wrong **memory grant**. They have different symptoms
and different fixes, and memory grant feedback only ever fixes one of them.

## Prerequisites

| | Requirement | Why |
|---|---|---|
| Engine | SQL Server 2017+ | 2019+ for row-mode memory grant feedback (scenario C); 2022 for PSP (scenario E) and feedback persistence (scenario F) |
| Edition | Developer / Enterprise / Standard | Developer is free for non-production |
| Permissions | `db_owner` on the database | Create objects, `ALTER DATABASE` |
| | `ALTER ANY EVENT SESSION` (server) | Optional — without it the demo falls back to DMV evidence, except `MGFeedbackState`, which has no DMV source ([why](#design-notes)) |
| Disk | ~1.5 GB free | ~1 GB for the sample database, a few hundred MB for the demo table. Query Store, which setup switches on for scenario F, holds about 1 MB for this workload — measured, two queries and two plans — but is enabled at its default 1 GB cap |

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
| 2 | `02-demo.sql` | After setup. Re-runnable. | **Yes** | Several minutes |
| 3 | `03-cleanup.sql` | Last | No | Seconds |

Each file is safe to run top to bottom in one go (F5). Nothing needs stepping
through.

## Before you run `02-demo.sql`

Turn on **SSMS → Query Options → Results → Grid → "Discard results after
execution"**.

The procedure returns 500,000 wide rows about twenty times during the demo,
sixteen of them inside the loops in scenarios C and F. Without that setting you
are timing the client grid rather than the server, and the elapsed times in the
summary are meaningless.

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
- `Demo.usp_BackfillEvidence` — fills in `MGFeedbackState` from the captured
  actual plans, once, after the run. See *Why one column comes from Extended
  Events* below.
- `Demo.vw_GrantStats` / `Demo.vw_CachedPlan` — for poking around afterwards.
- `Demo_ParamSniffing` — an Extended Events session for sort spills, memory
  grant feedback adjustments, and the actual plans. Optional, as noted in the
  prerequisites — but `MGFeedbackState` is blank without it.

**`02-demo.sql`** — six scenarios, evidence captured after every execution:

| | Scenario | Shows |
|---|---|---|
| A | Sniff minnow, run whale | Plan built for a few hundred rows reused for 500,000. Key lookups by the half million, sort spills to tempdb. |
| B | Sniff whale, run minnow | Hundreds of MB of grant reserved to return a handful of rows. No spill, no slow query — invisible to a duration-based monitor. |
| C | Memory grant feedback | The grant corrects itself over repeated executions — overshooting and re-correcting on 2022+. **The plan shape never does.** |
| D | `OPTION (RECOMPILE)` | Correct plan *and* correct grant in both directions — paid for with a compile per call and nothing accumulating for feedback to learn from. |
| E | Parameter Sensitive Plan optimization | 2022+ only. Checks whether PSP built a dispatcher plan and reports the verdict — on the tested 2025 run, this query did not qualify and PSP did not engage. |
| F | Feedback that outlives the plan | 2022+ only. `sp_recompile` throws the plan away; the learned grant comes back anyway, out of Query Store. |

**`03-cleanup.sql`** — restores the compatibility level, the scoped
configurations, and Query Store's desired state from `Demo.DemoState`, drops the
event session, drops the schema. Prints a before/after you can check against
`01-setup.sql`'s opening output. Query Store's collected data is left alone —
turning it off does not discard it, and that history is not this script's to
delete.

## How to read the output

Five result sets at the bottom of `02-demo.sql`:

1. **The summary** — one row per execution, with two computed flag columns:
   `SPILLED xN` counting `sort_warning` events for that execution, and
   `GRANT WASTED` when the grant far exceeds what was used. Those two flags are
   the two failure modes. `SPILLED` needs the Extended Events session; there is
   no DMV that answers "did this execution spill" (see [Design notes](#design-notes)).
2. **Scenario C trajectory** — `GrantDeltaMB` and `MGFeedbackState` across six
   executions. The states are the engine's own strings, colons and spaces
   included: `No: First Execution`, `No: Accurate Grant`, `Yes: Adjusting`,
   `Yes: Stable`, and on 2022+ `Yes: Percentile Adjusting`. Expect movement,
   not a tidy climb — 2022's percentile feedback sizes the grant from a history
   of executions rather than the last one, so it can overshoot, settle below
   ideal, and move again later. `PlanShape` should be identical on all six rows;
   that is the whole point of the scenario.
3. **Scenario F, the grant that survived a recompile** — the two `AFTER
   RECOMPILE` rows side by side. Same plan, same 1,000 rows, same fresh compile;
   the only difference is whether `MEMORY_GRANT_FEEDBACK_PERSISTENCE` was on.
   Expect roughly two orders of magnitude between the two `GrantMB` values and
   a `GRANT WASTED` flag on the persistence-ON row.
4. **The persisted feedback itself** — `sys.query_store_plan_feedback`, where
   `AdditionalMemoryKB` in `feedback_data` is the number a fresh compile would
   be handed. Scenario F also prints this mid-run, before its recompile, so you
   can read the number in Query Store and then watch it turn up as a grant. The
   two readings may differ: feedback keeps learning after the scenario ends, and
   persisting a revision is asynchronous.
5. **Extended Events** — `sort_warning` plus whichever feedback event this build
   uses, shredded as name/value pairs. On 2019 that is
   `memory_grant_updated_by_feedback`; on 2022+ percentile feedback fires
   `memory_grant_updated_by_percentile_grant` instead, and the older event can
   stay silent for the entire run even while the grant is visibly moving. On a
   2022 run, look for `is_persisted_feedback_used` — that field is scenario F
   in one boolean.

Raw data stays in `Demo.DemoResults` until cleanup, so you can query it
afterwards.

If a scenario refuses to misbehave, the bottom of `02-demo.sql` has a diagnostic
checklist ordered by likelihood — usually PSP still being on, a compatibility
level below 150, or a plan going parallel.

## What setup changes on your database

All recorded in `Demo.DemoState` before being changed, all restored by
`03-cleanup.sql`:

| Change | Why |
|---|---|
| Compatibility level raised to the engine's maximum | WideWorldImporters ships at 130. Row-mode memory grant feedback needs 150; PSP needs 160. |
| `PARAMETER_SENSITIVE_PLAN_OPTIMIZATION` set `OFF` (2022+) | PSP targets exactly this query shape and would fix scenarios A and B before you saw them fail. Scenario E turns it back on for the contrast. |
| `ROW_MODE_MEMORY_GRANT_FEEDBACK` set `ON` (2019+) | Scenario C is entirely about this feature. Asserted rather than assumed — if it is off, the grant stays flat and the scenario reads as broken. |
| `MEMORY_GRANT_FEEDBACK_PERSISTENCE` set `OFF` (2022+) | Persisted feedback is scenario F's subject. Left on it leaks into scenario C, whose first row then shows a 250 MB grant for 15 rows before C has done anything. Scenario F turns it on for one arm. |
| Query Store set to `READ_WRITE` if it wasn't already (2016+) | Scenario F watches feedback survive a recompile, and Query Store is where it survives. Enabled at its defaults, including the 1 GB storage cap; this demo puts about 1 MB in it. Collected data is never cleared — see below. |
| `MEMORY_GRANT_FEEDBACK_PERSISTENCE` toggled during scenario F (2022+) | The scenario runs the same sequence with it off and on. Restored at the end of the scenario as well as by cleanup. |

Everything else is additive: one schema, one table of demo data, two procedures,
two views, a results table, a state table, two harness procedures, and one
server-level Extended Events session.

**What setup deliberately does not do:** `ALTER DATABASE … SET QUERY_STORE
CLEAR`. If Query Store was already collecting on this database, wiping its
history to tidy up a demo is not a trade these scripts get to make. Scenario F
is built to work without it — with `MEMORY_GRANT_FEEDBACK_PERSISTENCE = OFF` the
engine ignores whatever is already stored, so the control arm stays honest even
though scenario C ran first and taught the feedback loop a large grant.

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

**Scenario D is the one place the harness shows a plan shape flipping.**
`OPTION (RECOMPILE)` is widely described as leaving nothing in the plan cache.
That is not what happens, and it is worth being precise about, because the
harness output makes the difference visible. The *procedure's* compiled plan is
cached and reused like any other — `sys.dm_exec_cached_plans` lists it with a
rising `usecounts`. What a statement-level `RECOMPILE` removes is statement plan
*reuse*: that `SELECT` is compiled again on every execution against the actual
parameter value, and `sys.dm_exec_query_plan` returns the most recent compile.

So scenario D reports a real plan shape per row — seek for the minnow, clustered
scan for the whale, seek again for the minnow — alongside a correctly sized
grant each time. `SniffedValue` is `NULL` on those rows because nothing was
sniffed: the optimizer had the literal value, so the plan carries no
`ParameterCompiledValue`.

The cost shows up in two other columns. `ExecutionCount` stays at 1 while
scenario C's climbs, and `MGFeedbackState` stays at `No: First Execution`.
Nothing accumulates across executions, which is exactly why scenario C's
self-correcting grant cannot happen here.

**Why two columns come from Extended Events.** Every column in
`Demo.DemoResults` is read from DMVs immediately after each execution — except
`MGFeedbackState` and `SpillWarnings`.

`SpillWarnings` is there because no DMV answers "did this execution spill".
The obvious proxy — ideal grant far above granted — is not merely imprecise, it
is backwards for this demo: `last_ideal_grant_kb` is derived from the
*estimate*, and the estimate on the sniffed plan is the minnow's. A real run
puts the ideal at 0.53 MB against a 1.00 MB grant while half a million rows
spill to tempdb, so an ideal-vs-granted flag reports "no spill" in exactly the
case the demo exists to show. The count comes from `sort_warning` events
instead, matched to rows by time window — `usp_Capture` runs immediately after
each execution, so the window is tight.

As for `MGFeedbackState`:
`IsMemoryGrantFeedbackAdjusted` is a *runtime* attribute: it appears on
`MemoryGrantInfo` only in an actual execution plan.
`sys.dm_exec_query_plan` returns the compiled plan and never carries it, so
reading it there yields `NULL` on every row regardless of what feedback is doing.

`sys.dm_exec_query_plan_stats` (2019+, `LAST_QUERY_PLAN_STATS`) looks like the
way out and is not. It does return the last actual plan, but built from
lightweight profiling, and its `MemoryGrantInfo` is trimmed to
`SerialRequiredMemory`, `SerialDesiredMemory`, `GrantedMemory` and
`MaxUsedMemory`. Checked on SQL Server 2022 with feedback demonstrably adjusting
on that same plan handle: the attribute is absent from that DMV, not
`NULL`-valued.

So the actual plans are collected by the `query_post_execution_showplan` event —
pinned by `object_id` to the two demo procedures, not to the database, because
unfiltered it would capture a showplan for every statement in
WideWorldImporters. `Demo.usp_BackfillEvidence` makes one pass over the ring
buffer after the run and matches events to rows on
`(object_id, granted_memory_kb)`, with ordinal position inside that pair as the
tiebreaker. `GrantKB` exists on `Demo.DemoResults` to be the exact,
non-rounded join key.

**Scenario F is the one that changes the advice.** Scenarios C and D together
imply a clean rule: feedback lives on the cached plan, so a recompile resets it.
On 2022 that rule is wrong. Memory grant feedback is persisted in Query Store,
keyed to the plan, and re-applied to a fresh compile — so a plan can arrive
pre-loaded with a grant learned from executions it never ran, for parameter
values it was never compiled for.

The demo shows it as an A/B because a single number proves nothing: the same
teach-then-recompile sequence runs twice, differing only in
`MEMORY_GRANT_FEEDBACK_PERSISTENCE`, and the post-recompile grant differs by two
orders of magnitude. The control arm runs first, and deliberately does not clear
Query Store — with persistence off the engine ignores what is stored, which is
what keeps the arm honest and the file re-runnable.

**`sp_recompile`, never `DBCC FREEPROCCACHE`.** There is no reason to flush an
entire instance's plan cache to reset one procedure.

## Status

**Tested in a limited, controlled environment.** Everything below describes the
only configurations these scripts have been run on. Run them against a scratch
copy before relying on anything, and expect a few hundred MB of data plus
transaction log for the 500,000-row load.

**All three scripts have been run end to end on SQL Server 2025 (17.0.4055.5)
against a real WideWorldImporters**, twice — once to find defects and once to
confirm the fixes. Setup, all six scenarios, and cleanup complete with zero
errors. Representative numbers from that run: scenario A reuses the minnow's
`(1060)` plan for 500,000 rows at 1,534,658 logical reads with `SPILLED x1`;
scenario C climbs 1.00 → 250.49 MB through `Yes: Adjusting` → `Yes: Stable` with
an identical plan shape on all seven rows; scenario F splits 1.00 MB against
250.49 MB across the persistence A/B. Scenario E reports that PSP did not engage
for this query.

Three earlier partial checks, all run on SQL Server 2022 (16.x, Linux/Docker)
against a small purpose-built skewed table rather than against
WideWorldImporters:

- The `MGFeedbackState` capture path — the event session in step 7,
  `Demo.usp_Capture`, and `Demo.usp_BackfillEvidence` — produced
  `No: First Execution` → `No: Accurate Grant` → `Yes: Adjusting` →
  `Yes: Stable` across the scenario C loop.
- Scenario D's plan cache behaviour, run with the procedures verbatim from
  `01-setup.sql`: the cached plan and per-execution shape flip described above
  are what the harness actually reported, not what was originally assumed here.
- Scenario F, run end to end with the scenario block verbatim from
  `02-demo.sql`: control arm 1.23 MB against persistence-ON 102.25 MB on the
  same freshly compiled 1,000-row plan, with `AdditionalMemoryKB` of 104,192 in
  `sys.query_store_plan_feedback` and `is_persisted_feedback_used = true` in the
  event stream. That the control arm ignores already-stored feedback was tested
  separately, with a large value sitting in Query Store.

**Unverified on SQL Server 2017 and 2019 entirely, and on 2022 for anything
beyond the three partial checks above.** No other edition, host platform, or
non-default instance configuration has been exercised.

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only, and are tested only in the limited, controlled environment described
above. Run them only on a scratch instance you can afford to lose, and read
every script before you run it — you are solely responsible for reviewing,
testing, and deciding whether to run anything here.

To the fullest extent permitted by law, the author provides these scripts
WITHOUT WARRANTY OF ANY KIND, express or implied, and shall not be liable for
any claim, damages, data loss, service interruption, or other liability arising
from or in connection with their use. See the
[full disclaimer](../README.md#disclaimer).
