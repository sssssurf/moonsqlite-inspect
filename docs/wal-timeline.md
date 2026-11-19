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
4. For a rowid table, two forward cursors compare full stored values by signed 64-bit rowid. Each JSON change carries the appropriate before and after records. Visitors deliver one row or change at a time. The array-returning APIs collect those results when the caller needs them.

The index stores metadata proportional to the number of validated frames and commits. Opening another revision reuses it. JSON for a row contains its cell page number and in-page offset. Adding the cell offset to `source.page_offset` locates the cell in the corresponding source. `source.revision` is the revision in which that page version was written. A transaction may write a page without changing a particular row on it. A row can span overflow pages whose origins differ from the cell origin.

## Visit historical rows and arbitrary pairs

`WalRevision::visit_table(name, emit)` visits stored rows in signed rowid order. `visit_revision_changes(before, after, name, emit)` uses the same merge as `diff_revisions`, including nonadjacent and reverse endpoints. Both return `true` only after reaching the end. Returning `false` from the callback stops immediately, without decoding another row, and makes the visitor return `false`.

```moonbit
let before = timeline.snapshot(0)
let after = timeline.snapshot(3)
let complete = @inspect.visit_revision_changes(before, after, "status", change => {
  match change {
    Added(row) => println("added \{row.row.rowid}")
    Removed(row) => println("removed \{row.row.rowid}")
    Changed(_, row) => println("changed \{row.row.rowid}")
  }
  true
})
```

A callback can observe a valid prefix before a later read or decoding error. Consumers writing an artifact should stage their output and commit it only after a `true` result. Cancellation intentionally leaves later records unchecked. `scan_table` and `diff_revisions` collect the complete scan and raise if it fails.

The CLI stages JSON for `wal-rows`, `wal-changes` and `wal-series` in a shared 8 MiB response budget, measured in UTF-8 bytes including the final newline. It checks BLOB expansion before hexadecimal encoding and accounts for JSON escapes when appending. Exceeding the limit or encountering a later invalid record returns exit code 2, a diagnostic on standard error and no standard output. Use the visitors for a larger individual result. Record, scan and input limits still apply.

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
- The library accepts byte arrays. Historical scans inherit the upstream limits of 100,000 rows and pages, 16 MiB per record, 64 MiB of payload per table scan and depth 64. The WAL frame budget defaults to 100,000 and is configurable through `open_wal_timeline`. Hitting a limit fails the operation. The CLI accepts 64 MiB per database or WAL file and an 8 KiB manifest. For a stable same-time database/WAL capture, `table --wal` reads the latest snapshot.
