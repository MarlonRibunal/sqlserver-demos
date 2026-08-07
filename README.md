# SQL Server demo scripts

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Self-contained, runnable demonstrations of SQL Server behaviour — one folder per
topic. Each folder has its own README with prerequisites, run order, and what to
expect in the output.

## Topics

| Topic | Sample database | Min. version |
|---|---|---|
| [Parameter sniffing, `RECOMPILE`, memory grant feedback](parameter-sniffing/) | WideWorldImporters | 2017 (2022+ for all six scenarios) |
| [tempdb: when to reach for a `#temp` table](tempdb/) | none — creates its own | 2016 |

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
4. Add a row to the **Topics** table above.
5. Note any client-specific requirements (SSMS settings, sqlcmd fallbacks) in
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
