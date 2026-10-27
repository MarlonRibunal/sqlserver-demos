# Wait stats triage: where the time went

> **The short version:** [Wait stats triage](https://marlonribunal.com/sqlserver-demos/wait-stats-triage/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

When a query is slow, wait statistics say what it was waiting *for*: a
lock, the log, the disk, a CPU. This topic makes each kind of wait happen
on purpose and measures it in the session that waited. It also shows where
the numbers mislead: background sessions that record nothing, a platform
that reports the log flush under a different name, storage too fast to
wait for, and an instance-wide top 10 that is all noise.

## The rule these scenarios are built around

**Start from one request's time: elapsed = CPU + waits. Measure waits per
session (`sys.dm_exec_session_wait_stats`) or live
(`sys.dm_os_waiting_tasks`), as before/after differences. Read the
instance-wide `sys.dm_os_wait_stats` only through a filter, and never
assume a wait you didn't see means time you didn't spend.**

## Prerequisites

- SQL Server 2017 or later (`STRING_AGG`). Developed and tested on **2022
  CU25 (16.0.4255.1)**, Linux container. CI also runs it on 2019 and 2025.
- No sample database. `01-setup.sql` creates its own database, `WaitDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` to read the wait
  DMVs.

## What setup and the demo change on your instance

Setup creates `WaitDemo` with Service Broker enabled (scenario A's
background session) and nothing else. **The instance's wait statistics
are never cleared.** The demo only reads them and works from differences.

The demo changes `WaitDemo` only, and its header says so:

- scenario A turns `READ_COMMITTED_SNAPSHOT` on, then off
- scenario B sets `DELAYED_DURABILITY = FORCED`, then back to `DISABLED`
- scenario C takes `WaitDemo` `OFFLINE` and back `ONLINE`, twice, to empty
  the cache of its pages without `DBCC DROPCLEANBUFFERS`, which would
  empty the whole instance's. Anyone else connected to `WaitDemo` is
  disconnected.

`03-cleanup.sql` drops the database and confirms that none of its files
remain.

## Run order

```
01-setup.sql     ~15 s     creates WaitDemo: a 100 MB table and the harness
02-demo.sql      ~30 s     five scenarios; prints a summary
03-cleanup.sql   seconds   drops WaitDemo
```

Run each file whole (F5).

## How it measures

Each measurement runs a piece of T-SQL in the demo's own session and
records:

- **elapsed time and CPU time**, from `sys.dm_exec_requests`
- **every wait the session added**, from `sys.dm_exec_session_wait_stats`,
  before and after
- **physical reads from `WaitDemo`'s files**, from
  `sys.dm_io_virtual_file_stats`

Then it checks the identity. A serial request's elapsed time is its CPU
time plus its waits. Signal waits, the time it was ready but waiting for a
CPU, count as waits.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25.

### A — a blocked reader: `LCK_M_S`

The demo holds an update lock on one row for 2 seconds while a background
session reads it, and watches `sys.dm_os_waiting_tasks`:

| | returned |
|---|---|
| the reader's wait | `LCK_M_S`, blocked by the demo's session id, resource `keylock hobtid=... mode=X` |
| the reader's read took | 2,097 ms; longest `wait_duration_ms` seen, 2,092 |
| the reader's own `sys.dm_exec_session_wait_stats`, `LCK_M_%` | **0 ms** |
| with `READ_COMMITTED_SNAPSHOT` on | read took 0 ms; never seen waiting |

`sys.dm_os_waiting_tasks` shows a wait while it happens: the type, how
long so far, the blocker, and the exact resource. The blocked session here
was a Service Broker activation task, and its own session wait stats
recorded **no** lock wait at all, though it waited 2 seconds. Don't treat a
missing wait in the per-session DMV as proof that nothing waited.
(The [blocking chains](../blocking-chains/) topic follows a chain back to
its head; [RCSI](../rcsi-snapshot-isolation/) covers what row versioning
costs.)

### B — commits: `WRITELOG`, or what this platform calls it

2,000 single-row inserts:

| | elapsed | CPU | `WRITELOG` | `PREEMPTIVE_OS_FLUSHFILEBUFFERS` |
|---|---|---|---|---|
| each its own transaction | **1,291 ms** | 1,167 ms | 2,002 waits, **66 ms** | 2,002 waits, **1,107 ms** |
| all in one transaction | 16 ms | 18 ms | 3 waits | 3 waits |
| each its own, `DELAYED_DURABILITY = FORCED` | 23 ms | 24 ms | 0 | 0 |

Every commit waits until its log records are on disk: one `WRITELOG` per
commit. On the tested build (Linux), the time went to
**`PREEMPTIVE_OS_FLUSHFILEBUFFERS`**, the call that flushes the log file,
and `WRITELOG` showed only 66 ms. A triage script that looks only for
`WRITELOG` would call this workload fine. Batching the inserts into one
transaction did one flush instead of 2,000. Delayed durability doesn't
wait for the flush at all: the commit returns first, so a crash can lose
the most recent ones it reported as committed.

Preemptive waits are time the thread spends in an operating system call.
On the tested build the CPU counter included that time too (1,167 ms of CPU
for 1,291 ms elapsed). So the demo counts them once: elapsed must fall
between CPU + the other waits and CPU + all waits.

### C — reading from disk: `PAGEIOLATCH_SH`, or nothing

The cache of `WaitDemo`'s pages was emptied before each cold run (205
pages were left; the table is about 13,000).

