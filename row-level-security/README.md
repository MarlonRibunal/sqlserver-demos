# Row-level security: what the filter stops, and what it doesn't

Row-level security (RLS) adds a predicate to every query on a table, so
each tenant sees only its own rows. The filter does that. This topic runs a
multi-tenant table the common way, with one application user and the
tenant passed in `SESSION_CONTEXT`, and shows what the filter doesn't do: it
doesn't stop writes, it trusts whoever sets the context, it leaks through
constraints and identity values, and its shape decides whether a query
seeks or scans.

## The rule these scenarios are built around

**A filter predicate only filters reads. Add `BLOCK` predicates for writes,
set the tenant `WITH @read_only = 1`, scope unique keys to the tenant, keep
the predicate a plain equality on an indexed column, and `CAST`
`SESSION_CONTEXT` to the column's type.**

## Prerequisites

- SQL Server 2016 SP1 or later. Developed and tested on **2022 CU25
  (16.0.4255.1)**, Linux container.
- No sample database. `01-setup.sql` creates its own database, `RlsDemo`.
- Permission to `CREATE DATABASE`.

## What setup changes on your instance

Nothing outside the database it creates:

- no server login. The application user, `AppUser`, is a database user
  `WITHOUT LOGIN` inside `RlsDemo`, and the demo impersonates it with
  `EXECUTE AS USER`
- Service Broker is enabled on `RlsDemo` only. Scenario C uses it for a
  background session (see below)
- no compatibility level, database scoped configuration or trace flag
  changed
- no existing database touched

The demo clears your session's `TenantID` at the start and the end, and
checks you're back to being `dbo` afterwards. `03-cleanup.sql` drops the
database and confirms that none of its files remain.

## Run order

```
01-setup.sql     seconds   creates RlsDemo: 100,000 orders for three tenants
02-demo.sql      ~10 s     five scenarios; prints a summary
03-cleanup.sql   seconds   drops RlsDemo
```

Run each file whole (F5).

## The setup

`Sales.Orders` holds three tenants: tenant 1 has 90,000 orders, tenant 2
9,900, tenant 3 100. The application connects as `AppUser`, and its data
layer says which tenant it's serving:

```sql
EXEC sys.sp_set_session_context @key = N'TenantID', @value = 3;
```

The predicate:

```sql
CREATE FUNCTION Security.fn_Tenant (@TenantID int)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN SELECT Visible = 1
          WHERE  @TenantID = CAST(SESSION_CONTEXT(N'TenantID') AS int);

CREATE SECURITY POLICY Security.TenantPolicy
    ADD FILTER PREDICATE Security.fn_Tenant(TenantID) ON Sales.Orders
    WITH (STATE = ON);
```

## The scenarios, and what they returned

Every value below is what the tested build returned.

### A — the filter works

| | returned | wanted |
|---|---|---|
| `AppUser`, `TenantID` = 1, 2, 3 | 90,000 / 9,900 / 100 | the same |
| `AppUser`, no `TenantID` | 0, and no error | 0 |
| **you, as `dbo`**, no `TenantID` | **0, and no error** | 100,000, for the report or ETL job |

The predicate applies to everyone, `db_owner` and `sysadmin` included. An
ETL job or report that runs as an admin, without setting a tenant, sees an
empty table and doesn't fail. Either set a `TenantID` in the job, tenant by
tenant, or exempt admins in the predicate, which costs the seek (scenario
E).

### B — a filter predicate doesn't stop writes

`AppUser` serving tenant 3:

| | returned | wanted |
|---|---|---|
| filter only: inserts an order with `TenantID = 2` | **1 inserted**; tenant 3 still sees 100, tenant 2 now 9,901 | rejected |
| filter only: `UPDATE` one of its orders to `TenantID = 2` | **1 updated**; tenant 3 now sees 99, tenant 2 9,902 | rejected |
| fix: `BLOCK` predicates, the insert | error 33504 | rejected |
| fix: `BLOCK` predicates, the update | error 33504 | rejected |
| … and **you, as `dbo`**, no `TenantID`, load an order | **error 33504** | inserted |

A filter predicate decides which rows a statement can *see*. It doesn't
check what's written. A tenant can write rows into another tenant, and
then can't see them itself. It can also move its own rows out of its own
view. `BLOCK` predicates check the row being written:

```sql
CREATE SECURITY POLICY Security.TenantPolicy
    ADD FILTER PREDICATE Security.fn_Tenant(TenantID) ON Sales.Orders,
    ADD BLOCK  PREDICATE Security.fn_Tenant(TenantID) ON Sales.Orders AFTER INSERT,
    ADD BLOCK  PREDICATE Security.fn_Tenant(TenantID) ON Sales.Orders AFTER UPDATE
    WITH (STATE = ON);
```

They bind admins too: the demo's own reload, as `dbo` with no tenant set,
failed with 33504 until it dropped the policy first.

