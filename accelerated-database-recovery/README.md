# Accelerated Database Recovery: instant rollback, and what it costs

> **The short version:** [Accelerated Database Recovery](https://marlonribunal.com/sqlserver-demos/accelerated-database-recovery/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

A killed batch job that takes longer to roll back than it ran. A log that
fills behind one long transaction. A restart that spends an hour in
recovery. Accelerated Database Recovery (ADR, SQL Server 2019+) exists for
all three. It keeps the old version of every changed row inside the
database, so undoing a transaction doesn't mean replaying its log
backwards. This topic runs the same big transaction with ADR off and on,
and measures what it gives and what it costs. That includes the open
transaction that keeps its version store from being cleaned up.

## The rule these scenarios are built around

**ADR makes rollback and recovery near-instant and lets the log truncate
under long transactions. It pays for that with slower writes, a version
store inside the database, and tables that grow. Turn it on where long
rollbacks or recoveries hurt, then watch the version store, and the
transactions that keep it from shrinking.**

## Prerequisites

- SQL Server **2019** or later. Developed and tested on **2022 CU25
  (16.0.4255.1)**, Linux container.
- No sample database. `01-setup.sql` creates its own database, `AdrDemo`.
- Permission to `CREATE DATABASE`, `ALTER DATABASE`, and `VIEW SERVER STATE`.
- About 1.5 GB of free disk.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched

Inside `AdrDemo`, setup turns on Service Broker (for scenario D's background
session). The demo switches ADR off and on **for `AdrDemo` only**, rebuilds
its table, shrinks its log, and runs `sys.sp_persistent_version_cleanup` on
it. `03-cleanup.sql` drops the database and confirms that none of its files
remain.

## Run order

```
01-setup.sql     ~10 s     creates AdrDemo: 1,000,000 rows, the background session
02-demo.sql      ~30 s     five scenarios; prints a summary
03-cleanup.sql   seconds   drops AdrDemo
```

Run each file whole (F5). **No second window is needed.** Scenario D's other
transaction is held by a background session started through Service Broker
activation (see [transaction-log-full](../transaction-log-full/) for the same
technique).

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25. The big
transaction updates all 1,000,000 rows of `Demo.Big` twice, then rolls back.

| | ADR off | ADR on |
|---|---|---|
| A: `ROLLBACK` | **2,036 ms** | **0 ms** |
| B: log in use, transaction still open, after `CHECKPOINT` | 640 MB | **132 MB** |
| C: the updates themselves | 1,462 ms | **4,443 ms** |
| C: version store at the end of the transaction | | **320 MB** |

### A — rollback

Without ADR, rolling back means reading the transaction's log backwards and
undoing every change: **2 seconds** here. In production, after hours of work,
it can take hours, and a `KILL` doesn't make it faster. With ADR the
`ROLLBACK` took **0 ms**. The old versions are already in the version store,
so the transaction is just marked aborted and readers see the old versions.
The same logic makes **crash recovery** fast: recovery no longer has to undo
long transactions. The demo doesn't crash the instance to show it.

### B — the log under a long transaction

Without ADR, the log can't be truncated past the start of the oldest open
transaction (see [transaction-log-full](../transaction-log-full/)): **640
MB** in use. With ADR, the log is no longer needed to undo the transaction,
so a checkpoint can truncate it: **132 MB**, even though the transaction was
still open.

### C — what it costs

The same updates took **3× as long** with ADR (4.4 s against 1.5 s, nearly
all of it CPU), because every row change also writes the row's previous
version. At the end of the transaction the persistent version store held
**320 MB**, inside the user database, in its primary filegroup unless you
move it (`PERSISTENT_VERSION_STORE_FILEGROUP`). After the rollback, `sys.sp_persistent_version_cleanup` took it back to
8 MB. The cleaner normally does this in the background.

### D — the transaction that blocks the cleanup

| | version store |
|---|---|
| a batch updates every row twice and fails (rolls back), while another session has a transaction open | **320 MB** |
| cleanup, the other transaction still open | **320 MB**, nothing removed |
| cleanup, after it ended | 8 MB |

The other transaction did nothing but insert one row and wait, like a
forgotten `BEGIN TRAN` or an hour-long report. The aborted versions belonged
to a different session and were needed by nobody. Still, the cleaner can't
remove them while an older transaction is open, and every further failure
would add to them. **The long-open transaction is the version store's
enemy**, as it is the log's without ADR. Watch for it.

### E — the table itself

| `Demo.Big` | size |
|---|---|
| at the start | 211.5 MB |
| after ADR versioned its rows (rolled back, versions cleaned up) | **423.3 MB** |
| rebuilt | 211.5 MB |

With ADR, a changed row can carry its previous version inside the row. Full
pages have no room for the extra bytes, so they split. The table **doubled**,
and stayed doubled after the transaction was rolled back and its versions
cleaned up. An index rebuild packed it again.

## Traps from building this

- **`persistent_version_store_size_kb` was stale.** On the tested build,
  `sys.dm_tran_persistent_version_store_stats` updated its size only when
  the cleaner ran. It read 136 KB while 300 MB of versions sat in the store.
  The demo reads the internal table `persistent_version_store` through
  `sys.allocation_units` instead.
- **Not every update fills the version store.** In the tested runs a
  committed update of every row added nothing measurable to it, and a single
  rolled-back update of every row added about 16 MB. Updating every row
  *twice* in one transaction, then rolling back, added 320 MB every time. ADR
  can keep a row's previous version inside the row; the second change has to
  go to the store. D uses the double update for that reason.

## How to read the output

`02-demo.sql` prints three result sets:

1. every measurement: time, CPU, rollback, log, version store, table size
2. the verdicts
3. **anything that didn't behave as predicted, which should be empty**

## Takeaways

1. **Rollback is instant with ADR**: 2,036 ms became 0.
2. **The log truncates under an open transaction**: 132 MB in use instead of
   640.
3. **Writes cost more**: 3× the time here, and a 320 MB version store in the
   database.
4. **One open transaction blocks the version store cleanup**, as it pins the
   log without ADR.
5. **Versioned tables grow**: `Demo.Big` doubled until it was rebuilt.

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

These scripts and this README were written with the help of AI. The results
come from running the scripts on SQL Server, not from the AI. See
[how this was made](../README.md#how-this-was-made).
