# Pagination: OFFSET vs keyset

Every list screen pages, and most page with `OFFSET ... FETCH`. It's easy and
works fine on page 1. This topic measures it on page 10,000, shows the rows
it loses and repeats when the data moves under the reader, and compares it
with keyset paging ("give me the 50 after the last one I showed you"). It
also shows what the total count for "page 1 of N" costs.

## The rule these scenarios are built around

**Page by key, not by position: `WHERE (sort key) < (last row's key)`,
`TOP (n)`, with an index on the sort key. Make the sort order unique. Don't
recount the total on every page.**

## Prerequisites

- SQL Server 2017 or later (`STRING_AGG`). Developed and tested on **2022
  CU25 (16.0.4255.1)**, Linux container.
- No sample database. `01-setup.sql` creates its own database, `PagingDemo`.
- Permission to `CREATE DATABASE`, and `VIEW SERVER STATE` (reads are
  measured through `sys.dm_exec_requests`).

## What setup changes on your instance

Nothing outside the database it creates:

- no compatibility level changed
- no database scoped configuration changed
- no trace flag set
- no existing database touched

The demo adds and removes a few rows of `Demo.Orders` in scenario C and puts
them back. `03-cleanup.sql` drops the database and confirms that none of its
files remain.

## Run order

```
01-setup.sql     ~20 s     creates PagingDemo: 1,000,000 orders, 20,000 tickets
02-demo.sql      ~20 s     five scenarios; prints a summary
03-cleanup.sql   seconds   drops PagingDemo
```

Run each file whole (F5).

## How it's built

`Demo.Orders` is paged newest first, `ORDER BY OrderDate DESC, OrderID
DESC`, 50 rows a page. `OrderID` is in the order because two orders share
each timestamp. `IX_Orders_Date` supports that order but doesn't include the
other columns, so every row shown needs a key lookup.

Each paging procedure returns its page into variables rather than to the
client: the IDs as one string, plus a checksum of the other columns so
they're really fetched. It records its logical reads (this session's
`sys.dm_exec_requests.logical_reads` just before and after the query) and the
IDs in `Demo.Pages`. Every paging query uses `OPTION (RECOMPILE)`, so that
page 1's plan isn't reused for page 10,000.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2022 CU25.

| page | `OFFSET` | `OFFSET`, deferred join | keyset |
|---|---|---|---|
| 1 | 207 | 215 | 215 |
| 10 | 1,642 | | 217 |
| 100 | 16,002 | | 217 |
| 1,000 | **159,530** | 322 | **217** |
| 10,000 | 22,933–40,187 | 1,213 | **217** |

Logical reads for one page of 50 rows.

### A — OFFSET's cost grows with the page number

```sql
SELECT ... FROM Demo.Orders
ORDER BY OrderDate DESC, OrderID DESC
OFFSET (@PageNo - 1) * 50 ROWS FETCH NEXT 50 ROWS ONLY;
```

`OFFSET 49950` doesn't jump to row 49,951. It reads 49,950 rows and throws
them away. Each of those rows also cost a key lookup here, so page 1,000 took
**159,530 reads to show 50 rows**, 770 times page 1. By page 10,000 the
optimizer had given up on the index and scanned the whole table instead
(23,000–40,000 reads; the plan varied between runs). Either way, the cost
of a page depends on how deep it is.

```sql
SELECT TOP (50) ... FROM Demo.Orders
WHERE  OrderDate <= @LastDate AND (OrderDate < @LastDate OR OrderID < @LastID)
ORDER BY OrderDate DESC, OrderID DESC;
```

Keyset paging seeks straight to where the previous page ended: **217 reads
for page 10 and for page 10,000**. Both methods returned identical rows for
all five pages. The application keeps the last row's key, which it has
already shown, instead of a page number.

The price: keyset paging moves forward (or backward) from a row. It can't
jump to "page 7,342" without knowing where that page starts. For "next" and
"previous" and infinite scroll, which is what most screens do, that's no
loss.

