# Plan cache bloat: single-use plans, and what each fix leaves behind

> **The short version:** [Plan cache bloat from ad hoc queries](https://marlonribunal.com/sqlserver-demos/plan-cache-bloat/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

An application builds its SQL by pasting values into the text:
`... WHERE CustomerID = 42`, then `= 43`, then `= 44`. To SQL Server each one
is a different query. Each is compiled, and each plan is cached, used once,
and never again. The plan cache fills with single-use plans, memory goes to
them instead of data, and CPU goes to compiling. This topic sends one query
1,000 times with a different value each time, and measures what the plan
cache holds, then and with each fix.

## The rule these scenarios are built around

**The plan cache matches on the exact text. A value written into the text
makes a new query, a new compilation and a new cached plan. `optimize for
ad hoc workloads` shrinks what a single use costs; parameters, sent by the
application or added by SQL Server, remove the duplicates.**

## Prerequisites

- **SQL Server 2017 or later** (the demo uses `STRING_AGG`). Developed and
  tested on **2025 RTM-CU10 (17.0.5035.5)** and **2022 RTM-CU25
  (16.0.4255.1)**, Linux containers; CI also runs it on 2019.
- No sample database. `01-setup.sql` creates its own database,
  `PlanCacheDemo` (about 20 MB).
- Permission to `CREATE DATABASE`, and to run `sp_configure` and
  `RECONFIGURE` (`ALTER SETTINGS`, held by `sysadmin` and `serveradmin`).

## What setup and the demo change on your instance

> **⚠ This one changes an instance-wide setting.** Run it on a scratch
> instance.

- `01-setup.sql` creates `PlanCacheDemo` and **records** two instance
  settings: `show advanced options` and `optimize for ad hoc workloads`.
  It changes nothing else.
- `02-demo.sql` turns **`optimize for ad hoc workloads` off, then on, then
  off**, which needs `show advanced options` on. While it runs, the setting
  applies to every database on the instance. At the end, the demo puts both
  settings back to the recorded values and checks that it did.
- The demo adds about 5,000 plans of its own to the plan cache (up to
  about 90 MB at once), and removes exactly those at the start and the
  end, with `DBCC FREEPROCCACHE (plan_handle)`, one plan at a time. **It
  never clears the whole plan cache.**
- Inside `PlanCacheDemo`, it switches the database to **forced
  parameterization** and back.
- `03-cleanup.sql` puts the settings back again, in case the demo stopped
  halfway, removes the demo's plans, then drops the database. Run it before
  anything else if the demo was interrupted.

## Run order

```
01-setup.sql     seconds    creates PlanCacheDemo, records the two settings
02-demo.sql      ~10 s      five scenarios, 5,000 queries
03-cleanup.sql   seconds    restores the settings, drops PlanCacheDemo
```

Run each file whole (F5).

## How it's built

`Demo.usp_Send` sends one query for customers 1 to 1,000, either with the
value written into the text and run with `EXEC ()`, as an application that
concatenates strings sends it, or as an `sp_executesql` parameter:

```sql
SELECT SUM(o.Amount) AS adhoc_a FROM Demo.Orders AS o
JOIN Demo.Customers AS c ON c.CustomerID = o.CustomerID WHERE o.CustomerID = 42;
```

`Demo.usp_Cache` reads `sys.dm_exec_cached_plans` for that query: full ad hoc
plans, stubs, prepared (parameterized) plans, their size and use counts.

## The scenarios, and what they showed

The results below come from the tested run on SQL Server 2025 RTM-CU10. 2022
gave the same counts, and slightly smaller plans.

### A — ad hoc SQL

| | |
|---|---|
| full ad hoc plans cached | **1,000**, each used once |
| cache used | **88,000 KB** (80,000 KB on 2022) |
| distinct `query_hash` values among them | **1** |

88 KB per plan, for one join. The last row is how to find this on a real
server: the 1,000 plans have different text, but one `query_hash`.

### B — simple parameterization

A simpler, single-table query (`SELECT SUM(Amount) FROM Demo.Orders WHERE
CustomerID = 42`) is one SQL Server can parameterize by itself:

| | |
|---|---|
| prepared plans | **2**: `(@1 tinyint)` used 255 times, `(@1 smallint)` used 745 times |
| ad hoc entries still cached | **1,000** |
| cache used | 16,128 KB |

Two surprises. **The parameter's type comes from the literal**: 1 to 255 fit a
`tinyint`, 256 and up a `smallint`, and each type is a separate plan. And
**every original text still gets a cache entry**, a shell that points to the
prepared plan: 16 KB each here. Simple parameterization also only applies to
simple queries: the join in A didn't qualify.

### C — `optimize for ad hoc workloads`

The join from A again, with the setting on:

| | |
|---|---|
| after 1,000 values | **1,000 stubs**, no full plans |
| cache used | **445 KB** (was 88,000) |
| after customer 1's query ran a second time | 1 full plan, 999 stubs |

The first run of a text caches a stub of under half a KB; only a second run
of the same text caches the plan. It saves memory, not compilations: each of
the 1,000 queries was still compiled.

### D — forced parameterization

```sql
ALTER DATABASE CURRENT SET PARAMETERIZATION FORCED;
```

| | |
|---|---|
| prepared plans | **1**, used 1,000 times |
| ad hoc entries still cached | 1,000 shells |
| cache used | 16,088 KB |

The join that simple parameterization skipped is parameterized, with one
parameter type. The shells remain. Forced parameterization changes every
query in the database, including queries that were better off compiled for
their values; [parameter sniffing](../parameter-sniffing/) and
[filtered indexes](../filtered-index/) show what that can cost.

### E — `sp_executesql` with a parameter

| | |
|---|---|
| prepared plans | **1**, used 1,000 times |
| ad hoc entries | **0** |
| cache used | **88 KB** |

The fix in the application: one plan, one compilation, nothing else cached.

## How to read the output

`02-demo.sql` prints three result sets:

1. every measurement
2. the verdicts, each with its evidence; the last one (`Z`) checks that the
   instance settings are back
3. **anything that didn't behave as predicted, which should be empty**

## Traps from building this

- **A parameterized plan's text isn't the text that was sent.** SQL Server
  rewrites `AS simple_b` to `[simple_b]` when it parameterizes a query, so a
  search for the original text didn't find the prepared plans. The demo
  searches for both forms.
- **Changing `PARAMETERIZATION` clears the database's plans**, so each
  scenario's plans are counted before the next one starts.

## Takeaways

1. **One `query_hash` with many single-use plans** is the signature of
   values pasted into SQL text.
2. **Parameters in the application are the real fix**: one plan, used every
   time.
3. **`optimize for ad hoc workloads` saves memory, not compilations.** A
   first run caches a stub of under half a KB instead of a full plan.
4. **Simple and forced parameterization still cache a shell for every
   text**, and simple parameterization makes a plan per inferred parameter
   type.
5. **Forced parameterization changes every query in the database.** Test it,
   or apply it to one query with a template plan guide (not tested here).

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the
configurations named under [Prerequisites](#prerequisites), SQL Server 2025
RTM-CU10 (17.0.5035.5) and 2022 RTM-CU25 (16.0.4255.1) in Linux containers,
and nowhere else. No other version, edition, platform, or configuration has
been exercised, and the measured numbers throughout this README are from
those instances rather than a general result.

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
