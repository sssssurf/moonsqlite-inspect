# SQLite WAL timeline

## Capture contract

The library opens one pre-WAL baseline and one immutable WAL from the same database. The baseline must contain the state immediately after a successful truncate checkpoint and before the first write represented by the captured WAL. Leave SQLite open with automatic checkpoints disabled, prevent other connections from checkpointing or resetting the WAL, and take the WAL copy while there is no write in progress. The demo script implements this sequence with a single connection.

The checksum establishes the continuity of frames in the WAL. The capture procedure establishes the pairing and order of the two inputs. A later checkpoint can write a newer page into the main file even when the WAL still contains older commits. Frame validation alone cannot establish which main-file bytes existed before that checkpoint. [SQLite WAL file format](https://sqlite.org/walformat.html) · [Checkpoint algorithm](https://sqlite.org/fileformat2.html#checkpoint_algorithm)

## How a revision is constructed

1. MoonSQLiteFile validates the baseline header and the WAL frame prefix. Its inspection API returns frame locations and complete commit boundaries. Revision 0 is the baseline. Each complete boundary in the prefix becomes one subsequent revision.
2. An index records each page's WAL versions and which revision supersedes each version. When a commit truncates the database, a max-heap identifies overlay pages beyond the new end. A main-file page beyond that end also stops being usable as a fallback. Every new page after growth must be covered by the WAL before the commit is exposed.
3. A read binary-searches the requested page's versions and resolves the latest version still visible at the chosen revision. It can then supply exact byte ranges to the upstream B-tree and overflow reader. The range view supplies the commit page count in a transient copy of the page 1 header. The input files and cell bytes stay intact.
4. For a rowid table, two forward cursors compare full stored values by signed 64-bit rowid. Each JSON change carries the appropriate before and after records. The package materializes the changed records, while the cursors read pages and records as needed.

The index stores metadata proportional to the number of validated frames and commits. Opening another revision reuses it. JSON for a row contains its cell page number and in-page offset. Adding the cell offset to `source.page_offset` locates the cell in the corresponding source. `source.revision` is the revision in which that page version was written. A transaction may write a page without changing a particular row on it. A row can span overflow pages whose origins differ from the cell origin.

## Boundaries

- Historical table reads cover ordinary rowid tables and raw SQLite storage values. Row comparison requires equal stored table definitions at both endpoints. Changes across endpoints describe those observed records. SQL statements, transaction timestamps and writer identity are outside the file model.
- The end of the usable history is the last complete commit before the first invalid or incomplete frame. `wal-history` reports the stop reason and offset, valid and committed frame counts, and bytes after the committed prefix. A valid but uncommitted tail stays outside the history. Exceeding the frame budget fails the open operation.
- The library accepts byte arrays and uses upstream default row, page and payload budgets. The CLI limits input files to 64 MiB each. This interface deals with offline snapshots. For a stable same-time database/WAL capture, `table --wal` reads the latest snapshot.
