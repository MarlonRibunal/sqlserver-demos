# Vector search in SQL Server 2025: exact, approximate, and the catches

> **The short version:** [Vector search (SQL Server 2025)](https://marlonribunal.com/sqlserver-demos/vector-search/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

SQL Server 2025 stores embeddings in a native **`vector`** type and offers
two ways to find the nearest ones: an **exact** search, `VECTOR_DISTANCE`
with `ORDER BY` and `TOP`, and an **approximate** one, `VECTOR_SEARCH` on a
DiskANN **vector index**. This topic runs both over 100,000 vectors of 128
dimensions and measures what each reads, what the approximate search
misses, and what the index costs, including a table it makes read-only.

## The rule these scenarios are built around

**The exact search reads every row, every time; the vector index reads
less and returns most, not all, of the true nearest rows. On the tested
build the index needs `PREVIEW_FEATURES`, makes the table read-only, and
applies a `WHERE` clause after it has picked its top N. Use it for a large,
mostly static set of vectors, and over-fetch when you filter.**

## Prerequisites

- **SQL Server 2025 or later.** Developed and tested on **2025 RTM-CU9-GDR
  (17.0.5015.4)**, Linux container. On 2022 and earlier the scripts still
  run, and the demo reports every scenario as `SKIPPED`.
- No sample database, and no AI model. `01-setup.sql` creates its own
  database, `VectorDemo`, and generates synthetic vectors (see below).
- Permission to `CREATE DATABASE`.

## What setup and the demo change on your instance

Nothing outside the database they create. Inside `VectorDemo`:

- setup turns on the database scoped configuration **`PREVIEW_FEATURES`**,
  which the vector index needs on the tested build
- scenario F turns it off and back on, and creates and drops a small table
- every write in scenario D fails, by design

`03-cleanup.sql` drops the database and confirms that none of its files
remain.

## Run order

```
01-setup.sql     1-2 min   creates VectorDemo: 100,000 vectors and a vector index
02-demo.sql      ~10 s     six scenarios
03-cleanup.sql   seconds   drops VectorDemo
```

Run each file whole (F5). Most of setup's time is building the vector
index.

## The data

`Demo.Embeddings` holds 100,000 rows of `vector(128)` in 200 clusters of 500.
Each cluster has a fixed centre, and each row is its centre plus noise, both
from hashes, so every run builds the same vectors. Real embeddings come from
a model; these are clustered the same way, which is what a nearest-neighbour
search depends on.

The 20 test queries aren't in the table. Each is near one cluster's centre,
with more noise than the stored rows.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2025 RTM-CU9-GDR.

### A — the exact search

```sql
SELECT TOP (10) ID FROM Demo.Embeddings
ORDER BY VECTOR_DISTANCE('cosine', Embedding, @q);
```

**7,193 reads per query, for a table of 7,171 pages.** There's no index that
helps `ORDER BY` a distance: every row's distance is computed, every time.
It's exact, and its cost grows with the table.

### B — the approximate search

```sql
SELECT t.ID
FROM VECTOR_SEARCH(TABLE = Demo.Embeddings AS t, COLUMN = Embedding,
                   SIMILAR_TO = @q, METRIC = 'cosine', TOP_N = 10) AS s;
```

| | per query |
|---|---|
| exact | 7,193 reads |
| `VECTOR_SEARCH` | **2,335 reads** |
| true top 10 also found | **167 of 200 (83%)** |
| queries that found all 10 | 10 of 20 |

The index walks a graph instead of reading every row. The price is
**recall**: it returned 83% of the true nearest rows here, and only half of
the queries got all ten. Across runs while building this, recall was 83% to
93% on the same data: the index isn't built identically every time. For
"find similar documents" that's usually fine. For anything that must be
exact, it isn't.

### C — filtering

The 10 nearest rows to row 777 that are **not** in its own cluster:

| | rows returned |
|---|---|
| `VECTOR_SEARCH ... TOP_N = 10` with `WHERE t.ClusterID <> @cluster` | **0** |
| the same with `TOP_N = 1000` | 500 |
| exact `TOP (10) ... WHERE ClusterID <> @cluster ORDER BY distance` | 10 |

**`VECTOR_SEARCH` picks its top N first, and the `WHERE` clause filters
those.** All ten nearest rows were in the excluded cluster, so asking for 10
returned nothing, without an error. Ask for many more than you need and
filter that, or use the exact search when a filter removes most rows.

### D — writing to the indexed table

| | result |
|---|---|
| `INSERT` one row | **error 42231** |
| `UPDATE` one row (not the vector column) | **error 42231** |
| `DELETE` | **error 42231** |

"Data modification statement failed because table has a vector index on
it." On the tested build **a vector index makes the table read-only**, even
for a column that isn't the vector. To add rows: drop the index, load, and
rebuild it, which scenario E prices.

### E — what the index costs

| | |
|---|---|
| the table | 7,171 pages |
| the vector index | **3,348 pages** |
| generating and loading the 100,000 rows | 20 s |
| building the index | **75 s** |

The build ran under x86 emulation on an ARM laptop, so the absolute time is
pessimistic. The comparison isn't: building the index took nearly four times
as long as creating the data.

### F — preview features, and dimensions

| | result |
|---|---|
| `CREATE VECTOR INDEX` with `PREVIEW_FEATURES = OFF` | **error 343**: "Unknown object type 'VECTOR'" |
| the same with `PREVIEW_FEATURES = ON` | ran |
| `VECTOR_DISTANCE` between `vector(3)` and `vector(2)` | **error 42204** |

The `vector` type, `VECTOR_DISTANCE` and the exact search all worked with
the setting off. The vector index, on the tested build, is a **preview
feature**, switched on per database. The read-only restriction in D may well change as it matures:
re-run this demo on your build before relying on either.

## How to read the output

`02-demo.sql` prints three result sets:

1. every measurement
2. the verdicts, each with its evidence
3. **anything that didn't behave as predicted, which should be empty**
   on 2025 (on 2022 and earlier, the `SKIPPED` rows)

## Traps from building this

- **A database scoped configuration applies from the next batch.** Setup
  first turned on `PREVIEW_FEATURES` and created the index in the same
  batch, and got error 343 anyway. Each change is now a batch of its own.
- **`DROP TABLE IF EXISTS` and `CREATE TABLE` in one batch** compiled the
  insert against the old table's definition: a prototype failed with
  "vector dimensions 128 and 64 do not match" after changing the size.
- **Hash-based test data needs a real hash.** `CHECKSUM` of an integer is
  the integer, so the first prototype's "noise" repeated every 1,000 rows,
  and ten rows were identical to the query. Hashing a string fixed it.

## Takeaways

1. **The exact search reads the whole table for every query**: 7,193 reads
   for 7,171 pages.
2. **`VECTOR_SEARCH` read a third as much, and is approximate**: 83% of the
   true top 10 in this run, between 83% and 93% across runs.
3. **A `WHERE` on `VECTOR_SEARCH` filters its top N afterwards.** Asked for
   10, it returned 0. Over-fetch, or use the exact search.
4. **On the tested build the vector index makes the table read-only**
   (error 42231).
5. **It's big and slow to build**: half the table's size, and nearly four
   times the load time.
6. **It needs `PREVIEW_FEATURES = ON`** on the tested build (error 343
   without).

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
