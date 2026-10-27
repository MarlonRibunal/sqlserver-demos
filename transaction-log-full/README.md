# "Why is my transaction log full?"

> **The short version:** [Why is my transaction log full?](https://marlonribunal.com/sqlserver-demos/transaction-log-full/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

The most common production emergency there is: the log file has filled the
disk, or won't stop growing. This topic reproduces the usual causes one at a
time, measures each through the DMVs that diagnose it, and shows the reflex
fix that doesn't work. It ends with the query to run when it happens to you.

## The rule these scenarios are built around

**Ask the database why before you do anything: `log_reuse_wait_desc` names
the reason. Fix the reason (take a log backup, end the transaction), then
shrink if you must. Grow the log in large steps.**

## Prerequisites

- SQL Server 2016 SP2 or later (for `sys.dm_db_log_info`). Developed and
  tested on **2022 CU25 (16.0.4255.1)**, Linux container.
- No sample database. `01-setup.sql` creates its own database, `LogFullDemo`.
- Permission to `CREATE DATABASE`, `BACKUP DATABASE` / `BACKUP LOG`, and
  `VIEW SERVER STATE`.
- About 1.5 GB of free disk: the demo grows logs on purpose.

## What setup changes on your instance

Nothing outside the databases it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched

Inside `LogFullDemo`, setup turns on Service Broker, and the demo switches its
recovery model, resizes its log, and backs it up to the **null device**
(`DISK = N'NUL'`). That writes no file anywhere. **Don't do it to a database
you need to restore**: a backup to `NUL` can't be restored, and it breaks the
chain your real backups depend on. The backups leave ordinary history rows in
`msdb`. Scenario D briefly creates and drops a second database,
`LogFullDemo_VLF`. `03-cleanup.sql` drops both and confirms that none of their
files remain.

## Run order

```
01-setup.sql     seconds   creates LogFullDemo, the background holder
02-demo.sql      ~20 s     four scenarios; prints a summary
03-cleanup.sql   seconds   drops LogFullDemo (and LogFullDemo_VLF, if left over)
```

Run each file whole (F5). **No second window is needed**: scenario B's open
transaction is held by a background session started through Service Broker
activation (see [rcsi-snapshot-isolation](../rcsi-snapshot-isolation/) for
the technique). That session keeps its transaction open until the demo
releases it.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25.

| step | recovery | log used | `log_reuse_wait_desc` |
|---|---|---|---|
| A1: ~200 MB of activity | FULL | 228.5 MB | **LOG_BACKUP** |
| A2: after `CHECKPOINT` | FULL | **228.5 MB** | LOG_BACKUP |
| A3: after `BACKUP LOG` | FULL | **5.1 MB** | |
| B1: one open transaction, ~200 MB later, after `CHECKPOINT` | SIMPLE | **226.2 MB** | **ACTIVE_TRANSACTION** |
| B2: after that transaction commits, `CHECKPOINT` | SIMPLE | **16.7 MB** | |

### A — FULL recovery, and no log backups

The most common full log of all. In FULL recovery, log records are kept until
a **log backup** has copied them; that's what makes point-in-time restore
possible. A database put in FULL recovery and then only ever given full
backups keeps every log record, and the log grows until the disk is full.

`log_reuse_wait_desc` says so: **`LOG_BACKUP`**. A `CHECKPOINT` frees nothing
(228.5 MB before and after). A log backup frees nearly all of it (5.1 MB).
The fix is a log backup schedule, or SIMPLE recovery if you don't need
point-in-time restore. A full backup doesn't count.

(FULL recovery only behaves like this once a full backup has started the log
chain; before that it truncates like SIMPLE. The demo takes that first backup
to `NUL`. See [minimal-logging](../minimal-logging/).)

### B — one open transaction

SIMPLE recovery truncates the log at every checkpoint, but only up to the
start of the **oldest transaction still open**. A background session opens a
transaction, writes one small row, and sits there. This session then writes
~200 MB of ordinary, committed work. After a checkpoint, **226 MB is still in
use** and the reason is **`ACTIVE_TRANSACTION`**: one idle session pins the
whole log, everybody's work included.

The two questions to ask about any full log:

- **Why?** `sys.databases.log_reuse_wait_desc`
- **Who?** the oldest transaction in `sys.dm_tran_database_transactions`, and
  its session. A user session's transaction is in
  `sys.dm_tran_session_transactions`. A background task's isn't, but its
  running request carries the transaction id, so look in
  `sys.dm_exec_requests` too. The demo found the holder's session both ways.

When the transaction commits, the next checkpoint frees it all (16.7 MB).

On SQL Server 2019 (in CI) the same step held 127 MB rather than 226. That's
less, but still pinned, so the verdict asks for at least half of what was
written.

### C — shrinking a log that is held

| | log file |
|---|---|
| before `DBCC SHRINKFILE`, transaction still open | 256 MB |
| after | **272 MB** |

The reflex with a full log is `DBCC SHRINKFILE`. While the reason it's full
is still there, the active part of the log can't be released and a shrink
gives nothing back. Here the file even grew, because the other work kept
writing. **Fix the reason first.** Afterwards, one shrink still may not be
enough if the active part of the log sits at the end of the file:
`Demo.usp_ShrinkLog` shows the usual loop of checkpoint, shrink, write a
little and repeat.

### D — autogrowth in tiny steps

| one transaction of ~180 MB of rows, in a fresh database | log size | VLFs |
|---|---|---|
| `FILEGROWTH = 1MB` | 518 MB | **517** |
| `FILEGROWTH = 256MB` | 520 MB | **20** |

A log file is divided into **virtual log files** (VLFs), and every growth adds
more. Grown in 1 MB steps, the same log ended up with 26× as many VLFs.
Thousands of VLFs slow down database startup and restore (each one is
examined during recovery) and some log operations. Size the log for its real
peak and grow it in large steps.

The transaction inserted about 180 MB of rows and needed a ~520 MB log, once
logging overhead and the space reserved for a possible rollback are counted.
A long transaction needs far more log than its data suggests.

## The query to run when a log is full

Result set 3 is this, scoped to the demo. Drop the `WHERE` to see every
database:

```sql
SELECT  d.name, d.recovery_model_desc, d.log_reuse_wait_desc,
        OldestTranBegin   = MIN(dt.database_transaction_begin_time),
        OldestTranSession = (SELECT TOP (1) COALESCE(st.session_id, r.session_id)
                             FROM sys.dm_tran_database_transactions AS x
                             LEFT JOIN sys.dm_tran_session_transactions AS st ON st.transaction_id = x.transaction_id
                             LEFT JOIN sys.dm_exec_requests AS r ON r.transaction_id = x.transaction_id
                             WHERE x.database_id = d.database_id AND x.database_transaction_begin_time IS NOT NULL
                             ORDER BY x.database_transaction_begin_time)
FROM    sys.databases AS d
LEFT JOIN sys.dm_tran_database_transactions AS dt
       ON dt.database_id = d.database_id AND dt.database_transaction_begin_time IS NOT NULL
GROUP BY d.database_id, d.name, d.recovery_model_desc, d.log_reuse_wait_desc;
```

Other values you may meet in `log_reuse_wait_desc`: `REPLICATION`
(transactional replication or CDC hasn't read the log yet),
`AVAILABILITY_REPLICA` (a secondary hasn't received or redone it),
`ACTIVE_BACKUP_OR_RESTORE`, and `CHECKPOINT`.

## Traps from building this

- **`log_reuse_wait_desc` reports the last truncation attempt, so it can
  lag.** In the tested run it still said `LOG_BACKUP` after the log backup
  had freed the space, and `ACTIVE_TRANSACTION` after the transaction had
  committed. The used space was the truth. Check both.
- **Free-standing helpers mustn't touch the held row.** The first version of
  the demo's log generator deleted every row in the table the background
  session was holding a lock on, and waited for it while it waited to be
  released. It now writes to a table of its own.

## How to read the output

`02-demo.sql` prints four result sets:

1. the log at every step: size, used, reuse wait, VLFs
2. the verdicts
3. the diagnostic query above
4. **anything that didn't behave as predicted, which should be empty**

## Takeaways

1. **Ask why first: `log_reuse_wait_desc`.** It names the reason, and the
   fix follows from it.
2. **`LOG_BACKUP`: FULL recovery needs log backups.** A `CHECKPOINT` or a full
   backup frees nothing; a log backup freed 223 of 228 MB.
3. **`ACTIVE_TRANSACTION`: one idle session can pin the whole log.** Find the
   oldest transaction and its session.
4. **Don't shrink a log that's still held.** It gave nothing back, and the
   file grew.
5. **Grow the log in large steps.** 1 MB growth made 517 VLFs, 256 MB made 20.
6. **A big transaction needs far more log than its data**: about 520 MB for
   180 MB of rows.

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
