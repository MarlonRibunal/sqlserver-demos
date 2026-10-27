# "Slow in the app, fast in SSMS": SET options and the plan cache

> **The short version:** [Slow in the app, fast in SSMS](https://marlonribunal.com/sqlserver-demos/slow-in-app-fast-in-ssms/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

The most-asked question in SQL Server performance: a procedure is slow when
the application calls it and instant when you paste the same call into SSMS.
Four scenarios reproduce it in one session, show exactly why, and show why
the usual fix (set `ARITHABORT ON` in the app) only moves the problem
somewhere else.

## The rule these scenarios are built around

**`ARITHABORT` isn't the cause. It's a different key into the plan cache. The
slow call is running a plan sniffed for a different parameter value. Fix the
sniffing, and to reproduce the app's plan in SSMS, `SET ARITHABORT OFF`.**

## Prerequisites

- SQL Server 2016 or later. Developed and tested on **2022 CU25
  (16.0.4255.1)**.
- No sample database. `01-setup.sql` creates its own database,
  `SetOptionsDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` for the plan cache
  DMVs.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched
- no instance-wide plan cache flush (`sp_recompile` only, object scoped)

`02-demo.sql` changes `SET ARITHABORT` for **its own session**, which is the
point of the topic. Session SET options end with the session.
`03-cleanup.sql` drops the database and confirms that none of its files remain.

## Run order

```
01-setup.sql     ~5 s      creates SetOptionsDemo, 1,000,000 skewed orders, the procedure
02-demo.sql      ~3 s      four scenarios; prints a summary
03-cleanup.sql   seconds   drops SetOptionsDemo
```

Run each file whole (F5). Through sqlcmd, pass `-I`.

## How it's built

`Demo.Orders` is deliberately skewed: customer 1 owns 300,000 of the 1,000,000
orders, and every other customer about 15. `Demo.usp_CustomerSummary
@CustomerID` totals one customer's orders. Its best plan is a seek plus
lookups for a small customer, and a scan for customer 1.

One session plays both parts:

- **the app**: `SET ARITHABORT OFF`, the default for ADO.NET, ODBC, JDBC and
  most other drivers
- **SSMS**: `SET ARITHABORT ON`, the SSMS default

`Demo.usp_Call` records each call's reads and CPU. `Demo.usp_SnapshotPlans`
records every cached plan for the procedure: its `set_options` (from
`sys.dm_exec_plan_attributes`), the parameter value it was compiled for
(`ParameterCompiledValue` in the plan XML), and its shape.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25, 8 schedulers.

### A — the complaint

| | who | customer | logical reads |
|---|---|---|---|
| overnight, first call after the plan was evicted | app | 1 | 21,939 |
| this morning | app | 45 | **21,915** |
| the developer checks | SSMS | 45 | **70** |

The same call for customer 45 costs **300×** more from the app than from SSMS.
"It's fast for me."

### B — why

| `set_options` | `ARITHABORT` | compiled for | plan |
|---|---|---|---|
| 251 | OFF | customer **1** | clustered scan |
| 4347 | ON | customer **45** | seek + lookups |

SET options are part of the plan cache key. A connection with `ARITHABORT
OFF` and one with it ON can't share a plan. When the developer ran the
procedure in SSMS, it didn't find the app's plan at all. It compiled a new
one, sniffing customer 45 and choosing a seek. The app is still running the
plan compiled for customer 1.

`ARITHABORT` didn't make anything faster. It sent SSMS to a different, freshly
compiled plan.

### C — ARITHABORT is innocent

Recompile, and run the same calls in the other order:

| | who | sniffed first | customer 45 costs | customer 1 then costs |
|---|---|---|---|---|
| C1 | SSMS (ON) | customer 1 | **21,915**, as slow as the app | |
| C2 | app (OFF) | customer 45 | **48** | **900,524** (a scan was 21,939) |

With the same sniff, SSMS is exactly as slow as the app was. With the reverse
sniff, the app is fast for small customers, and customer 1 now does a seek
and 300,000 lookups at 41× the reads of a scan. Setting `ARITHABORT ON` in the
app only changes which cache entry it lands in and which customer pays.

The real fixes are the ones in the
[parameter-sniffing](../parameter-sniffing/) topic: `OPTION (RECOMPILE)`,
`OPTIMIZE FOR`, Query Store hints, or Parameter Sensitive Plan optimization on
SQL Server 2022. PSP didn't create plan variants for this query on the tested
build, so it isn't a safe assumption that it will.

### D — finding it

Result set 3 is the query to run when someone says "it's fast in SSMS". Swap
in your procedure:

```sql
WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT  SetOptions   = so.v,
        ArithAbortOn = CASE WHEN so.v & 4096 = 4096 THEN 1 ELSE 0 END,
        CompiledFor  = qp.query_plan.value('(//ParameterList/ColumnReference/@ParameterCompiledValue)[1]', 'nvarchar(100)'),
        qs.execution_count,
        AvgReads     = qs.total_logical_reads / NULLIF(qs.execution_count, 0)
FROM    sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
CROSS APPLY (SELECT v = CAST(pa.value AS int) FROM sys.dm_exec_plan_attributes(qs.plan_handle) AS pa
             WHERE pa.attribute = 'set_options') AS so
WHERE   st.objectid = OBJECT_ID('dbo.YourProcedure') AND st.dbid = DB_ID();
```

If it shows two rows with different `set_options` and different compiled
values, that's the whole diagnosis. To see the app's slow plan from SSMS, run
`SET ARITHABORT OFF;` in the query window before the `EXEC`. Your session then
lands on the app's cache entry instead of compiling its own.

## How to read the output

`02-demo.sql` prints five result sets: every call, the plan cache after
scenario A, the diagnostic query, the verdicts, and **anything that didn't
behave as predicted, which should be empty.**

## Takeaways

1. **SET options are part of the plan cache key.** The app and SSMS usually
   differ on `ARITHABORT`, so they get separate plans for the same procedure.
2. **"Fast in SSMS" usually means SSMS compiled a fresh plan for your
   parameter.** The app is running one compiled for somebody else's.
3. **Setting `ARITHABORT ON` in the app moves the lottery; it doesn't stop
   it.** With the order of first calls reversed, the big customer paid 41×.
4. **To reproduce the app, `SET ARITHABORT OFF` in SSMS.** Then fix the
   sniffing.
5. **Look in the plan cache before guessing.** One query shows every cached
   copy, its SET options and what it was compiled for.

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the single
configuration named under [Prerequisites](#prerequisites), SQL Server 2022 CU25
(16.0.4255.1) on 8 schedulers, and nowhere else. No other version, edition, or
configuration has been exercised, and the measured numbers throughout this
README are from that one instance rather than a general result.

Run them only on a scratch instance you can afford to lose, and read every
script before you run it. You alone are responsible for reviewing, testing,
and deciding whether to run anything here.

To the fullest extent permitted by law, the author provides these scripts
WITHOUT WARRANTY OF ANY KIND, express or implied, and shall not be liable for
any claim, damages, data loss, service interruption, or other liability arising
from or in connection with their use. See the
[full disclaimer](../README.md#disclaimer).