### B — the deferred join

When you must keep `OFFSET` (a "go to page" box), take the offset over the
index alone, then fetch the rows:

```sql
SELECT o.* FROM (SELECT OrderID FROM Demo.Orders
                 ORDER BY OrderDate DESC, OrderID DESC
                 OFFSET @skip ROWS FETCH NEXT 50 ROWS ONLY) AS k
JOIN Demo.Orders AS o ON o.OrderID = k.OrderID;
```

Skipped rows no longer cost a lookup each: page 1,000 fell from 159,530 reads
to **322**. Skipped rows are still read, though, from the narrow index. Page
10,000 took 1,213 reads to keyset's 217, and the cost keeps growing.

### C — the data moves between pages

| between page 1 and page 2 | `OFFSET` | keyset |
|---|---|---|
| 5 new orders arrive (at the top) | **5 rows of page 1 shown again** on page 2 | 0 |
| 5 orders from page 1 are removed | **5 rows never shown** | 0 |

`OFFSET 50` means "skip the first 50 rows *as they are now*". When five new
rows push everything down, the last five rows of page 1 become the first
five of page 2, and the reader sees them twice. When five rows go, five rows
slide from page 2 onto page 1, which the reader has already seen, and nobody
ever sees them. Keyset paging asks for "the rows after this one", which
doesn't change when other rows come and go.

### D — ties in the ORDER BY

`Demo.Tickets`: 20,000 tickets, each with a `Priority` of 1, 2 or 3. All
1,000 pages, 20 at a time:

| order | rows shown | distinct tickets |
|---|---|---|
| `ORDER BY Priority` | 20,000 | **18,760**: 1,240 shown twice, 1,240 never shown |
| `ORDER BY Priority, TicketID` | 20,000 | 20,000 |

With only three values in the order, which tickets come first *within* a
priority is up to the plan, and the plan wasn't the same for every page. The
shallow pages read `IX_Tickets_Priority`, which lists ties in `CreatedAt`
order. The deep pages scanned and sorted, which lists them in another. Each
page was a correct answer to its own query, but together they weren't a
listing of the table. No error, just 1,240 tickets the user never saw.
**Add a unique column to the end of every paged `ORDER BY`.**

### E — "page 1 of 20,000"

| page 1 | reads |
|---|---|
| without the total | 207 |
| with `COUNT(*) OVER ()` | **3,189,538** |

`COUNT(*) OVER ()` puts the total on every row of the page, which means
counting every row behind it, through a spool, on every page view. The
count cost **15,000 times as much as the page**. Show "more results" instead
of a total, cache the count, or use an estimate such as `sys.partitions.rows`
when an exact number doesn't matter.

## Traps from building this

- **`@AfterDate IS NULL OR ...` in the keyset query** (for "first page or
  next page" in one statement) stopped the index seek. Pages cost 217 reads
  at page 10 and 1,214 at page 10,000, even with `OPTION (RECOMPILE)`. Two
  statements, one per case, fixed it.
- **Key lookups under a `TOP` prefetch past it.** With the lookups under the
  `TOP (50)`, the nested loop's `ORDERED PREFETCH` read far ahead: 1,162
  reads for a deep keyset page instead of 165. Take the 50 keys first, then
  join for the rows.

## How to read the output

`02-demo.sql` prints three result sets:

1. logical reads per page for each method
2. the verdicts
3. **anything that didn't behave as predicted, which should be empty**

## Takeaways

1. **`OFFSET` reads every row it skips.** Page 1,000 cost 159,530 reads; the
   same page by keyset, 217.
2. **Keyset paging costs the same on every page**, and doesn't repeat or
   lose rows when the data changes between pages.
3. **When you must have `OFFSET`, offset over the index, then join** (322
   reads instead of 159,530).
4. **Make the order unique.** Paging by a three-value column showed 1,240
   tickets twice and 1,240 never.
5. **Don't count all the rows on every page.** The total cost 15,000× the
   page.

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
