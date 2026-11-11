# MoonSQLite Inspect

Read the stored records of an offline SQLite snapshot in pure MoonBit. The library consumes bytes directly and exposes the catalog, table and index records with physical page and cell locations. The optional WAL reader verifies the frame salts and cumulative checksums, then overlays only frames through the last valid commit. The command-line tool uses Node.js for file input.

## Run the inspector

From this directory, build the CLI with `moon build --target js --frozen`. Use a stable offline copy. A database and its WAL must come from the same capture. The CLI reads the WAL explicitly. Omitting it shows the contents of the main image alone.

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

The oracle generates files with Python's SQLite and compares 6,012 table, index and `WITHOUT ROWID` records across three page sizes and all three encodings. It also compares rowid lookups and pagination with SQLite queries on a multi-level B-tree, including signed 64-bit boundary values and records visible through the WAL. Other cases cover backup comparisons, WAL commits and tails, database truncation and regrowth, cell overlaps, freeblock loops and invalid rowid ranges. The reader follows the SQLite file format specification. [SQLite file format](https://sqlite.org/fileformat2.html)

After building the CLI, `python scripts/benchmark.py` measures WAL loading, backup comparison and point lookup. Pass `--baseline /path/to/main.js` to compare two builds on the WAL and backup inputs. On one Windows run with Node.js 24.13.0 and SQLite 3.45.3, the median of five runs against `f026635` went from 565.0 ms to 137.1 ms for the 12,000-commit WAL workload and from 187.9 MiB to 118.2 MiB peak RSS for the backup comparison.

On the 8,000-row BLOB backup, `row` returned the same record as filtering the complete `table` output. In five runs on the same machine, the median CLI time was 75.2 ms for `row` and 4,202.5 ms for the full export, including JSON serialization and output.

The project is licensed under Apache-2.0.