### C — whoever can set the context can change tenant

| | returned | wanted |
|---|---|---|
| `AppUser`, serving tenant 3, runs `sp_set_session_context 'TenantID', 1` itself | **sees 90,000** | 100, and an error |
| fix: the data layer set `TenantID` `WITH @read_only = 1`; then the same | error 15664; still sees 100 | 100, and an error |

The predicate trusts `SESSION_CONTEXT`, and any code running on that
connection can set it. That includes SQL injection, and a reporting tool
that lets users write their own queries. Set it read-only when the
connection opens:

```sql
EXEC sys.sp_set_session_context @key = N'TenantID', @value = 3, @read_only = 1;
```

*Cannot set key 'TenantID' in the session context. The key has been set as
read_only for this session.* It stays that way for the life of the
session. With connection pooling, set it each time a connection is taken
from the pool.

The read-only half runs in a background session (Service Broker
activation), because doing it in yours would lock `TenantID` for the rest of
the demo and for a re-run in the same SSMS window. Activation sessions are
reused, and `SESSION_CONTEXT` survived from one activation to the next.

### D — rows you can't see still leak

`AppUser` serving tenant 3, which sees 100 orders:

| | returned | wanted |
|---|---|---|
| inserts order number `SO-000500` (tenant 1's) | **error 2627**: *… The duplicate key value is (SO-000500).* | 1 inserted |
| inserts an order of its own: its new `OrderID` | **100002** | a value that says nothing about others |
| fix: `UNIQUE (TenantID, OrderNumber)`; inserts `SO-000500` | 1 inserted | 1 inserted |

Constraints are checked against every row in the table, not just the
visible ones. A unique key across tenants tells any tenant whether a value
exists, and the message names it. A key scoped to the tenant doesn't. An
`IDENTITY` (or a `SEQUENCE`) shared by all tenants tells each one roughly how
many orders everyone has taken. Use a key that doesn't count across
tenants, such as a per-tenant number or a `uniqueidentifier`, if that
matters.

The documentation also warns about side channels through errors such as
divide by zero: a query that fails only when a hidden row has a certain
value. On the tested build it didn't leak. Three variants, against a row by
key and by scan, all returned 0 rows with no error. Whether it leaks depends
on the plan, so it isn't a scenario here.

### E — what the predicate costs

Tenant 3 reads its 100 orders: one `COUNT` and `SUM(Amount)`, logical reads
of a warm run.

| predicate | logical reads |
|---|---|
| `fn_Tenant`, index on `TenantID` | **8** |
| `fn_Tenant`, **no** index on `TenantID` | **3,047** |
| `fn_TenantOrOwner`: `... OR IS_MEMBER('db_owner') = 1` | **291** (and you, as `dbo`, see all 100,000) |
| `fn_TenantNoCast`: `@TenantID = SESSION_CONTEXT(N'TenantID')` | **291** |

| `fn_TenantNoCast`, the application sets `TenantID` as the string `'3'` | returned | wanted |
|---|---|---|
| orders tenant 3 sees | **0, and no error** | 100 |
| fix: `fn_Tenant` (with `CAST`) | 100 | 100 |

The predicate is added to every query on the table, so it needs an index
like any other filter. Without one, the smallest tenant reads the whole
table. With one, `OR` in the predicate (the admin bypass) turned the seek
into a scan of the index, and so did comparing the `int` column with
`SESSION_CONTEXT`'s `sql_variant` without a `CAST`. Without the `CAST`,
a `TenantID` passed as a string doesn't equal the number either. Values in a
`sql_variant` comparison of different type families are never equal, so
the tenant sees nothing.

## Traps from building this

- **A function a policy uses can't be altered**, even with the policy's
  `STATE = OFF`: Msg 3729. Drop the policy, change the function, and create
  the policy again.
- **`BLOCK` predicates block `dbo`'s loads too** (scenario B). Plan how the
  ETL job gets its rows in before turning them on.
- **`SESSION_CONTEXT` outlived the activation.** The background session
  found the previous activation's read-only `TenantID` still set.

## How to read the output

`02-demo.sql` prints two result sets:

1. **what SQL Server returned**: every step, what it gave, what was wanted,
   and `WORKS` / `TRAP` / `FIXED` / `info`
2. **anything that didn't behave as predicted, which should be empty**

## Takeaways

1. **The predicate binds admins too.** `dbo` with no tenant saw 0 rows and
   no error.
2. **Filter predicates don't stop writes.** Add `BLOCK` predicates `AFTER
   INSERT` and `AFTER UPDATE`.
3. **Set the tenant `WITH @read_only = 1`.** Otherwise the tenant is
   whatever the last statement on the connection said.
4. **Scope unique keys to the tenant**, and remember a shared identity
   counts everyone's rows.
5. **Index the tenant column, keep the predicate a plain equality, and
   `CAST` `SESSION_CONTEXT`.** 8 reads instead of 291 or 3,047.

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
