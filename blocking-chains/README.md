# Blocking chains: finding the head, and why the DMVs blame the wrong session

> **The short version:** [Blocking chains](https://marlonribunal.com/sqlserver-demos/blocking-chains/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

"The database is slow" is very often one session holding a lock and doing
nothing, with a queue of sessions behind it, and more behind those. This topic
builds a real chain with four background sessions, finds its head the way you
would in production, watches it drain, and adds the two neighbours of
blocking: lock timeouts and deadlocks.

## The rule these scenarios are built around

**Follow `blocking_session_id` back to the session that blocks but isn't
blocked. That's the head, and nothing further down the chain is worth
killing. Expect a waiting request to be reported blocked by the request
queued ahead of it, not only by the lock holder.**

## Prerequisites

- SQL Server 2016 or later. Developed and tested on **2022 CU25
  (16.0.4255.1)**, Linux container.
- No sample database. `01-setup.sql` creates its own database, `BlockingDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` for the DMVs.

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no instance setting, not even `blocked process threshold`
- no existing database touched

Inside `BlockingDemo`, setup turns on Service Broker. `03-cleanup.sql` drops
the database and confirms that none of its files remain.

## Run order

```
01-setup.sql     seconds   creates BlockingDemo, four worker queues
02-demo.sql      ~15 s     five scenarios; prints a summary
03-cleanup.sql   seconds   drops BlockingDemo
```

Run each file whole (F5). **No second window is needed.**

## How it's built: four background sessions from one script

A chain needs several sessions at once. As in the
[RCSI topic](../rcsi-snapshot-isolation/), Service Broker **activation**
provides them: a message on a queue starts a procedure in a background
session. One queue only adds readers gradually, so each worker has its own
queue (Q1–Q4) and starts the moment it's sent a command. Each worker logs what
it did, and the demo reads that log `WITH (NOLOCK)` so it can see events still
inside a worker's open transaction.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25.

### A — a blocking chain

| worker | does | blocked by | wait type |
|---|---|---|---|
| Q1 `HEAD` | takes item 1, then sits for 6 s with the transaction open | — | `WAITFOR` |
| Q2 `B1` | takes item 2, then asks for item 1 | **HEAD** | `LCK_M_X` |
| Q3 `B2` | reads item 1 | **B1** ⚠ | `LCK_M_S` |
| Q4 `B3` | reads item 2 | **B1** | `LCK_M_S` |

`B3` never touched item 1 and has nothing to do with HEAD. It's stuck anyway,
because B1 holds item 2 while it waits. That's what makes a chain: sessions
blocked by sessions that are themselves blocked.

**`B2` is the surprise.** It wants item 1, which HEAD holds, and the DMVs
report it blocked by **B1**, which doesn't hold item 1 at all. B1's exclusive
request for item 1 is already queued, and lock requests are granted in order.
B2's shared request waits *behind B1's request*, not merely behind HEAD's
lock. `blocking_session_id` names the request ahead of you in the queue. So
"session X is blocking me" doesn't always mean "session X holds the lock I
want", and it's why you follow the chain to its head instead of acting on the
first link.

### B — finding the head

The head blocks someone and is blocked by no one. Starting from **sessions**
rather than requests matters, because a typical real-world head is an
application that began a transaction and went quiet. It shows in
`sys.dm_exec_sessions` with an open transaction and has **no row in
`sys.dm_exec_requests`** at all.

```sql
WITH links AS
(
    SELECT s.session_id, BlockedBy = ISNULL(r.blocking_session_id, 0)
    FROM   sys.dm_exec_sessions AS s
    LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = s.session_id
),
heads AS
(
    SELECT l.session_id FROM links AS l
    WHERE  l.BlockedBy = 0
      AND  EXISTS (SELECT 1 FROM links AS x WHERE x.BlockedBy = l.session_id)
),
chain AS
(
    SELECT session_id, Depth = 1 FROM heads
    UNION ALL
    SELECT l.session_id, c.Depth + 1 FROM links AS l JOIN chain AS c ON l.BlockedBy = c.session_id
)
SELECT * FROM chain ORDER BY Depth;
```

Against the demo it found exactly one head, the HEAD worker, with three
sessions behind it at depths 2 and 3. The demo's own head is an activation
procedure inside `WAITFOR`, so it does have a request, but it's waiting on
nothing but time, which is the point.

### C — draining

| | finished |
|---|---|
| HEAD commits | first |
| B1 | right after |
| B2, B3 | right after B1 |

B3 had waited **almost 6 seconds** for a row that nobody was using: the whole
time, it was queued behind a session queued behind a session that was doing
nothing.

### D — LOCK_TIMEOUT

| | result |
|---|---|
| `SET LOCK_TIMEOUT 1000`, then read a row HEAD holds | **Msg 1222 after 1,003 ms** |

By default a blocked request waits forever. `SET LOCK_TIMEOUT` bounds the
wait, and the statement fails with 1222 so the caller can decide what to do.
It's session-level, so it suits a request that would rather fail fast than
join the queue.

### E — a deadlock

| | result |
|---|---|
| `DL_A` takes item 3, then wants 4; `DL_B` takes 4, then wants 3 | **one victim, Msg 1205; the other committed** |
| time to resolve | **about 5 seconds** |

A chain that loops back on itself never drains on its own. The deadlock
monitor finds the cycle (it checks every few seconds, hence the ~5 s), picks a
victim and rolls it back with 1205. Unlike a blocking chain, a deadlock
resolves itself by failing a transaction, which the application has to be
ready to retry.

## How to read the output

`02-demo.sql` prints four result sets:

1. the chain as the DMVs saw it: depth, head flag, blocked-by, wait type
2. every worker's log
3. the verdicts
4. **anything that didn't behave as predicted, which should be empty**

## Takeaways

1. **One idle session can hold up a chain of others.** Three sessions waited
   about 6 seconds behind one that was doing nothing.
2. **Find the head: blocks someone, blocked by no one.** Start from sessions,
   not requests, or you'll miss the head that has no request.
3. **`blocking_session_id` names the request ahead in the queue, not always
   the lock holder.** B2 was "blocked by" B1, which never held the row.
4. **`SET LOCK_TIMEOUT` turns an endless wait into Msg 1222.**
5. **A deadlock is a chain that loops.** The engine breaks it within seconds
   with Msg 1205. Retry the victim.

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
