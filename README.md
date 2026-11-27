# MoonSQLite Inspect

Open and compare committed versions of an offline SQLite database. Given a checkpointed baseline and the WAL written after it, MoonSQLite Inspect can read an earlier revision, compare two revisions by rowid and trace each reported cell to its page in the baseline or to a specific WAL frame. The history index and row comparisons are implemented in MoonBit and use MoonSQLiteFile for WAL verification and record decoding. The CLI uses Node.js for file input and hashing. [MoonSQLiteFile](https://mooncakes.io/docs/prowk/moonsqlitefile)

## Install the library

Use MoonBit `moonc` 1.0.0-rc1 or newer and check the compiler with `moon version --all`. CI checks the same minimum and records the tested version in each run. Add the module to an existing MoonBit project. [CI runs](https://github.com/sssssurf/moonsqlite-inspect/actions/workflows/ci.yml)

```sh
moon add sssssurf/moonsqlite-inspect@0.5.1
```

Import the package in that project's `moon.pkg`.

```moonbit
import {
  "sssssurf/moonsqlite-inspect" @inspect,
}
```

Use the checkpointed baseline and WAL bytes from the capture workflow below.

```moonbit
fn first_commit_changes(
  base : Bytes,
  wal : Bytes,
) -> Array[@inspect.VersionedChange] raise @inspect.InspectError {
  let history = @inspect.open_wal_timeline(base, wal)
  @inspect.diff_revisions(history.snapshot(0), history.snapshot(1), "status")
}
```

The library builds on JS, native, Wasm and Wasm GC. JS shares read-only frame slices with the upstream validator. The other targets copy the requested frame bytes. The CLI entry point is supported on JS with Node.js 24. [Mooncakes package](https://mooncakes.io/docs/sssssurf/moonsqlite-inspect)

## Reproduce a WAL history

Run the following commands from the repository root with MoonBit, Node.js and Python 3.10 or later. Python's SQLite extension generates the demonstration capture. Use a fresh output directory to regenerate it.

```sh
moon update
moon build --target js
node _build/js/debug/build/cmd/main/main.js --help
python scripts/wal_demo.py _build/wal-demo
node _build/js/debug/build/cmd/main/main.js wal-verify _build/wal-demo/baseline.sqlite _build/wal-demo/capture.wal _build/wal-demo/capture.json
node _build/js/debug/build/cmd/main/main.js wal-history _build/wal-demo/baseline.sqlite _build/wal-demo/capture.wal
node _build/js/debug/build/cmd/main/main.js wal-rows _build/wal-demo/baseline.sqlite _build/wal-demo/capture.wal 1 status
node _build/js/debug/build/cmd/main/main.js wal-row _build/wal-demo/baseline.sqlite _build/wal-demo/capture.wal 1 status 41 --manifest _build/wal-demo/capture.json
node _build/js/debug/build/cmd/main/main.js wal-range _build/wal-demo/baseline.sqlite _build/wal-demo/capture.wal 3 status -9223372036854775808 9223372036854775807 2
node _build/js/debug/build/cmd/main/main.js wal-range _build/wal-demo/baseline.sqlite _build/wal-demo/capture.wal 3 status 9223372036854775807 9223372036854775807 2
node _build/js/debug/build/cmd/main/main.js wal-changes _build/wal-demo/baseline.sqlite _build/wal-demo/capture.wal 0 1 status
node _build/js/debug/build/cmd/main/main.js wal-changes _build/wal-demo/baseline.sqlite _build/wal-demo/capture.wal 1 2 status
node _build/js/debug/build/cmd/main/main.js wal-changes _build/wal-demo/baseline.sqlite _build/wal-demo/capture.wal 0 2 status
node _build/js/debug/build/cmd/main/main.js wal-series _build/wal-demo/baseline.sqlite _build/wal-demo/capture.wal 0 3 status --limit 2 --manifest _build/wal-demo/capture.json
```

The demo creates four SQLite commits. Revision 0 is the baseline. Row 41 changes from `ready` to `waiting` in revision 1 and returns to `ready` in revision 2. The two adjacent comparisons each report one change. The comparison from 0 to 2 returns an empty `entries` array. Reported rows identify the cell's page payload offset and, for WAL pages, the frame and revision that supplied that page.

`wal-row` seeks a signed rowid at the selected revision and returns zero or one record. `wal-range` reads an inclusive rowid interval in ascending order, up to the requested row limit and the JSON byte budget. The first example page ends with `next_rowid: "9223372036854775807"`. For the next call, use that value as the first bound and keep the same capture, revision, table and last bound. `null` marks exhaustion. The lookup reads the relevant B-tree branches and any overflow pages needed by the selected records.

`wal-series` compares every adjacent pair in the requested interval, including pairs with zero changes. Each invocation indexes the WAL once and returns up to 32 comparisons by default. Use `--limit` to request 1–1024 comparisons. The demo returns `next_from: 2`, so the next call uses `2 3 status`. A `null` continuation marks completion. Revision 4 in the demo changes the table definition, so the series stops at revision 3.

`wal-rows`, `wal-row`, `wal-range`, `wal-changes` and `wal-series` each return at most 8 MiB of UTF-8 JSON, including the final newline. `wal-range` reserves space for its continuation and returns early when another row would exceed the budget. When the first row cannot fit, the command reports an error with empty standard output. Use `wal-range` for large tables, a smaller series `--limit` for multiple comparisons or a library visitor for larger individual values. A decoding error while reading a page of results discards that response. Record decoding and the shared history index also use memory.

`wal-verify` checks file sizes, SHA-256 digests and the WAL epoch against `capture.json`, then reports the validated timeline. Provide `--manifest FILE` to apply the same check before any history read or comparison. To make your own bundle, use the capture helper with a SQLite writer you control. It keeps a read transaction open from the checkpointed baseline through export. The CLI accepts up to 64 MiB per database or WAL file. Use the latest-snapshot commands below for a consistent same-time database/WAL pair. [Capture and snapshot details](docs/wal-timeline.md)

From MoonBit, open the capture once with `open_wal_timeline(base, wal)`. Use `commits()` to list revisions, `snapshot(revision)` to read stored rows and `diff_revisions(before, after, name)` for a pair with matching table definitions. `WalRevision::visit_table` visits rows without collecting the table, and `visit_revision_changes` visits changes between any two supported views, including reverse comparisons. Return `false` to stop before reading another record. A `true` result means the scan completed; an error can follow earlier callbacks. The array-returning APIs remain available. `visit_adjacent_changes` emits ordered changes and completion events one comparison at a time. `page_origin(page)` gives the underlying byte location of a logical page. [Visitor examples](docs/wal-timeline.md#visit-historical-rows-and-arbitrary-pairs)

`WalRevision::find_row` and `WalRevision::visit_rowid_range` seek directly in a revision. The range visitor returns the first unaccepted key when its row limit is reached or its callback declines the current row. [Historical lookup API](docs/wal-timeline.md#seek-rows-at-a-revision)

## Inspect a backup or the latest snapshot

Use a stable offline database copy. For latest-snapshot commands, the database and WAL must belong to the same static capture. Omitting the WAL shows the main image alone.

```sh
node _build/js/debug/build/cmd/main/main.js catalog backup.sqlite
node _build/js/debug/build/cmd/main/main.js table backup.sqlite samples
node _build/js/debug/build/cmd/main/main.js index backup.sqlite samples_n
node _build/js/debug/build/cmd/main/main.js row backup.sqlite samples 4000
node _build/js/debug/build/cmd/main/main.js range backup.sqlite samples 100 900 25
node _build/js/debug/build/cmd/main/main.js table capture.sqlite samples --wal capture.wal
node _build/js/debug/build/cmd/main/main.js diff before.sqlite after.sqlite samples
node _build/js/debug/build/cmd/main/main.js wal-diff capture.sqlite samples --wal capture.wal
```

`index` also reads `WITHOUT ROWID` tables in their physical key order. `diff` compares signed rowids in tables with identical stored SQL definitions and reports added, removed and changed records. It walks the two tables row by row and retains the changes. `wal-diff` compares the main image with the committed snapshot reconstructed from its WAL. Each record includes the physical source location. JSON uses decimal strings for 64-bit integers and rowids and hexadecimal strings for blobs.

`row` and `range` work with ordinary rowid tables, and both accept an optional `--wal WAL`. They follow B-tree branches that intersect the requested keys. `row` returns an empty `entries` array if the key is absent. `range` takes inclusive signed 64-bit bounds and a positive row limit. When `next_rowid` is a decimal string, use it as the next request's first bound with the same snapshot and upper bound. A `null` value marks the last page.

The corresponding library methods are `Snapshot::find_row` and `Snapshot::scan_rowid_range`. They work on the in-memory snapshot returned by `open_snapshot`, including its committed WAL pages.

The reader supports UTF-8, UTF-16LE and UTF-16BE databases with SQLite page sizes from 512 through 65,536 bytes. It validates cell boundaries, freeblock chains and rowid ranges in the B-trees it visits. It returns the SQLite storage classes and field order from each physical record. For an `INTEGER PRIMARY KEY` alias, the key appears in `rowid` and its stored column remains NULL. SQL projections and schema-derived defaults belong to the query layer. The library caps each decoded record at 16 MiB and the CLI caps each input file at 64 MiB.

Stored REAL values use numeric equality. NaNs compare equal to other NaNs, and positive and negative zero compare equal. NaN payload bits are outside this value comparison. A raw serial-7 NaN remains a `Real` value here, while SQLite SQL reads it as NULL. A stored REAL-to-NULL or INTEGER-to-REAL change still appears in a diff. JSON encodes REALs as strings, including `NaN`, `Infinity` and `-Infinity`. [SQLite numeric representation](https://sqlite.org/floatingpoint.html)

## Reproduce verification

```sh
moon test --target js --frozen
moon build --target js --frozen
python -B scripts/sqlite_oracle.py
python -B scripts/history_stress.py
python -B scripts/verify_distribution.py
python -B scripts/verify_readme.py
```

The oracle checks 6,012 legacy table, index and `WITHOUT ROWID` records across three page sizes and three encodings. It compares signed rowid lookups, pagination and differences with SQLite queries and checks page provenance against raw cell bytes. WAL coverage includes historical reads and adjacent changes for all nine encoding/page-size combinations, truncation and regrowth, partially written tails, uncommitted frames, batch continuation, overflow-only updates, output limits and rejection of mismatched capture files. [SQLite file format](https://sqlite.org/fileformat2.html)

`history_stress.py` uses two fixed seeds and two page sizes to generate four captures with 24 commits each. It compares 100 historical snapshots and 120 adjacent, nonadjacent, reverse or identical-endpoint comparisons with SQLite queries, and checks cell origins against raw frame bytes. The workload includes multi-page tables, index updates, overflow payloads, growth, vacuum shrink and regrowth, savepoint and transaction rollback, and writes to an unrelated table.

`verify_distribution.py` unpacks the current distribution and uses it in a separate consumer project. Seven public API tests run on each of the four backends, including a history seek and a resume at the first rejected key. The SQLite oracle checks multi-level seeks, historical insertion and deletion, raw cell origins and pagination where JSON escaping triggers the byte budget. `verify_readme.py` executes the README's history commands in a newly extracted package and checks all ten JSON reports. To verify the published release using a new registry installation, update the index and run the registry mode.

```sh
moon update
python -B scripts/verify_distribution.py --registry --version 0.5.1
```

After building the CLI, `python -B scripts/benchmark.py` measures latest WAL loading, backup comparison and point lookup. Add `--history` to measure indexing 12,000 commits and `--compare-export` to compare full exports of an 8,000-row BLOB table. Pass `--baseline /path/to/main.js` to run the paired cases against an earlier build. The benchmark checks matching results before reporting times.

Use `python -B scripts/benchmark.py --history-lookup --runs 7` to compare historical point lookup with scanning and filtering an 8,000-row capture. Supply `--baseline` with a 0.4.1 build to use that release for the scan. [Optimization plan and verification results](docs/optimization-plan-0.5.0.md)

## Source and license

MoonSQLite Inspect and the MoonSQLiteFile 0.8.1 dependency use Apache-2.0. The project builds on the upstream public APIs. Its own timeline indexes page lifetimes across all available revisions, compares stored rows and reports version-specific cell provenance. The SQLite engine is used by the demo and verification scripts. [Upstream release](https://github.com/prowk/MoonSQLiteFile/releases/tag/v0.8.1) · [Hackathon review and acceptance notes](docs/hackathon-review.md)
