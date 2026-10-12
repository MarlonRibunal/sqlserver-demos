# SQL Server demo scripts

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Self-contained, runnable demonstrations of SQL Server behaviour — one folder per
topic. Each folder has its own README with prerequisites, run order, and what to
expect in the output.

## Start from the symptom

You probably arrived with a problem, not a feature name. Find it below; each
link is a topic that reproduces that problem on purpose and measures the
fixes.

**"It's fast sometimes and slow other times"**
- the plan was compiled for somebody else's parameter → [parameter sniffing](parameter-sniffing/)
- only for the newest data → [the ascending-key problem](ascending-key/)
- "slow in the app, fast in SSMS" → [SET options and the plan cache](slow-in-app-fast-in-ssms/)
- a search screen with optional filters → [catch-all queries](catch-all-queries/)
- it was fine yesterday and nothing was deployed → [Query Store: plan regressions](query-store-regression/)

**"This query reads far more than it should"**
- a function or expression on the column → [non-SARGable predicates](non-sargable-predicates/)
- the parameter's type doesn't match the column → [implicit conversions](implicit-conversion/)
- thousands of key lookups, or a scan where you expected a seek → [the tipping point](tipping-point/)
- a scalar function in the query → [scalar UDF inlining](scalar-udf-inlining/)
- a date-partitioned table and the query reads every partition → [partition elimination](partition-elimination/)
- a heap that keeps getting slower to scan → [forwarded records](heap-forwarded-records/)
- a columnstore table that isn't as fast or small as it should be → [the delta store](columnstore-delta-store/)

**"The estimates in the plan are nowhere near the actual rows"**
- rows newer than the statistics → [ascending key](ascending-key/)
- two related columns in one `WHERE` → [correlated predicates](correlated-predicates/)
- skewed data, rare values, values that don't exist → [statistics sampling](statistics-sampling/)
- a `#temp` table vs a table variable → [tempdb](tempdb/)
- a multi-statement function estimated at 1 or 100 rows, a table variable estimated at 1 → [MSTVFs and table variables](mstvf-table-variables/)

**"The totals are off by a cent" / "the report is missing a day" / "the dates are swapped"**
- integer division, float, decimal and money rounding, strings cut short, datetime ranges, date formats, trailing spaces, identity overflow → [data type traps](data-type-traps/)

**"The server is slow and I don't know where to start" / "what are we waiting on?"**
- elapsed = CPU + waits, per-session and live waits, `WRITELOG`, `PAGEIOLATCH`, `LCK_M_*`, `SOS_SCHEDULER_YIELD`, and the instance-wide numbers' noise → [wait stats triage](wait-stats-triage/)

**"Queries wait for memory" (`RESOURCE_SEMAPHORE`)**
- grants far bigger than the data → [memory grants sized by declared width](memory-grant-declared-width/)

**"`CXPACKET` is my top wait" / "small queries eat all the CPU"**
- a parallel query no faster than serial, skew, the cost threshold, why a plan stays serial → [parallelism](parallelism/)

**"Everything is blocked" / "we get deadlocks"**
- find the session holding everyone up → [blocking chains](blocking-chains/)
- `Msg 1205`, "chosen as the deadlock victim" → [deadlock patterns](deadlock-patterns/)
- a big update locks the whole table → [lock escalation](lock-escalation/)
- readers wait for writers, or `NOLOCK` everywhere → [RCSI and snapshot isolation](rcsi-snapshot-isolation/)

**"Duplicate rows" / "primary key violations under load" / "the counter is wrong"**
- two sessions insert the same new row, or overwrite each other's update → [upsert race conditions](upsert-race-conditions/)

**"Page 500 of the results takes forever" / "users see the same row on two pages"**
- `OFFSET ... FETCH` on deep pages, rows repeated or lost between pages, ties in the sort, the total count → [pagination: OFFSET vs keyset](pagination/)

**"The database is too big" / "should we turn on compression?"**
- ROW vs PAGE vs columnstore, the CPU it costs, data that won't compress, heaps, big documents → [data compression](data-compression/)

**"Should I rebuild / add this index?"**
- the maintenance job says the index is fragmented → [index fragmentation](index-fragmentation/)
- the missing-index DMVs suggest something → [missing-index suggestions](missing-index-suggestions/)

**"The rollback is taking forever" / "recovery after a restart takes hours"**
- instant rollback, a log that truncates under long transactions, and the version store it costs → [Accelerated Database Recovery](accelerated-database-recovery/)

**"A tenant can see (or write) another tenant's rows" / "the admin report comes back empty"**
- writes past the filter, a spoofable `SESSION_CONTEXT`, leaks through unique keys and identities, the predicate that scans → [row-level security](row-level-security/)

**"Someone deleted the wrong rows" / "will our backups actually restore?"**
- point-in-time restore to a copy, the tail-log backup, `COPY_ONLY` and broken differentials, checksums → [backup and restore](backup-restore/)

**"The transaction log is full" / "the log file won't stop growing"**
- no log backups, an open transaction, a shrink that won't shrink, thousands of VLFs → [why is my transaction log full?](transaction-log-full/)

