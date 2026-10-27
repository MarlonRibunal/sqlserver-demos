# ZSTD backup compression in SQL Server 2025: smaller, often faster, and one trap

> **The short version:** [ZSTD backup compression (SQL Server 2025)](https://marlonribunal.com/sqlserver-demos/zstd-backup-compression/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

Until 2025, `WITH COMPRESSION` meant one algorithm, MS_XPRESS. SQL Server
2025 adds **ZSTD**, with three levels: `COMPRESSION (ALGORITHM = ZSTD, LEVEL
= LOW | MEDIUM | HIGH)`. This topic backs up the same 170 MB database every
way, three times each, and measures size and time. It also tries data that
doesn't compress, a backup file that already holds an MS_XPRESS backup, and
a restore.

## The rule these scenarios are built around

**ZSTD LOW is a straight upgrade on MS_XPRESS: smaller and no slower.
MEDIUM and HIGH trade time for size. No algorithm compresses encrypted or
already-compressed data. And to switch an existing backup file to ZSTD,
`WITH INIT` isn't enough: use `WITH FORMAT`, or a new file.**

## Prerequisites

- **SQL Server 2025 or later.** Developed and tested on **2025 RTM-CU9-GDR
  (17.0.5015.4)**, Linux container. On 2022 and earlier the scripts still
  run, and the demo reports every scenario as `SKIPPED`.
- No sample database. `01-setup.sql` creates two of its own.
- Permission to `CREATE DATABASE`, `BACKUP DATABASE` and `RESTORE`, and about
  500 MB free in the default backup folder.

## What setup and the demo change on your instance

- setup creates **`ZstdDemo`** (1,000,000 rows of repetitive text and numbers,
  about 170 MB) and **`ZstdDemoRandom`** (100,000 rows of random bytes, about
  45 MB)
- the demo writes **backup files named `ZstdDemo_*.bak`** to the instance's
  default backup folder (`SERVERPROPERTY('InstanceDefaultBackupPath')`),
  overwriting them on every run
- scenario E restores one as **`ZstdDemo_Copy`** and drops it again

`03-cleanup.sql` deletes each backup file by name (nothing else in the folder
is touched), drops the databases and their msdb backup history, and confirms
that all of it is gone.

## Run order

```
01-setup.sql     ~15 s     creates ZstdDemo and ZstdDemoRandom
02-demo.sql      ~10 s     about 20 backups and one restore
03-cleanup.sql   seconds   deletes the files, drops the databases and history
```

Run each file whole (F5).

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2025 RTM-CU9-GDR, a
Linux container under x86 emulation on an ARM laptop. Absolute times will be
very different on a real server; the comparisons are the point.

### A and B — size and time

`ZstdDemo`, 168 MB uncompressed. Each backup ran three times; the time is the
best of three:

| | size | time |
|---|---|---|
| `NO_COMPRESSION` | 168.1 MB | 82 ms |
| `COMPRESSION` (MS_XPRESS) | 17.3 MB | 122 ms |
| ZSTD `LOW` | **13.8 MB** | **83 ms** |
| ZSTD `MEDIUM` | 11.5 MB | 90 ms |
| ZSTD `HIGH` | **10.9 MB** | **281 ms** |

**Every ZSTD level was smaller than MS_XPRESS**, and on this container LOW
was faster too: 20% smaller in a third less time. MEDIUM was a further 17% smaller for little more
time. HIGH saved another 5% and took more than three times as long as LOW.

**The times depend on the hardware; the sizes don't.** The table comes from
the test container, which runs x64 SQL Server under emulation on an ARM
Mac, so compression is expensive there. On GitHub's native x64 CI runners
the same demo measured LOW 432 ms and HIGH 427 ms: the same time. The demo
reports times as `INFO` and makes no claim about them.

The backup-to-disk times here are tiny because the files land on the same
fast disk. On a real server, writing less to the network or a backup
appliance is often what takes the time, and a smaller backup is a faster one.

### C — data that doesn't compress

`ZstdDemoRandom`, random bytes, which is what encrypted (TDE) or
already-compressed data looks like to a compressor:

| | size |
|---|---|
| no compression | 46.1 MB |
| MS_XPRESS | 40.6 MB (88%) |
| ZSTD `HIGH` | 40.2 MB (87%) |

The 12% saved is page headers and row overhead, not the data. **No
algorithm or level compresses random data**, so HIGH spends its CPU for
nothing there.

### D — a file that holds an MS_XPRESS backup

| | result |
|---|---|
| a ZSTD backup to the same file `WITH INIT` | **fails**: error 3098, then 3013 |
| the same `WITH INIT, FORMAT` | ran |

Error 3098: "The backup cannot be performed because 'ZSTD' was requested
after the media was formatted with an incompatible structure." `WITH INIT`
overwrites the backup sets but keeps the media header, and the header
records the algorithm. **A job that backs up to a fixed file name with `WITH
INIT` fails the first night after it's switched to ZSTD.** Use `WITH
FORMAT`, or new file names.

(A `CATCH` block sees only the last of the two errors, 3013, "BACKUP
DATABASE is terminating abnormally". The demo checks for that; the reason is
in 3098.)

### E — restoring a ZSTD backup

`RESTORE DATABASE ... FROM DISK` with nothing about the algorithm restored
the ZSTD HIGH backup as `ZstdDemo_Copy`: 1,000,000 rows of 1,000,000.
Restore reads the algorithm from the file.

This demo runs on one instance, so it can't show the other side: a ZSTD
backup needs a SQL Server that knows ZSTD to restore it. Check before using
ZSTD for backups that might be restored on an older version.

## How to read the output

`02-demo.sql` prints three result sets:

1. every measurement
2. the verdicts, each with its evidence
3. **anything that didn't behave as predicted, which should be empty**
   on 2025 (on 2022 and earlier, the `SKIPPED` rows)

## Traps from building this

- **The first timing run measured failures.** It backed up to one file with
  each algorithm in turn, `WITH INIT`. Every ZSTD backup after the first
  MS_XPRESS one failed with error 3098, quickly. That's how scenario D was
  found. Each backup now uses `WITH FORMAT`.
- **`TRY`/`CATCH` hides the reason a backup failed.** See D.

## Takeaways

1. **ZSTD LOW beat MS_XPRESS on size**: 13.8 MB against 17.3 MB;
   on the test container on time as well, 83 ms
   against 122 ms.
2. **MEDIUM is the middle ground**; HIGH saved 5% more than MEDIUM. Whether
   it costs time depends on the hardware: three times as long as LOW on the
   test container, the same on native x64.
3. **Nothing compresses random, encrypted or already-compressed data.**
4. **Switching a fixed backup file to ZSTD needs `WITH FORMAT`**, or the next
   backup fails with error 3098.
5. **Restore needs no option**, but it needs a version that knows ZSTD.

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