| | physical reads | read stall | `PAGEIOLATCH` waits | elapsed |
|---|---|---|---|---|
| scan of `Demo.Big` (100 MB), cold | 196 | 24 ms | **0** | 102 ms |
| 2,000 scattered single-row lookups, cold | 1,496 | 27 ms | **0** | 51 ms |
| the same lookups, warm | 0 | 0 | 0 | 6 ms |

`PAGEIOLATCH_SH` means a session needed a page that was still being read
from disk. Here the pages really were read from disk, 1,692 reads, but
no session ever waited: 51 ms of read stall in all, and each read finished
before the page was needed. The container's files were most likely served
from the host's memory. (The scan's 196 reads covered about 13,000 pages:
read-ahead reads many pages at a time. On 2019, in CI, it took only 30.) Slower storage would be expected to
show these reads as `PAGEIOLATCH` waits, but that wasn't measured here. On
storage this fast, disk reads didn't appear in wait stats at all. Look at
`sys.dm_io_virtual_file_stats` and logical reads, not only at waits.

### D — busy, not waiting: `SOS_SCHEDULER_YIELD`

Hashing every row five times, from memory:

| elapsed | CPU | `SOS_SCHEDULER_YIELD` |
|---|---|---|
| 6,242 ms | **6,243 ms** | 1,568 times, **4 ms** |

A running query gives up its scheduler about every 4 ms, so a CPU-bound
query racks up `SOS_SCHEDULER_YIELD` *counts*. On an idle machine it gets
the CPU straight back, and the wait *time* is tiny. Its time is CPU. A large
`SOS_SCHEDULER_YIELD` time, or a high signal-wait share overall, means
queries are queuing for CPU.

### E — the instance-wide view

`sys.dm_os_wait_stats` since the instance started, top 10 by wait time:

| raw top 10 | |
|---|---|
| all **10** on the filter list | `SOS_WORK_DISPATCHER`, `DISPATCHER_QUEUE_SEMAPHORE`, `SLEEP_TASK`, `LOGMGR_QUEUE`, `XE_TIMER_EVENT`, … |

These are background tasks waiting for work. Their wait time grows whether
the server is busy or idle. The demo prints the raw top 10, then the top 10
without them, with average wait and signal-wait share. The filter list is
in `02-demo.sql`. It's a starting point, not a complete list. The filtered
numbers are still totals since startup, for every database. To see what
happened during an incident, take two snapshots and subtract, as every
scenario above does. `DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR)` resets
them for the whole instance, and everyone else's baseline with it.

## Traps from building this

- **A background session's waits weren't in its session wait stats** (A).
- **The commit wait was named for the OS call, not `WRITELOG`** (B), and
  CPU time included it.
- **Cold reads produced no `PAGEIOLATCH` waits** (C). The first version
  expected them and failed.
- **Taking the database `OFFLINE` empties its pages from the cache.** That
  gives a cold cache for one database without flushing the whole
  instance's.

## How to read the output

`02-demo.sql` prints:

- E1 and E2: the instance-wide top 10, raw and filtered
- **1. where the time went**: every measured run's elapsed, CPU, waits,
  physical reads, and its top 3 waits
- **2. the verdicts**, with evidence, including the identity check for every run
- **3. anything that didn't behave as predicted, which should be empty**

## Takeaways

1. **Elapsed = CPU + waits.** Do that sum before reading wait names.
2. **Measure per session, as differences.** The instance-wide totals are
   mostly idle background tasks.
3. **Watch it live with `sys.dm_os_waiting_tasks`**: the wait, the blocker,
   the resource.
4. **A wait you didn't see isn't time you didn't spend.** Background
   sessions, OS calls, and fast storage all hid time here.
5. **Many single-row commits cost a log flush each.** Batch them.

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
