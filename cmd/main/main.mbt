///|
extern "js" fn read_file(path : String, limit : Int32) -> Bytes? =
  #| (path, limit) => {
  #|   const fs = require('node:fs');
  #|   try {
  #|     const fd = fs.openSync(path, fs.constants.O_RDONLY | (fs.constants.O_NONBLOCK || 0));
  #|     try {
  #|       const stat = fs.fstatSync(fd, { bigint: true });
  #|       if (!stat.isFile() || stat.size > BigInt(limit)) return null;
  #|       const size = Number(stat.size);
  #|       const bytes = new Uint8Array(size);
  #|       let length = 0;
  #|       while (length < bytes.length) {
  #|         const read = fs.readSync(fd, bytes, length, bytes.length - length, null);
  #|         if (read === 0) break;
  #|         length += read;
  #|       }
  #|       const after = fs.fstatSync(fd, { bigint: true });
  #|       return length === size && after.size === stat.size &&
  #|         after.mtimeNs === stat.mtimeNs && after.ctimeNs === stat.ctimeNs ? bytes : null;
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
  guard read_file(path, 64 * 1024 * 1024) is Some(bytes) else {
    raise CliError(
      "Cannot read a stable regular file up to 64 MiB at \{Json(path).stringify()}",
    )
  }
  bytes
}

///|
extern "js" fn blob_hex(data : Bytes) -> String =
  #| (bytes) => Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString('hex')

///|
fn load_snapshot(path : String, wal_path : String?) -> @inspect.Snapshot raise {
  let main = load(path)
  let wal = match wal_path {
    None => None
    Some(path) => Some(load(path))
  }
  @inspect.open_snapshot(main, wal?)
}

///|
fn wal_option(options : ArrayView[String]) -> String? raise CliError {
  match options {
    [] => None
    ["--wal", path] => Some(path)
    _ => raise CliError("Expected an optional --wal WAL argument")
  }
}

///|
fn decimal_input(value : String) -> StringView raise CliError {
  let unsigned = match value[:] {
    ['+' | '-', .. rest] => rest
    rest => rest
  }
  guard !(unsigned is ['0', 'x' | 'X' | 'o' | 'O' | 'b' | 'B', ..]) else {
    raise CliError("Expected a decimal integer")
  }
  value[:]
}

///|
fn parse_rowid(value : String) -> Int64 raise CliError {
  @string.parse_int64(decimal_input(value)) catch {
    _ =>
      raise CliError(
        "Expected a signed 64-bit decimal rowid, got \{Json(value).stringify()}",
      )
  }
}

///|
fn parse_limit(
  value : String,
  label~ : String = "row limit",
) -> Int32 raise CliError {
  let limit = @string.parse_int(decimal_input(value)) catch {
    _ =>
      raise CliError(
        "Expected a positive 32-bit decimal \{label}, got \{Json(value).stringify()}",
      )
  }
  guard limit > 0 else { raise CliError("The \{label} must be positive") }
  limit
}

///|
fn value_json(value : @inspect.Value) -> Json {
  match value {
    Null => { "type": "null" }
    Integer(number) => { "type": "integer", "value": number.to_string() }
    Real(number) => { "type": "real", "value": number.to_string() }
    Text(text) => { "type": "text", "value": text }
    Blob(bytes) => { "type": "blob", "value": blob_hex(bytes) }
  }
}

///|
fn row_fields(row : @inspect.Row) -> Map[String, Json] {
  {
    "rowid": Json(row.rowid.to_string()),
    "page": Json(row.page),
    "cell_offset": Json(row.cell_offset),
    "values": Json(row.values.map(value_json)),
  }
}

///|
fn row_json(row : @inspect.Row) -> Json {
  Json(row_fields(row))
}

