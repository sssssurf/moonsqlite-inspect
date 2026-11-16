///|
fn parse_revision(value : String) -> Int32 raise CliError {
  let revision = @string.parse_int(value, base=10) catch {
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
fn changes_json(
  before : @inspect.WalRevision,
  after : @inspect.WalRevision,
  name : String,
) -> Json raise @inspect.InspectError {
  let changes = @inspect.diff_revisions(before, after, name).map(fn(
    change,
  ) -> Json {
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
  })
  {
    "from": commit_json(before.info),
    "to": commit_json(after.info),
    "entries": changes,
  }
}
