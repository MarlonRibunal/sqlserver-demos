# tempdb space governance in SQL Server 2025: capping tempdb per workload group

> **The short version:** [Capping tempdb with Resource Governor (SQL Server 2025)](https://marlonribunal.com/sqlserver-demos/tempdb-space-governance/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

One runaway query fills tempdb, and every session on the instance starts
failing. Until 2025 the only defence was to size tempdb and watch it. SQL
Server 2025 lets Resource Governor cap how much tempdb a workload group can
use: `GROUP_MAX_TEMPDB_DATA_MB` or `GROUP_MAX_TEMPDB_DATA_PERCENT`. This
topic sets a 20 MB cap and measures what fails, what counts against it, and
when the cap isn't enforced at all.

## The rule these scenarios are built around

**The limit is a total for the whole workload group, and it is enforced
only after `ALTER RESOURCE GOVERNOR RECONFIGURE`. Temporary tables, table
variables and sort spills count; the version store doesn't. The query that
goes over fails with error 1138 and dooms its transaction. A percentage
limit is ignored unless tempdb has a fixed size.**

## Prerequisites

- **SQL Server 2025 or later.** Developed and tested on **2025 RTM-CU10
  (17.0.5035.5)**, Linux container, and passes on RTM-CU9-GDR
  (17.0.5015.4). On 2022 and earlier the scripts still run, and the demo
  reports every scenario as `SKIPPED` and changes nothing.
- No sample database. `01-setup.sql` creates its own database,
  `TempGovDemo`.
- Permission to `CREATE DATABASE` and `CONTROL SERVER` (for Resource
  Governor).

## What setup and the demo change on your instance

> **⚠ This one changes an instance-wide setting.** Run it on a scratch
> instance.

- `01-setup.sql` creates `TempGovDemo` and **records** the current Resource
  Governor settings: whether it's enabled, and the default workload group's
  tempdb limits. It changes nothing else.
- `02-demo.sql` sets **`GROUP_MAX_TEMPDB_DATA_MB = 20` on the `default`
  workload group** and **enables Resource Governor**. The default group
  holds every session that no classifier function sends elsewhere: on most
  servers, all of them. While the demo runs, they share 20 MB of tempdb.
  At the end, the demo puts back the recorded settings and checks that it
  did.
- `03-cleanup.sql` puts them back again, in case the demo stopped halfway,
  then drops the database. Run it before anything else if the demo was
  interrupted.

## Run order

```
01-setup.sql     seconds   creates TempGovDemo; records the Resource Governor settings
02-demo.sql      ~2 min    five scenarios; restores Resource Governor at the end
03-cleanup.sql   seconds   restores Resource Governor again, drops TempGovDemo
```

Run each file whole (F5).

## How it's built

Each test runs one statement through `Demo.usp_Try`, which returns the error
number it raised. The data comes from `Demo.Numbers`, a table in the demo
database, so generating rows doesn't use tempdb itself. The "50 MB" test
inserts 6,400 rows of `char(8000)` into a temporary table.

Between tests, `Demo.usp_Drain` waits until the default group's tempdb use
drops below 4 MB. A dropped temporary table's pages are freed in the
background, and until then they still count against the group.

## The scenarios, and what they showed

The results below come from the tested run: SQL Server 2025 RTM-CU10.

### A — before the limit is applied

| | result |
|---|---|
| no limit: 50 MB into a temporary table | ran |
| no limit: a sort that spills about 45 MB | ran |
| `ALTER WORKLOAD GROUP [default] WITH (GROUP_MAX_TEMPDB_DATA_MB = 20)`, no `RECONFIGURE` | `is_reconfiguration_pending` = 1 |
| the same 50 MB | **ran** |

**`ALTER WORKLOAD GROUP` stores the limit; nothing enforces it until
`ALTER RESOURCE GOVERNOR RECONFIGURE`.**

### B — a 20 MB limit

After `ALTER RESOURCE GOVERNOR RECONFIGURE`, which also enabled Resource
Governor:

| | result |
|---|---|
| 50 MB into a temporary table | **error 1138** |
| 10 MB | ran |
| 15 MB into one temporary table | ran |
| 15 MB into each of two temporary tables | **error 1138** |
| `total_tempdb_data_limit_violation_count` | +2 |

Error 1138: "Could not allocate a new page for database 'tempdb' because
that would exceed the limit set for workload group 'default', group_id 2."
The limit is a total for the group, not per table or per session: the
second 15 MB table failed. Every refusal is counted in
`sys.dm_resource_governor_workload_groups`.

### C — what counts

| | result |
|---|---|
| 50 MB into a table variable | **error 1138** |
| the sort that spilled in A | **error 1138** |
| `UPDATE` of all 50 MB of `Demo.Wide` under `READ_COMMITTED_SNAPSHOT` | ran |
| version store in tempdb during that update | **50 MB** |
| tempdb the default group held at that moment | 336 KB |

Table variables and spills count, like temporary tables. **The version
store doesn't**: 50 MB of row versions, more than twice the limit, and the
group held 336 KB. A long-running transaction under RCSI can still fill
tempdb with the limit in place.

### D — inside a transaction

A transaction inserted a row, then ran the 50 MB insert:

| | result |
|---|---|
| the insert | error 1138 |
| `XACT_STATE()` | **-1** |
| rows kept from before the error | 0 |

Error 1138 is severity 17 and **dooms the transaction**: the work before it
can only be rolled back.

### E — a percentage limit

`GROUP_MAX_TEMPDB_DATA_PERCENT = 1` instead of the 20 MB limit. The
container's 8 tempdb data files all autogrow with no `MAXSIZE`:

| | result |
|---|---|
| `RECONFIGURE` | message: "GROUP_MAX_TEMPDB_DATA_PERCENT is not in effect because tempdb configuration requirements aren't met." |
| 50 MB into a temporary table | **ran** |

A percentage needs a fixed-size tempdb to be a percentage of. The message
is informational, not an error, so a deployment script carries on, and
nothing is limited.

## How to read the output

`02-demo.sql` prints three result sets:

1. every attempt
2. the verdicts, each with its evidence, ending with the check that
   Resource Governor is back as setup found it
3. **anything that didn't behave as predicted, which should be empty**
   on 2025 (on 2022 and earlier, the `SKIPPED` rows)

If tempdb on your instance has fixed-size files, scenario E reports
`INCONCLUSIVE`: there the percentage limit would apply.

## Traps from building this

- **A dropped temporary table still counts for a moment.** In prototypes a
  one-row insert failed with 1138 straight after a big temporary object
  had gone. The pages are freed in the background (deferred drop). The
  demo waits for them before each test.
- **Loading data can hit the limit too.** A prototype that built its test
  table with `INSERT ... SELECT` from a cross join of `sys.all_columns`
  failed with 1138: the query's work tables are in tempdb. The setup now
  loads its tables before any limit is set, from a numbers table.

## Takeaways

1. **Apply it with `ALTER RESOURCE GOVERNOR RECONFIGURE`.** Until then the
   limit is stored, not enforced.
2. **It's a total for the group.** Put the reporting workload in its own
   group with a classifier function, rather than capping `default`.
3. **Temporary tables, table variables and spills count; the version store
   doesn't.**
4. **The query that goes over fails with error 1138 and dooms its
   transaction.** Anything that can be capped needs to handle that.
5. **A percentage limit needs fixed-size tempdb files.** Check the message
   after `RECONFIGURE`, or use `GROUP_MAX_TEMPDB_DATA_MB`.

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the
configurations named under [Prerequisites](#prerequisites), SQL Server 2025
RTM-CU10 (17.0.5035.5) and RTM-CU9-GDR (17.0.5015.4) in a Linux container,
and nowhere else. No other version, edition, platform, or configuration has
been exercised, and the measured numbers throughout this README are from
that one instance rather than a general result.

**This demo changes an instance-wide setting while it runs.** Run it only on
a scratch instance you can afford to lose, and read every script before you
run it. You alone are responsible for reviewing, testing, and deciding
whether to run anything here.

To the fullest extent permitted by law, the author provides these scripts
WITHOUT WARRANTY OF ANY KIND, express or implied, and shall not be liable for
any claim, damages, data loss, service interruption, or other liability arising
from or in connection with their use. See the
[full disclaimer](../README.md#disclaimer).

These scripts and this README were written with the help of AI. The results
come from running the scripts on SQL Server, not from the AI. See
[how this was made](../README.md#how-this-was-made).
