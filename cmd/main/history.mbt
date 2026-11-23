///|
fn parse_revision(value : String) -> Int32 raise CliError {
  let revision = @string.parse_int(decimal_input(value)) catch {
    _ =>
      raise CliError(
        "Expected a nonnegative revision, got \{Json(value).stringify()}",
      )
  }
  guard revision >= 0 else {
    raise CliError("The revision must be nonnegative")
  }
  revision
}

///|
fn commit_json(commit : @inspect.WalCommit) -> Json {
  {
    "revision": commit.revision,
    "first_frame": commit.first_frame,
    "last_frame": commit.last_frame,
    "page_count": commit.page_count,
  }
}

///|
fn versioned_row_json(row : @inspect.VersionedRow) -> Json {
  let fields = row_fields(row.row)
  fields["source"] = match row.origin {
    MainPage(offset) => { "kind": "main", "page_offset": offset.to_string() }
    WalFrame(origin) =>
      {
        "kind": "wal",
        "frame": origin.frame,
        "revision": origin.revision,
        "page_offset": origin.offset.to_string(),
      }
  }
  Json(fields)
}

///|
fn history_json(timeline : @inspect.WalTimeline) -> Json {
  {
    "page_size": timeline.page_size,
    "valid_frames": timeline.valid_frames,
    "committed_frames": timeline.committed_frames,
    "ignored_wal_bytes": timeline.ignored_wal_bytes,
    "stop_offset": timeline.stop_offset.to_string(),
    "stop_reason": timeline.stop_reason,
    "commits": timeline.commits().map(commit_json),
  }
}

///|
fn versioned_change_json(change : @inspect.VersionedChange) -> Json {
  match change {
    Added(row) => { "kind": "added", "after": versioned_row_json(row) }
    Removed(row) => { "kind": "removed", "before": versioned_row_json(row) }
    Changed(old, new) =>
      {
        "kind": "changed",
        "before": versioned_row_json(old),
        "after": versioned_row_json(new),
      }
  }
}

///|
fn changes_text(
  before : @inspect.WalRevision,
  after : @inspect.WalRevision,
  name : String,
) -> String raise {
  let out = JsonOutput::new()
  let mut first = true
  let head = "{\"from\":\{commit_json(before.info).stringify()},\"to\":\{commit_json(after.info).stringify()},\"entries\":["
  let complete = out.append(head) &&
    @inspect.visit_revision_changes(before, after, name, change => {
      let separator = first || out.append(",")
      first = false
      separator && out.append_change(change)
    })
  guard complete && out.append("]}") else {
    raise CliError(
      "WAL changes exceed the 8 MiB output budget; use visit_revision_changes",
    )
  }
  out.text.to_string()
}

///|
fn rows_text(snapshot : @inspect.WalRevision, name : String) -> String raise {
  let out = JsonOutput::new()
  let mut first = true
  let complete = out.append(revision_rows_header(snapshot.info)) &&
    snapshot.visit_table(name, row => {
      let fits = out.append_row(row, comma=!first)
      first = false
      fits
    })
  guard complete && out.append("]}") else {
    raise CliError(
      "WAL rows exceed the 8 MiB output budget; use WalRevision::visit_table",
    )
  }
  out.text.to_string()
}

///|
fn revision_rows_header(commit : @inspect.WalCommit) -> String {
  "{\"revision\":\{commit_json(commit).stringify()},\"entries\":["
}

///|
fn row_at_text(
  snapshot : @inspect.WalRevision,
  name : String,
  key : Int64,
) -> String raise {
  let out = JsonOutput::new()
  ignore(out.append(revision_rows_header(snapshot.info)))
  let fits = match snapshot.find_row(name, key) {
    Some(row) => out.append_row(row, reserve=2)
    None => true
  }
  guard fits && out.append("]}") else {
    raise CliError(
      "WAL row exceeds the 8 MiB output budget; use WalRevision::find_row",
    )
  }
  out.text.to_string()
}

///|
fn row_range_text(
  snapshot : @inspect.WalRevision,
  name : String,
  first : Int64,
  last : Int64,
  limit : Int32,
) -> String raise {
  let out = JsonOutput::new()
  ignore(out.append(revision_rows_header(snapshot.info)))
  // Leave space for the closing JSON and the longest possible signed rowid.
  let reserve = "],\"next_rowid\":\"-9223372036854775808\"}".length()
  let mut has_rows = false
  let next = snapshot.visit_rowid_range(name, first, last, limit~, row => {
    let fits = out.append_row(row, comma=has_rows, reserve~)
    if fits {
      has_rows = true
    }
    fits
  })
  guard has_rows || next is None else {
    raise CliError(
      "WAL range row exceeds the 8 MiB output budget; use WalRevision::visit_rowid_range",
    )
  }
  let continuation = match next {
    Some(rowid) => "\"\{rowid}\""
    None => "null"
  }
  ignore(out.append("],\"next_rowid\":\{continuation}}"))
  out.text.to_string()
}
