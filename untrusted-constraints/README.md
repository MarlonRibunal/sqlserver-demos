# Untrusted constraints: enabled, but not trusted, and the plans that costs

> **The short version:** [Untrusted foreign keys and CHECK constraints](https://marlonribunal.com/sqlserver-demos/untrusted-constraints/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

A foreign key or `CHECK` constraint does two jobs. It stops bad rows, and it
tells the optimizer something it can rely on: every order has a customer,
every status is between 0 and 3. The optimizer only relies on it when SQL
Server has checked every row already in the table. Disable a constraint for a
load and enable it again the usual way, and it goes on stopping bad rows, but
the optimizer stops relying on it. Nothing warns you: `sys.foreign_keys` and
`sys.check_constraints` have a column for it, `is_not_trusted`. This topic
makes constraints untrusted in the common ways, and measures the plans.

## The rule these scenarios are built around

**`CHECK CONSTRAINT` enables a constraint; only `WITH CHECK CHECK
CONSTRAINT` makes it trusted again, by checking every row. Until then, the
optimizer can't remove a join through the foreign key, or skip a query the
`CHECK` constraint makes impossible.**

## Prerequisites

- **SQL Server 2016 or later.** Developed and tested on **2025 RTM-CU10
  (17.0.5035.5)** and **2022 RTM-CU25 (16.0.4255.1)**, Linux containers;
  CI also runs it on 2019.
- No sample database. `01-setup.sql` creates its own database,
  `UntrustedDemo` (about 30 MB).
- Permission to `CREATE DATABASE`.

## What setup and the demo change on your instance

Nothing outside the database they create. `03-cleanup.sql` drops the
database and confirms that none of its files remain.

## Run order

```
01-setup.sql     seconds   creates UntrustedDemo: 100,000 customers, 500,000 orders
02-demo.sql      seconds   five scenarios
03-cleanup.sql   seconds   drops UntrustedDemo
```

Run each file whole (F5).

## How it's built

`Demo.Orders` has a foreign key to `Demo.Customers`, and a `CHECK`
constraint that keeps `Status` between 0 and 3. Two queries live in
procedures:

```sql
-- q_Join: total order value. The join uses no column from Customers.
SELECT SUM(CAST(o.Amount AS bigint)) FROM Demo.Orders AS o
JOIN Demo.Customers AS c ON c.CustomerID = o.CustomerID;

-- q_Check: a status the CHECK constraint doesn't allow.
SELECT COUNT_BIG(*) FROM Demo.Orders WHERE Status = 7;
```

`Demo.usp_Run` recompiles a procedure, runs it, and reads its cached plan:
which tables the plan touches, and its logical reads from
`sys.dm_exec_query_stats`.

## The scenarios, and what they showed

The results below come from the tested run on SQL Server 2025 RTM-CU10. 2022
gave the same verdicts.

### A — trusted constraints

| | plan touches | logical reads |
|---|---|---|
| `q_Join` | `Orders` only: **the join is removed** | 1,370 |
| `q_Check` (`Status = 7`) | **neither table** | 6 |

With a trusted, `NOT NULL` foreign key, every order is known to have exactly
one customer, so the join can't remove or repeat a row, and the optimizer
drops it. With a trusted `CHECK` constraint, `Status = 7` can't match
anything, and the plan doesn't read the table.

### B — `NOCHECK`, then `CHECK`

```sql
ALTER TABLE Demo.Orders NOCHECK CONSTRAINT FK_Orders_Customers, CK_Orders_Status;
ALTER TABLE Demo.Orders CHECK CONSTRAINT FK_Orders_Customers, CK_Orders_Status;
```

This is how constraints are commonly disabled around a load and enabled
afterwards. Both are now **enabled, but not trusted**:

| | plan touches | logical reads |
|---|---|---|
| `q_Join` | `Orders` **and `Customers`** | **4,205** (was 1,370) |
| `q_Check` | **`Orders`**: a full scan | **1,370** (was 6) |

The constraints still reject new bad rows. What's lost is the optimizer's
use of them.

### C — born untrusted

| how the constraint was added | state |
|---|---|
| `WITH NOCHECK ADD CONSTRAINT ...` | enabled, **not trusted** |
| `... NOT FOR REPLICATION`, then `WITH CHECK CHECK CONSTRAINT` | enabled, **not trusted**, and the join stayed |

`WITH NOCHECK` skips the existing rows, so the constraint starts untrusted.
**A `NOT FOR REPLICATION` constraint is never trusted**, even after a
successful `WITH CHECK CHECK`: replication agents are allowed to bypass it.
If that option was set by a template and you don't use replication, the
only fix is to drop the constraint and add it again without it.

### D — re-trusting, when a bad row got in

While the foreign key was disabled, an order for customer 999,999, who
doesn't exist, was inserted.

| | result |
|---|---|
| orders, all / joined to a customer | 500,001 / **500,000** |
| `WITH CHECK CHECK CONSTRAINT` | **error 547**: "The ALTER TABLE statement conflicted with the FOREIGN KEY constraint" |
| orders without a customer, found with `NOT EXISTS` and deleted | 1 |
| `WITH CHECK CHECK CONSTRAINT` again | **trusted**; the join is removed again |

The first row matters: the untrusted key isn't wrong to keep the join. With
the bad order in the table, the join is what keeps it out of the total. The
optimizer refuses to assume what nobody checked. Re-trusting a key means
finding and fixing those rows first.

### E — what `WITH CHECK CHECK` locks

Run inside a transaction, so the locks can be read before they're released:

| | lock held |
|---|---|
| `Demo.Orders` | **Sch-M** |
| `Demo.Customers` | **Sch-M** |

Validating 500,000 orders took 4,067 logical reads. A schema modification
lock blocks every query on both tables, including reads under `NOLOCK`,
until it finishes. On a large table, re-trust in a maintenance window.

## How to read the output

`02-demo.sql` prints three result sets:

1. every measurement
2. the verdicts, each with its evidence
3. **anything that didn't behave as predicted, which should be empty**

## Traps from building this

- **"Not read" isn't zero reads.** The first version expected 0 logical
  reads for the impossible `Status = 7`. The plan didn't touch the table,
  but the query still reported 6 reads, so the verdict now checks the plan,
  not the count.
- **Each measurement recompiles first.** `Demo.usp_Run` calls
  `sp_recompile` before every run, so each plan is compiled against the
  constraint as it is at that moment, not taken from an earlier scenario.

## Not tested here

Loads are a common source of untrusted constraints: `BULK INSERT` and `bcp`
don't check constraints unless asked to (`CHECK_CONSTRAINTS`, `-h
"CHECK_CONSTRAINTS"`), and SSIS fast load has a "Check constraints" option.
That's documented behaviour; this demo doesn't load from a file, so it
doesn't measure it. Check `is_not_trusted` after any bulk load.

## Takeaways

1. **`CHECK CONSTRAINT` re-enables. `WITH CHECK CHECK CONSTRAINT`
   re-trusts.** Only the second one helps the optimizer.
2. **An untrusted foreign key keeps joins the optimizer would remove**,
   and an untrusted `CHECK` constraint makes impossible filters scan.
3. **`NOT FOR REPLICATION` constraints are never trusted.**
4. **Re-trusting fails with error 547 if bad rows got in.** Find them with
   `NOT EXISTS` first.
5. **Re-trusting holds Sch-M locks on both tables** while it checks every
   row.

## Disclaimer

These scripts are provided as-is, for demonstration and educational purposes
only. They are tested in a **limited, controlled environment** — the
configurations named under [Prerequisites](#prerequisites), SQL Server 2025
RTM-CU10 (17.0.5035.5) and 2022 RTM-CU25 (16.0.4255.1) in Linux containers,
and nowhere else. No other version, edition, platform, or configuration has
been exercised, and the measured numbers throughout this README are from
those instances rather than a general result.

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
