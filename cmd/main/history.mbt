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
  let head = "{\"revision\":\{commit_json(snapshot.info).stringify()},\"entries\":["
  let complete = out.append(head) &&
    snapshot.visit_table(name, row => {
      let separator = first || out.append(",")
      first = false
      separator && out.append_row(row)
    })
  guard complete && out.append("]}") else {
    raise CliError(
      "WAL rows exceed the 8 MiB output budget; use WalRevision::visit_table",
    )
  }
  out.text.to_string()
}
