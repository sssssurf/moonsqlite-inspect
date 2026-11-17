# SQLite WAL timeline

## Capture contract

The library opens one pre-WAL baseline and one immutable WAL from the same database. The baseline must contain the state after a successful truncate checkpoint and before the first write represented by the captured WAL. `scripts/wal_capture.py` establishes that baseline from a caller-owned file-backed WAL connection. It disables automatic checkpoints for the session, finishes a truncate checkpoint and opens a second connection's read transaction before releasing the write lock. The reader pins the main-file view while the caller commits the workload. The helper takes the WAL copy while holding a new write lock and restores the caller's autocheckpoint setting when the session ends.

Use the helper with an idle SQLite writer and export between transactions. Run the example from the `scripts` directory or make the helper importable in the workload.

```python
from pathlib import Path
from wal_capture import capture_wal

with capture_wal(connection) as capture:
    connection.execute("UPDATE status SET message='waiting' WHERE rowid=41")
    connection.commit()
    capture.export(Path("capture"))
```

The bundle contains `baseline.sqlite`, `capture.wal` and `capture.json`. The manifest records capture order, each file's size and SHA-256 digest, and the WAL header epoch. The epoch is the hexadecimal encoding of the checkpoint sequence and both salts. It is `null` for an empty WAL. Keep the manifest produced by the capture process with the artifacts to verify the same bytes later.

SQLite's frame checksums establish WAL continuity. The pinned read transaction establishes input pairing and order at capture time. A later checkpoint can copy newer pages into the main file while older WAL frames are still present, so raw input pairs require the same baseline capture procedure. [SQLite WAL locking](https://sqlite.org/walformat.html#wal_locks) · [Checkpoint algorithm](https://sqlite.org/fileformat2.html#checkpoint_algorithm)

## How a revision is constructed

1. MoonSQLiteFile validates the baseline header and the WAL frame prefix. Its inspection API returns frame locations and complete commit boundaries. Revision 0 is the baseline. Each complete boundary in the prefix becomes one subsequent revision.
2. An index records each page's WAL versions and which revision supersedes each version. When a commit truncates the database, a max-heap identifies overlay pages beyond the new end. A main-file page beyond that end also stops being usable as a fallback. Every new page after growth must be covered by the WAL before the commit is exposed.
3. A read binary-searches the requested page's versions and resolves the latest version still visible at the chosen revision. It can then supply exact byte ranges to the upstream B-tree and overflow reader. The range view supplies the commit page count in a transient copy of the page 1 header. The input files and cell bytes stay intact.
4. For a rowid table, two forward cursors compare full stored values by signed 64-bit rowid. Each JSON change carries the appropriate before and after records. The package materializes the changed records, while the cursors read pages and records as needed.

The index stores metadata proportional to the number of validated frames and commits. Opening another revision reuses it. JSON for a row contains its cell page number and in-page offset. Adding the cell offset to `source.page_offset` locates the cell in the corresponding source. `source.revision` is the revision in which that page version was written. A transaction may write a page without changing a particular row on it. A row can span overflow pages whose origins differ from the cell origin.

## Export adjacent changes

`WalTimeline::visit_adjacent_changes` traverses adjacent commit pairs in a range. It records the pages used by the last successful scan, including the header, schema, B-tree and overflow payloads. When the next commit keeps the same database size and its WAL frames touch none of those pages, the visitor emits an empty comparison without scanning that table again. Page count changes or writes to a referenced page trigger a fresh comparison.

Consumers can stream each change as it arrives. A pair starts with `CommitStarted` and becomes complete at `CommitFinished`. Returning `false` from the consumer stops the visitor and returns `false` to the caller. The CLI buffers its bounded JSON response until all comparisons in that response finish, so a read or budget error returns an error without a partial JSON document.

```moonbit
let complete = timeline.visit_adjacent_changes("status", from=0, to=3, event => {
  match event {
    CommitStarted(_, after) => println("revision \{after.revision}")
    CommitChange(Added(row)) => println("added \{row.row.rowid}")
    CommitChange(Removed(row)) => println("removed \{row.row.rowid}")
    CommitChange(Changed(_, row)) => println("changed \{row.row.rowid}")
    CommitFinished(_) => ()
  }
  true
})
```

## Boundaries

- Historical table reads cover ordinary rowid tables and raw SQLite storage values. Row comparison requires equal stored table definitions at both endpoints. Changes across endpoints describe those observed records. SQL statements, transaction timestamps and writer identity are outside the file model.
- The end of the usable history is the last complete commit before the first invalid or incomplete frame. `wal-history` reports the stop reason and offset, valid and committed frame counts, and bytes after the committed prefix. A valid but uncommitted tail stays outside the history. Exceeding the frame budget fails the open operation.
- The library accepts byte arrays and uses upstream default row, page and payload budgets. The CLI limits input files to 64 MiB each. This interface deals with offline snapshots. For a stable same-time database/WAL capture, `table --wal` reads the latest snapshot.