**"The load is slow and the log is huge"**
- bulk inserts that should be minimally logged → [minimal logging](minimal-logging/)
- tempdb contention, or when to use a `#temp` table → [tempdb](tempdb/)

## Topics

| Topic | Sample database | Min. version |
|---|---|---|
| [Parameter sniffing, `RECOMPILE`, memory grant feedback](parameter-sniffing/) | WideWorldImporters | 2017 (2022+ for all six scenarios) |
| [tempdb: when to reach for a `#temp` table](tempdb/) | none — creates its own | 2016 |
| [Index fragmentation: what it costs, and what it doesn't](index-fragmentation/) | none — creates its own | 2016 |
| [The ascending-key problem: estimates for rows statistics haven't seen](ascending-key/) | none — creates its own | 2016 SP2 |
| [Implicit conversions: when a type mismatch costs a scan](implicit-conversion/) | none — creates its own | 2016 |
| [Non-SARGable predicates: which functions on a column cost a seek](non-sargable-predicates/) | none — creates its own | 2016 |
| [Lock escalation: the threshold, and what does and doesn't avoid it](lock-escalation/) | none — creates its own | 2016 |
| [Heaps: forwarded records, and the pages a heap keeps](heap-forwarded-records/) | none — creates its own | 2016 |
| [Key lookups and the tipping point](tipping-point/) | none — creates its own | 2016 |
| [Scalar UDF inlining: what SQL Server 2019 changed, and what it didn't](scalar-udf-inlining/) | none — creates its own | 2019 |
| [Columnstore: the delta store, and the rowgroups a query can skip](columnstore-delta-store/) | none — creates its own | 2016 SP1 |
| [Missing-index suggestions: what the DMVs ask for, and what to build instead](missing-index-suggestions/) | none — creates its own | 2016 |
| ["Slow in the app, fast in SSMS": SET options and the plan cache](slow-in-app-fast-in-ssms/) | none — creates its own | 2016 |
| [Minimal logging: when bulk inserts really are cheap](minimal-logging/) | none — creates its own | 2016 |
| [Correlated predicates: when two columns aren't independent](correlated-predicates/) | none — creates its own | 2016 SP1 |
| [Memory grants sized by declared width](memory-grant-declared-width/) | none — creates its own | 2016 (2019+ for C, 2022 for D) |
| [Catch-all queries: optional parameters, five ways](catch-all-queries/) | none — creates its own | 2016 |
| [Partition elimination traps](partition-elimination/) | none — creates its own | 2016 SP1 |
| [Statistics sampling and skew](statistics-sampling/) | none — creates its own | 2016 SP1 CU4 |
| [RCSI and snapshot isolation: readers, writers, and the version store](rcsi-snapshot-isolation/) | none — creates its own | 2016 |
| [Blocking chains: finding the head](blocking-chains/) | none — creates its own | 2016 |
| ["Why is my transaction log full?"](transaction-log-full/) | none — creates its own | 2016 SP2 |
| [Query Store: catching a plan regression, forcing the fix, and watching it break](query-store-regression/) | none — creates its own | 2016 (2022 for E) |
| [Upsert race conditions: IF EXISTS, MERGE, and the locks that make them safe](upsert-race-conditions/) | none — creates its own | 2016 SP1 |
| [Deadlock patterns: making them on cue, fixing them, and reading the graphs](deadlock-patterns/) | none — creates its own | 2017 |
| [Parallelism: what it buys, what it costs, and when it goes wrong](parallelism/) | none — creates its own | 2019 |
| [Pagination: OFFSET vs keyset](pagination/) | none — creates its own | 2017 |
| [Data compression: ROW, PAGE, columnstore, and COMPRESS()](data-compression/) | none — creates its own | 2016 SP1 |
| [Accelerated Database Recovery: instant rollback, and what it costs](accelerated-database-recovery/) | none — creates its own | 2019 |
| [Backup and restore: the restores you'll need, practised](backup-restore/) | none — creates its own | 2019 |
| [Data type traps: wrong answers without an error](data-type-traps/) | none — creates its own | 2016 |
| [Row-level security: what the filter stops, and what it doesn't](row-level-security/) | none — creates its own | 2016 SP1 |
| [MSTVFs and table variables: the fixed guesses, and what replaced them](mstvf-table-variables/) | none — creates its own | 2019 |
| [Wait stats triage: where the time went](wait-stats-triage/) | none — creates its own | 2017 |

## Running them

The fastest way to a scratch instance is the `docker-compose.yml` in this
repo. It runs SQL Server 2019, 2022 and 2025 Developer edition side by side.

```
cp .env.example .env              # then choose your own MSSQL_SA_PASSWORD
docker compose up -d sql2022      # or sql2019, sql2025
tools/run-topic.sh tempdb         # one topic, end to end
tools/run-all.sh                  # every topic
```

`tools/run-topic.sh` runs a topic exactly as its README says: setup, the demo,
**the demo again** (every demo must be re-runnable without re-running setup),
then cleanup. It reports **PASS**, **WARN** or **FAIL**:

- **FAIL**: a script raised an error, or the demo's final "anything that did
  not behave as predicted" result set has a row in it.
- **WARN**: the only rows there are documented environment caveats, such as
  `INCONCLUSIVE`, `INTERMITTENT` or `SKIPPED`.

Every topic carries its own predictions and checks them, so a PASS means the
behaviour the README describes really happened on that instance. It isn't
just "the script ran". It defaults to the `sqldemo-2022` container. Pass
another container name as a second argument, or set `SQL_CONTAINER`.

Prefer SSMS or Azure Data Studio? Open each script and run it whole (F5).
Every README says what to expect.

### Continuous integration

[`.github/workflows/demos.yml`](.github/workflows/demos.yml) runs every topic
through `tools/run-topic.sh` on SQL Server 2019, 2022 and 2025, on every push.
A topic that needs something the CI containers don't have, such as a sample
database, has a `.ci-skip` file saying so.

## How these are built

Every topic follows the same shape, so once you've run one you know how to run
the rest.

**Numbered scripts, run in order.**

```
01-setup.sql     builds objects and loads data. Runs no demo of its own.
02-demo.sql      the demonstration. Run the whole file — never step through it.
03-cleanup.sql   restores anything setup changed, then drops everything.
```

**Setup and demo are always separate**, so it's never ambiguous which script to
run when, and so you can re-run a demo without rebuilding its data.

**Demos run unattended.** A demo script captures its own evidence — into a
results table, an Extended Events session, or both — and prints a summary at the
end. You should not have to sit there reading execution plans between
executions to see the point.

**Everything lives in a `Demo` schema** so cleanup can drop it wholesale without
touching the sample database. A topic that needs no sample database may create
its own database instead and drop it in cleanup — that is preferred where it
works, since it puts the demo's blast radius at zero.

**Setup records what it changes.** If a script alters a compatibility level, a
scoped configuration, a database setting such as Query Store, or a server
setting, it saves the original value first and cleanup puts it back. Each topic
README states plainly what its setup mutates — including when the answer is
"nothing", which is worth stating explicitly rather than leaving to inference.

**Prefer a scenario that needs no setting change at all.** Where two scenarios
teach the same lesson, the one that does not touch engine configuration wins,
even if it takes more setup data to build.

**Setup changes settings, never data it did not create.** Turning Query Store on
for a demo is fair; clearing the query history that was already in it is not.
Where a demo could take a destructive shortcut, it takes the longer route and
says why in comments.

**Object-scoped cache operations only** — `sp_recompile`, never
`DBCC FREEPROCCACHE`. Nothing here flushes an entire instance's plan cache.

**Nothing runs against production.** Several topics change database-level
settings by design. Use a scratch instance.

## Adding a topic

1. Create `<topic-name>/` — kebab-case, named for the behaviour being
   demonstrated, not the fix.
2. Add `01-setup.sql`, `02-demo.sql`, `03-cleanup.sql` following the conventions
   above. Split further only if a topic genuinely needs it (`02a`, `02b`).
3. Write `<topic-name>/README.md` covering: prerequisites, run order with rough
   timings, what each scenario shows, what setup changes on the database, and
   how to read the output.
4. End `02-demo.sql` with a result set headed
   `=== N. ANYTHING THAT DID NOT BEHAVE AS PREDICTED ===` that lists every
   check whose verdict was wrong. That is what `tools/run-topic.sh` and CI read.
5. Run `tools/run-topic.sh <topic-name>` until it reports PASS, on every
   version the topic claims to support.
6. Add a row to the **Topics** table above.
7. Note any client-specific requirements (SSMS settings, sqlcmd fallbacks) in
   the topic README — not everyone runs SSMS.

## Sample databases

Topics use Microsoft's published sample databases rather than synthetic data
where possible. Individual READMEs link to the download and give the restore
command.

| Database | Source |
|---|---|
| WideWorldImporters | [sql-server-samples releases](https://github.com/microsoft/sql-server-samples/releases/tag/wide-world-importers-v1.0) |

Backups are gitignored — download them yourself rather than expecting them here.

Where a sample database won't reproduce the behaviour on its own (WideWorldImporters
is generated with near-uniform distributions, so it can't show data skew), the
setup script manufactures the conditions **deliberately and says so** in
comments. A demo that admits what it constructed is worth more than one claiming
to have found it in the wild.

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They have been tested in a **limited, controlled environment** — the
specific SQL Server versions and configurations named in each topic README, and
nowhere else. They are not production-ready, and they have not been validated
against any other version, edition, configuration, or workload.

Run them only on a scratch instance you can afford to lose. Read every script
before you run it. You are solely responsible for reviewing, testing, and
deciding whether to run anything here.

To the fullest extent permitted by law, the author provides this repository
WITHOUT WARRANTY OF ANY KIND, express or implied, including but not limited to
the warranties of merchantability, fitness for a particular purpose, and
non-infringement. In no event shall the author be liable for any claim,
damages, data loss, service interruption, or other liability, whether in an
action of contract, tort, or otherwise, arising from, out of, or in connection
with these scripts or their use.

## License

[MIT](LICENSE). The as-is and no-liability terms in the licence apply in
addition to the disclaimer above.