///|
fn snapshot_fields(
  snapshot : @inspect.Snapshot,
  entries : Json,
) -> Map[String, Json] {
  {
    "page_size": Json(snapshot.page_size),
    "page_count": Json(snapshot.page_count),
    "text_encoding": Json(snapshot.text_encoding()),
    "wal_frames_applied": Json(snapshot.wal_frames_applied),
    "wal_tail_bytes": Json(snapshot.wal_tail_bytes),
    "entries": entries,
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
  if args is ["wal-history", base, wal, .. options] {
    return history_json(load_timeline(base, wal, manifest_option(options)))
  }
  if args is ["wal-verify", base, wal, manifest] {
    return {
      "manifest_verified": true,
      "timeline": history_json(load_timeline(base, wal, Some(manifest))),
    }
  }
  if args is ["wal-rows", base, wal, revision, name, .. options] {
    let number = parse_revision(revision)
    let timeline = load_timeline(base, wal, manifest_option(options))
    let snapshot = timeline.snapshot(number)
    return {
      "revision": commit_json(snapshot.info),
      "entries": snapshot.scan_table(name).map(versioned_row_json),
    }
  }
  if args is ["wal-changes", base, wal, before, after, name, .. options] {
    let from = parse_revision(before)
    let to = parse_revision(after)
    let timeline = load_timeline(base, wal, manifest_option(options))
    return changes_json(timeline.snapshot(from), timeline.snapshot(to), name)
  }
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
  if args is ["row", path, name, key, .. options] {
    let rowid = parse_rowid(key)
    let snapshot = load_snapshot(path, wal_option(options))
    let entries : Array[Json] = match snapshot.find_row(name, rowid) {
      Some(row) => [row_json(row)]
      None => []
    }
    return Json(snapshot_fields(snapshot, Json(entries)))
  }
  if args is ["range", path, name, first, last, limit, .. options] {
    let first = parse_rowid(first)
    let last = parse_rowid(last)
    let limit = parse_limit(limit)
    let snapshot = load_snapshot(path, wal_option(options))
    let page = snapshot.scan_rowid_range(name, first, last, limit~)
    let fields = snapshot_fields(snapshot, Json(page.rows.map(row_json)))
    fields["next_rowid"] = match page.next_rowid {
      Some(rowid) => Json(rowid.to_string())
      None => Json::null()
    }
    return Json(fields)
  }
  let (command, db_path, name, wal_path) = match args {
    ["catalog", path] => ("catalog", path, "", None)
    ["catalog", path, "--wal", wal] => ("catalog", path, "", Some(wal))
    ["table" as command, path, name] | ["index" as command, path, name] =>
      (command, path, name, None)
    ["table" as command, path, name, "--wal", wal]
    | ["index" as command, path, name, "--wal", wal] =>
      (command, path, name, Some(wal))
    _ => {
      let usage =
        #| Usage: moonsqlite-inspect COMMAND
        #|   wal-history BASE WAL [--manifest FILE]
        #|   wal-rows BASE WAL REVISION TABLE [--manifest FILE]
        #|   wal-changes BASE WAL FROM TO TABLE [--manifest FILE]
        #|   wal-series BASE WAL FROM TO TABLE [--limit COMMITS] [--manifest FILE]
        #|   wal-verify BASE WAL MANIFEST
        #|   catalog DB [--wal WAL]
        #|   (table|index) DB NAME [--wal WAL]
        #|   row DB NAME ROWID [--wal WAL]
        #|   range DB NAME FIRST LAST LIMIT [--wal WAL]
        #|   diff BEFORE AFTER NAME
        #|   wal-diff DB NAME --wal WAL
      raise CliError(usage)
    }
  }
  let snapshot = load_snapshot(db_path, wal_path)
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
  Json(snapshot_fields(snapshot, entries))
}

///|
fn run_text(args : ArrayView[String]) -> String raise {
  match args {
    ["wal-series", base, wal, from, to, name, .. options] => {
      let (limit, manifest) = series_options(options)
      let timeline = load_timeline(base, wal, manifest)
      series_json(
        timeline,
        name,
        parse_revision(from),
        parse_revision(to),
        limit,
      )
    }
    _ => run(args).stringify()
  }
}

///|
fn main {
  println(run_text(@env.args()[2:])) catch {
    CliError(message) => fail(message)
    @inspect.InspectError::Invalid(message) => fail("Invalid: \{message}")
    @inspect.InspectError::Unsupported(message) =>
      fail("Unsupported: \{message}")
    @inspect.InspectError::NotFound(name) =>
      fail("NotFound: table \{Json(name).stringify()}")
    error => fail(error.to_string())
  }
}
