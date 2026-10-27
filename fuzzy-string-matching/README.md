# Fuzzy string matching in SQL Server 2025: EDIT_DISTANCE, Jaro-Winkler, and SOUNDEX

> **The short version:** [Fuzzy string matching (SQL Server 2025)](https://marlonribunal.com/sqlserver-demos/fuzzy-string-matching/) on marlonribunal.com covers the symptoms, the cause and the fixes on one page, with a query to check your own server.

Finding "Jhonson" when someone searches for "Johnson" used to mean
`SOUNDEX`, `DIFFERENCE`, or a CLR function. SQL Server 2025 adds four
built-in functions: `EDIT_DISTANCE`, `EDIT_DISTANCE_SIMILARITY`,
`JARO_WINKLER_DISTANCE` and `JARO_WINKLER_SIMILARITY`. This topic measures
what they need before they'll run, what they count, how their two
similarity scores disagree, and what a search over 200,000 names costs.

## The rule these scenarios are built around

**Fuzzy matching is a scan: every row's distance is computed. Narrow the
rows first with something indexed, and accept that the narrowing has its
own blind spots. Pick one similarity score and tune its threshold on your
own data; the two scores don't agree. And on the tested build, the
functions need preview features and a Windows collation.**

## Prerequisites

- **SQL Server 2025 or later.** Developed and tested on **2025 RTM-CU9-GDR
  (17.0.5015.4)**, Linux container. On 2022 and earlier the scripts still
  run, and the demo reports every scenario as `SKIPPED`.
- No sample database. `01-setup.sql` creates its own database, `FuzzyDemo`.
- Permission to `CREATE DATABASE`.

## What setup and the demo change on your instance

Nothing outside the database they create. `FuzzyDemo` is created with the
Windows collation `Latin1_General_100_CI_AS`, whatever the server's default,
and with the database scoped configuration **`PREVIEW_FEATURES`** on.
Scenario A turns it off and back on. `03-cleanup.sql` drops the database and
confirms that none of its files remain.

## Run order

```
01-setup.sql     ~10 s     creates FuzzyDemo: 200,000 surnames, with typos
02-demo.sql      seconds   five scenarios
03-cleanup.sql   seconds   drops FuzzyDemo
```

Run each file whole (F5).

## The data

`Demo.People` holds 200,000 surnames: 40 common ones, each written five ways,
1,000 rows of each:

| way | Johnson becomes |
|---|---|
| as written | Johnson |
| 2nd and 3rd letters swapped | Jhonson |
| 3rd letter dropped | Jonson |
| 2nd letter replaced by `y` | Jyhnson |
| the next letter of the alphabet first | Kohnson |

A persisted `SOUNDEX(Surname)` column is indexed.

## The scenarios, and what they showed

The numbers below come from the tested run: SQL Server 2025 RTM-CU9-GDR.

### A — what the functions need

| | result |
|---|---|
| `EDIT_DISTANCE`, `PREVIEW_FEATURES = OFF` | **error 195**: "not a recognized built-in function name" |
| `PREVIEW_FEATURES = ON`, Windows collation | ran |
| a string in `SQL_Latin1_General_CP1_CI_AS` | **error 9847**: "does not support SQL_* collations" |

On the tested build the functions are a **preview feature**, switched on per
database. And they refuse `SQL_*` collations.
`SQL_Latin1_General_CP1_CI_AS` is the default server collation on a
US-English install, so on many servers the functions fail on existing
columns until they're cast to a Windows collation (`COLLATE
Latin1_General_100_CI_AS`).

### B — what EDIT_DISTANCE counts

| pair | `EDIT_DISTANCE` |
|---|---|
| smith / SMITH | **0**: the collation is case-insensitive |
| Müller / Muller | 1: and accent-sensitive |
| ab / ba | **1**: a swap of adjacent letters is one edit |
| Katherine / Kathy | 5 |
| Katherine / Kathy, maximum distance 1 | **2** |
| NULL / Kathy | NULL |

Comparison follows the collation, unlike [`REGEXP_LIKE`](../regex-functions/),
which ignores it. Swapping two adjacent letters, the most common typo,
counts as one edit, not two. And the optional third argument is a maximum:
once the distance passes it, the function stops counting and returns the
maximum plus 1. It's an optimization, not a different answer to "is this
within N edits?".

### C — the two similarity scores disagree

| pair | `EDIT_DISTANCE_SIMILARITY` | `JARO_WINKLER_SIMILARITY` |
|---|---|---|
| Smith / Smyth | 80 | 89 |
| MARTHA / MARHTA | 83 | 96 |
| Jonathan / Jon | **38** | **85** |
| Smith / Smithson | **63** | **93** |
| Robert / Bob | 33 | 50 |

Both run from 0 to 100, which invites using one threshold for either. Don't.
Jaro-Winkler rewards a shared beginning: at a threshold of 80 it accepts
Jonathan/Jon and Smith/Smithson, and edit-distance similarity rejects both.
Neither is wrong. They measure different things, and a threshold only means
something for the score it was tuned on.

### D — SOUNDEX against edit distance

| pair | SOUNDEX | edit distance |
|---|---|---|
| Catherine / Katherine | **C365 / K365**: different | 1 |
| Robert / Rupert | **R163 / R163**: the same | 2 |

`SOUNDEX` keeps the first letter, so a different first letter is never a
match, however similar the rest. And it matches names that are different
names.

### E — searching 200,000 names

Every surname within two edits of "Johnson". Serial, best of three:

| | CPU | names found |
|---|---|---|
| `EDIT_DISTANCE` on every row | 149 ms | Jhonson, Johnson, Jonson, Jyhnson, **Kohnson**, **Roinson** |
| `SOUNDEX` code first, then `EDIT_DISTANCE` | **20 ms** | Jhonson, Johnson, Jonson, Jyhnson |

Fuzzy functions can't use an index, so every row is computed. Filtering on
the indexed `SOUNDEX` code first cut the CPU sevenfold, and lost Kohnson:
the narrowing step has `SOUNDEX`'s blind spot. Two edits also reached
**Roinson**, which is a Robinson with a letter dropped. That's a different
person, and a threshold of 2 on a seven-letter name is generous. Short names
need a smaller one.

## How to read the output

`02-demo.sql` prints three result sets:

1. every measurement
2. the verdicts, each with its evidence
3. **anything that didn't behave as predicted, which should be empty**
   on 2025 (on 2022 and earlier, the `SKIPPED` rows)

## Traps from building this

- **The first probe failed on the default collation.** The container's
  server collation is `SQL_Latin1_General_CP1_CI_AS`, and every function
  raised error 9847. `FuzzyDemo` now sets a Windows collation explicitly.
- **`PREVIEW_FEATURES` can't be set in `master`** (error 12122). It's a
  setting for user databases.

## Takeaways

1. **On the tested build the functions need `PREVIEW_FEATURES = ON`** and a
   **Windows collation**: error 195 and error 9847 otherwise.
2. **`EDIT_DISTANCE` follows the collation** (case ignored here) and counts
   a swap of adjacent letters as one edit.
3. **With a maximum, it returns the maximum plus 1** once it's passed.
4. **The two similarity scores disagree**: Jonathan/Jon scored 85 and 38.
   Tune a threshold for one of them.
5. **`SOUNDEX` misses a different first letter** and matches different
   names.
6. **A search computes every row.** Narrowing with an indexed `SOUNDEX`
   code cut the CPU sevenfold and lost a match.

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
