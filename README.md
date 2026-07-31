# SQL Server demo scripts

One folder per topic. Each folder is self-contained and has its own README with
run order and prerequisites.

| Topic | Folder | Sample database |
|-------|--------|-----------------|
| Parameter sniffing, `RECOMPILE`, memory grant feedback | [`parameter-sniffing/`](parameter-sniffing/) | WideWorldImporters |

## Conventions

- Scripts are numbered in run order: `01-setup.sql`, `02-demo.sql`,
  `03-cleanup.sql`.
- Setup and demo are always separate. Setup builds objects and runs no demo;
  the demo script runs unattended and records its own evidence.
- Everything is created inside a `Demo` schema so cleanup can drop it wholesale.
- Any setting a setup script changes is recorded first and restored by cleanup.
- `sp_recompile`, never `DBCC FREEPROCCACHE`.
