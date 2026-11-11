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

`index` also reads `WITHOUT ROWID` tables in their physical key order. `diff` compares signed rowids in tables with identical stored SQL definitions and reports added, removed and changed records. `wal-diff` compares the main image with the committed snapshot reconstructed from its WAL. Each record includes the physical source location. JSON uses decimal strings for 64-bit integers and rowids and hexadecimal strings for blobs.

The reader supports UTF-8 databases with SQLite page sizes from 512 through 65,536 bytes. It returns the SQLite storage classes and field order from each physical record. For an `INTEGER PRIMARY KEY` alias, the key appears in `rowid` and its stored column remains NULL. SQL projections and schema-derived defaults belong to the query layer. The library reads stable snapshots and implements the main file and WAL paths. The CLI caps each input file at 64 MiB and each decoded record at 16 MiB.

## Reproduce verification

```sh
moon test --target js --frozen
moon build --target js --frozen
python scripts/sqlite_oracle.py
```

The oracle generates real files with Python's SQLite, compares all 2,004 table, index and `WITHOUT ROWID` records across 512, 4,096 and 65,536 byte pages, and checks the schema catalog. Separate fixtures compare backups, verify that uncommitted and partial WAL tails stay outside the recovered snapshot, and confirm that invalid page pointers and header checksums produce diagnostic errors. SQLite is used by the test oracle. The MoonBit library implements the file reader from the [SQLite file format specification](https://sqlite.org/fileformat2.html).

The project is licensed under Apache-2.0.
