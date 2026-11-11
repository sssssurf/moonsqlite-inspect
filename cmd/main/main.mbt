///|
extern "js" fn read_file(path : String) -> Bytes? =
  #| (path) => {
  #|   const fs = require('node:fs');
  #|   try {
  #|     const fd = fs.openSync(path, fs.constants.O_RDONLY | (fs.constants.O_NONBLOCK || 0));
  #|     try {
  #|       const stat = fs.fstatSync(fd);
  #|       if (!stat.isFile() || stat.size > 64 * 1024 * 1024) return null;
  #|       const bytes = new Uint8Array(stat.size + 1);
  #|       let length = 0;
  #|       while (length < bytes.length) {
  #|         const read = fs.readSync(fd, bytes, length, bytes.length - length, null);
  #|         if (read === 0) break;
  #|         length += read;
  #|       }
  #|       return length === stat.size ? bytes.subarray(0, length) : null;
  #|     } finally {
  #|       fs.closeSync(fd);
  #|     }
  #|   } catch {
  #|     return null;
  #|   }
  #| }

///|
extern "js" fn fail(message : String) -> Unit =
  #| (message) => { console.error(message); process.exitCode = 2; }

///|
priv suberror CliError {
  CliError(String)
}

///|
fn load(path : String) -> Bytes raise CliError {
  guard read_file(path) is Some(bytes) else {
    raise CliError(
      "Cannot read a stable regular file up to 64 MiB at \{Json(path).stringify()}",
    )
  }
  bytes
}

///|
fn value_json(value : @inspect.Value) -> Json {
  match value {
    Null => { "type": "null" }
    Integer(number) => { "type": "integer", "value": number.to_string() }
    Real(number) => { "type": "real", "value": number.to_string() }
    Text(text) => { "type": "text", "value": text }
    Blob(bytes) => { "type": "blob", "value": @hex.encode(bytes[:]) }
  }
}

///|
fn row_json(row : @inspect.Row) -> Json {
  {
    "rowid": row.rowid.to_string(),
    "page": row.page,
    "cell_offset": row.cell_offset,
    "values": row.values.map(value_json),
  }
}

///|
fn diff_json(
  before : @inspect.Snapshot,
  after : @inspect.Snapshot,
  name : String,
) -> Json raise {
  let changes = @inspect.diff_table(before, after, name).map(fn(
    change,
  ) -> Json {
    match change {
      Added(row) => { "kind": "added", "after": row_json(row) }
      Removed(row) => { "kind": "removed", "before": row_json(row) }
      Changed(old, new) =>
        { "kind": "changed", "before": row_json(old), "after": row_json(new) }
    }
  })
  {
    "entries": changes,
    "wal_frames_applied": after.wal_frames_applied,
    "wal_tail_bytes": after.wal_tail_bytes,
  }
}

///|
fn run(args : ArrayView[String]) -> Json raise {
  if args is ["diff", before, after, name] {
    return diff_json(
      @inspect.open_snapshot(load(before)),
      @inspect.open_snapshot(load(after)),
      name,
    )
  }
  if args is ["wal-diff", path, name, "--wal", wal] {
    let main = load(path)
    return diff_json(
      @inspect.open_snapshot(main),
      @inspect.open_snapshot(main, wal=load(wal)),
      name,
    )
  }
  let (command, db_path, name, wal_path) = match args {
    ["catalog", path] => ("catalog", path, "", None)
    ["catalog", path, "--wal", wal] => ("catalog", path, "", Some(wal))
    ["table" as command, path, name] | ["index" as command, path, name] =>
      (command, path, name, None)
    ["table" as command, path, name, "--wal", wal]
    | ["index" as command, path, name, "--wal", wal] =>
      (command, path, name, Some(wal))
    _ =>
      raise CliError(
        "Usage: moonsqlite-inspect catalog DB [--wal WAL] | (table|index) DB NAME [--wal WAL] | diff BEFORE AFTER NAME | wal-diff DB NAME --wal WAL",
      )
  }
  let main = load(db_path)
  let wal = match wal_path {
    None => None
    Some(path) => Some(load(path))
  }
  let snapshot = @inspect.open_snapshot(main, wal?)
  let entries : Json = match command {
    "catalog" =>
      Json(
        snapshot
        .catalog()
        .map(fn(entry) -> Json {
          let sql : Json = match entry.sql {
            Some(value) => Json(value)
            None => Json::null()
          }
          {
            "kind": entry.kind,
            "name": entry.name,
            "table": entry.table,
            "root_page": entry.root_page,
            "sql": sql,
          }
        }),
      )
    "table" => Json(snapshot.scan_table(name).map(row_json))
    _ =>
      Json(
        snapshot
        .scan_index(name)
        .map(fn(record) -> Json {
          {
            "page": record.page,
            "cell_offset": record.cell_offset,
            "values": record.values.map(value_json),
          }
        }),
      )
  }
  {
    "page_size": snapshot.page_size,
    "page_count": snapshot.page_count,
    "text_encoding": snapshot.text_encoding(),
    "wal_frames_applied": snapshot.wal_frames_applied,
    "wal_tail_bytes": snapshot.wal_tail_bytes,
    "entries": entries,
  }
}

///|
fn main {
  println(run(@env.args()[2:]).stringify()) catch {
    CliError(message) => fail(message)
    @inspect.InspectError::Invalid(message) => fail("Invalid: \{message}")
    @inspect.InspectError::Unsupported(message) =>
      fail("Unsupported: \{message}")
    @inspect.InspectError::NotFound(name) =>
      fail("NotFound: table \{Json(name).stringify()}")
    error => fail(error.to_string())
  }
}
