# MoonSQLite Inspect

Open and compare committed versions of an offline SQLite database in pure MoonBit. Given a checkpointed baseline and the WAL written after it, MoonSQLite Inspect can read an earlier revision, compare two revisions by rowid and trace each reported cell to its page in the baseline or to a specific WAL frame. It uses [MoonSQLiteFile](https://mooncakes.io/docs/prowk/moonsqlitefile) for WAL verification and historical record decoding. The CLI uses Node.js for file input.

## Reproduce a WAL history

Run the following commands from the repository root with MoonBit, Node.js and Python 3.10 or later. Python's SQLite extension generates the demonstration capture. Use a fresh output directory to regenerate it.

```sh
moon update
moon build --target js
python scripts/wal_demo.py _build/wal-demo
node _build/js/debug/build/cmd/main/main.js wal-history _build/wal-demo/baseline.sqlite _build/wal-demo/capture.wal
node _build/js/debug/build/cmd/main/main.js wal-rows _build/wal-demo/baseline.sqlite _build/wal-demo/capture.wal 1 status
node _build/js/debug/build/cmd/main/main.js wal-changes _build/wal-demo/baseline.sqlite _build/wal-demo/capture.wal 0 1 status
node _build/js/debug/build/cmd/main/main.js wal-changes _build/wal-demo/baseline.sqlite _build/wal-demo/capture.wal 1 2 status
node _build/js/debug/build/cmd/main/main.js wal-changes _build/wal-demo/baseline.sqlite _build/wal-demo/capture.wal 0 2 status
```

The demo creates four SQLite commits. Revision 0 is the baseline. Row 41 changes from `ready` to `waiting` in revision 1 and returns to `ready` in revision 2. The two adjacent comparisons each report one change. The comparison from 0 to 2 returns an empty `entries` array. Its row data and changes carry `source` fields that identify the cell's page payload offset and, for WAL pages, the frame and revision that supplied that page.

For a real input, copy the baseline immediately after a successful `wal_checkpoint(TRUNCATE)`, before the next write. Preserve the later WAL while the writer is idle, with checkpoints and WAL resets prevented between those two steps. SQLite can checkpoint newer pages into the main file. For a consistent same-time pair use the latest-snapshot commands below. Input sizes for the CLI are limited to 64 MiB per file. [SQLite WAL format](https://sqlite.org/walformat.html) · [Snapshot details](docs/wal-timeline.md)

From MoonBit, open the capture once with `open_wal_timeline(base, wal)`. Use `commits()` to list revisions, `snapshot(revision)` to open one, `scan_table(name)` to read its stored rows and `diff_revisions(before, after, name)` to compare two revisions with matching table definitions. `page_origin(page)` gives the underlying byte location for a logical page in a revision.

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

## Reproduce verification

```sh
moon test --target js --frozen
moon build --target js --frozen
python scripts/sqlite_oracle.py
```

The oracle checks 6,012 legacy table, index and `WITHOUT ROWID` records across three page sizes and three encodings. It compares rowid lookups and pagination with SQLite queries, including signed 64-bit boundaries, and checks malformed pages and backup differences. The WAL cases check five historical views, six revision pairs, page provenance against raw SQLite cell bytes, truncation and regrowth, partially written or invalid tails, and valid uncommitted frames. [SQLite file format](https://sqlite.org/fileformat2.html)

After building the CLI, `python scripts/benchmark.py` measures latest WAL loading, backup comparison and point lookup. Add `--history` to also measure indexing 12,000 commits. Pass `--baseline /path/to/main.js` to compare two builds on the WAL and backup inputs.

## Source and license

MoonSQLite Inspect and the MoonSQLiteFile 0.8.1 dependency use Apache-2.0. The project builds on the upstream public APIs. Its own timeline indexes page lifetimes across all available revisions, compares stored rows and reports version-specific cell provenance. The SQLite engine is used by the demo and verification scripts. [Upstream release](https://github.com/prowk/MoonSQLiteFile/releases/tag/v0.8.1) · [Hackathon review and acceptance notes](docs/hackathon-review.md)
