# Backup and restore: the restores you'll need, practised

Everyone takes backups; few people practise the restores. This topic runs
four of them for real against a demo database and counts what came back:
point in time after an accidental `DELETE`, the tail of the log, the
differential that won't restore, and compressed, checksummed backups.

## The rule these scenarios are built around

**A backup is only as good as the restore you've practised. Restore to a
copy, not over production; take a tail-log backup before restoring over a
damaged database; use `COPY_ONLY` for every backup outside the schedule;
and back up `WITH CHECKSUM`.**

## Prerequisites

- SQL Server 2019 or later (`SERVERPROPERTY('InstanceDefaultBackupPath')`
  finds the backup folder). Developed and tested on **2022 CU25
  (16.0.4255.1)**, Linux container. Scenario D needs backup compression,
  which Express edition doesn't have; it reports `SKIPPED` there.
- No sample database. `01-setup.sql` creates its own database, `BackupDemo`.
- Permission to `CREATE DATABASE`, `BACKUP` and `RESTORE`, and to run
  `xp_fileexist` and `xp_delete_file` (sysadmin) for the cleanup.
- About 200 MB of free disk in the default backup folder.

## What setup and the demo change on your instance

Setup creates `BackupDemo` (FULL recovery) and nothing else: no instance
setting (not `backup compression default`, not `backup checksum default`),
no compatibility level, no trace flag.

**The demo goes further, and says so at the top of `02-demo.sql`:**

- it writes **backup files** into this instance's default backup folder
  (`SERVERPROPERTY('InstanceDefaultBackupPath')`), all named
  `BackupDemo_*.bak`, overwriting them on every run
- it restores them as a **second database**, `BackupDemo_Copy`
- scenario B takes a tail-log backup `WITH NORECOVERY`, which puts
  `BackupDemo` into `RESTORING` for a moment, then brings it back online
- every backup and restore adds **history rows to `msdb`**

`03-cleanup.sql` removes all of it: the 14 backup files **one by one, by
name** (`xp_delete_file` on each, so nothing else in the folder is touched),
both databases, and their msdb history (`sp_delete_database_backuphistory`).
Then it confirms each is gone.

## Run order

```
01-setup.sql     seconds   creates BackupDemo: 100,000 orders
02-demo.sql      ~10 s     four scenarios; prints a summary
03-cleanup.sql   seconds   deletes the backup files, both databases, the msdb history
```

Run each file whole (F5).

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25.

### A — someone ran `DELETE` without a `WHERE`

| | rows |
|---|---|
| `Demo.Orders` before the accident | 102,000 |
| after `DELETE Demo.Orders` | **0** |
| 500 new orders arrive afterwards; then a log backup | 500 |
| a **copy** restored `WITH STOPAT` the moment before the `DELETE` | **102,000** (none of the 500 later ones) |
| `Demo.Orders` after copying the missing rows back | **102,500** |

Restoring the database itself to before the accident would bring the
102,000 rows back and **throw away the 500 orders taken since**. Restore a
copy to the moment before, and copy back what's missing (keeping the
original IDs with `IDENTITY_INSERT`). Nothing is lost.

```sql
RESTORE DATABASE BackupDemo_Copy FROM DISK = '...a_full.bak' WITH NORECOVERY, MOVE ..., MOVE ...;
RESTORE LOG      BackupDemo_Copy FROM DISK = '...a_log1.bak' WITH NORECOVERY;
RESTORE LOG      BackupDemo_Copy FROM DISK = '...a_log2.bak' WITH RECOVERY, STOPAT = @before;
```

Point in time needs FULL recovery and an unbroken chain of log backups from
a full backup up to the moment you want.

### B — the tail of the log

| | rows |
|---|---|
| `BackupDemo`, with 300 orders taken since the last log backup | 102,800 |
| restored from the backups there were | **102,500**, 300 short |
| restored from the same backups **plus a tail-log backup** | **102,800** |

The work since the last log backup is still in the database's log. Before
restoring over a damaged database, back that up:

```sql
BACKUP LOG BackupDemo TO DISK = '...b_tail.bak' WITH NORECOVERY;
```

`NORECOVERY` leaves the database `RESTORING` (the demo checked), so nothing
can change after the backup. If the data files themselves are damaged, the
documentation's answer is to add `NO_TRUNCATE`; the demo doesn't damage any
files to show that. The demo brings
`BackupDemo` straight back online and restores the chain as a copy. In a
real recovery you'd restore it over the damaged database.

### C — the ad hoc full backup

| sequence | restore scheduled full + differential |
|---|---|
| scheduled full → **ad hoc full** → differential | **fails**: Msg 3136, *"This differential backup cannot be restored because the database has not been restored to the correct earlier state."* |
| scheduled full → **ad hoc full `COPY_ONLY`** → differential | works, every row |

A differential backup holds every page changed since the most recent full
backup, *any* full backup. Someone's "just a quick copy before the
release" becomes the base of every differential after it. If that copy has
since been deleted, the differentials are useless until the next full.
msdb shows what happened, in `backupset.differential_base_guid`:

| file | type | differential base |
|---|---|---|
| `c_full` | full | |
| `c_adhoc` | full | |
| `c_diff` | differential | **`c_adhoc`** |
| `c2_full` | full | |
| `c2_adhoc` | full, copy-only | |
| `c2_diff` | differential | `c2_full` |

`COPY_ONLY` takes a full backup without making it the new base, and a log
backup without breaking the log chain. Use it for every backup outside the
schedule.

### D — compression and checksums

| full backup | size | time |
|---|---|---|
| uncompressed | 53 MB | 73 ms |
| `WITH COMPRESSION` | **1.7 MB** | 61 ms |

This table is mostly padding, which is why the ratio is so extreme. Real
data compresses less. The compressed backup was also slightly faster here,
since there was less to write.

Every backup in the demo is taken `WITH CHECKSUM`: page checksums are
verified as pages are read, and the backup gets a checksum of its own.
`msdb` records `has_backup_checksums = 1`, and `RESTORE VERIFYONLY ... WITH
CHECKSUM` read the whole compressed backup back cleanly. That proves the file
is readable. Only a restore, like A–C's, proves the database comes back.

## Traps from building this

- **`STOPAT` a few milliseconds after a commit lost that commit.** The first
  version captured the stop time right after the last good insert, and the
  copy came back without those 1,000 rows. Leave a margin, or stop at a log
  mark or LSN (`STOPBEFOREMARK`).
- **`TRY...CATCH` shows the wrapper, not the cause.** A failed `RESTORE`
  raises the real error (3136 here) and then 3013, *"RESTORE DATABASE is
  terminating abnormally"*. `ERROR_NUMBER()` in the `CATCH` block saw only
  3013.
- **Backups leave history in msdb.** Restores do too. Cleanup removes it
  with `sp_delete_database_backuphistory`.

## How to read the output

`02-demo.sql` prints three result sets:

1. every measurement: row counts, restore errors, the msdb chain, sizes
2. the verdicts
3. **anything that didn't behave as predicted, which should be empty**

## Takeaways

1. **Restore to a copy and copy back.** The deleted 102,000 rows returned,
   and the 500 later orders were kept.
2. **Take a tail-log backup before restoring over a damaged database.**
   Without it, 300 orders were gone.
3. **`COPY_ONLY` for every backup outside the schedule.** One ad hoc full
   made the next differential unrestorable.
4. **Back up `WITH CHECKSUM`, and verify**, but count only a real restore as
   proof.

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
