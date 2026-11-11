# MoonSQLite Inspect

Read the stored records of an offline SQLite snapshot in pure MoonBit. The library consumes bytes directly and exposes the catalog, table and index records with physical page and cell locations. The optional WAL reader verifies the frame salts and cumulative checksums, then overlays only frames through the last valid commit. The command-line tool uses Node.js for file input.

## Run the inspector

From this directory, build the CLI with `moon build --target js --frozen`. Use a stable offline copy. A database and its WAL must come from the same capture. The CLI reads the WAL explicitly. Omitting it shows the contents of the main image alone.

```sh
node _build/js/debug/build/cmd/main/main.js catalog backup.sqlite
node _build/js/debug/build/cmd/main/main.js table backup.sqlite samples
node _build/js/debug/build/cmd/main/main.js index backup.sqlite samples_n
node _build/js/debug/build/cmd/main/main.js table capture.sqlite samples --wal capture.wal
node _build/js/debug/build/cmd/main/main.js diff before.sqlite after.sqlite samples
node _build/js/debug/build/cmd/main/main.js wal-diff capture.sqlite samples --wal capture.wal
```

`index` also reads `WITHOUT ROWID` tables in their physical key order. `diff` compares signed rowids in tables with identical stored SQL definitions and reports added, removed and changed records. It walks the two tables row by row and retains the changes. `wal-diff` compares the main image with the committed snapshot reconstructed from its WAL. Each record includes the physical source location. JSON uses decimal strings for 64-bit integers and rowids and hexadecimal strings for blobs.

The reader supports UTF-8, UTF-16LE and UTF-16BE databases with SQLite page sizes from 512 through 65,536 bytes. It validates cell boundaries, freeblock chains and rowid ranges in the B-trees it visits. It returns the SQLite storage classes and field order from each physical record. For an `INTEGER PRIMARY KEY` alias, the key appears in `rowid` and its stored column remains NULL. SQL projections and schema-derived defaults belong to the query layer. The library caps each decoded record at 16 MiB and the CLI caps each input file at 64 MiB.

## Reproduce verification

```sh
moon test --target js --frozen
moon build --target js --frozen
python scripts/sqlite_oracle.py
```

The oracle generates files with Python's SQLite and compares 6,012 table, index and `WITHOUT ROWID` records across three page sizes and all three encodings. Other cases cover backup comparisons, WAL commits and tails, database truncation and regrowth, cell overlaps, freeblock loops and invalid rowid ranges. The reader follows the SQLite file format specification. [SQLite file format](https://sqlite.org/fileformat2.html)

After building the CLI, `python scripts/benchmark.py` measures elapsed time and peak process memory on a 12,000-commit WAL and two backups with 8,000 rows each. Pass `--baseline /path/to/main.js` to compare two builds on the same inputs. On one Windows run with Node.js 24.13.0 and SQLite 3.45.3, the median of five runs against `f026635` went from 565.0 ms to 137.1 ms for the WAL workload and from 187.9 MiB to 118.2 MiB peak RSS for the backup comparison.

The project is licensed under Apache-2.0.
