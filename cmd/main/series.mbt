///|
fn series_options(
  options : ArrayView[String],
) -> (Int32, String?) raise CliError {
  let (limit, manifest) = match options {
    ["--limit", count, .. rest] =>
      (parse_limit(count, label="commit limit"), manifest_option(rest))
    ["--manifest", path, "--limit", count] =>
      (parse_limit(count, label="commit limit"), Some(path))
    _ => (32, manifest_option(options))
  }
  guard limit <= 1024 else {
    raise CliError("The commit limit must be at most 1024")
  }
  (limit, manifest)
}

///|
extern "js" fn utf8_byte_length(value : String) -> Int32 =
  #| (value) => Buffer.byteLength(value, 'utf8')

///|
// Avoid encoding a single large value that already exceeds the remaining budget.
fn minimum_row_bytes(row : @inspect.VersionedRow) -> Int32 {
  let mut size = 0
  for value in row.row.values {
    match value {
      Text(text) => size += utf8_byte_length(text)
      Blob(data) => size += 2 * data.length()
      _ => ()
    }
  }
  size
}

///|
fn minimum_change_bytes(change : @inspect.VersionedChange) -> Int32 {
  match change {
    Added(row) | Removed(row) => minimum_row_bytes(row)
    Changed(before, after) =>
      minimum_row_bytes(before) + minimum_row_bytes(after)
  }
}

///|
priv struct SeriesOutput {
  text : StringBuilder
  mut remaining : Int32
}

///|
fn SeriesOutput::append(self : SeriesOutput, value : String) -> Bool {
  let size = utf8_byte_length(value)
  guard size <= self.remaining else { return false }
  self.remaining -= size
  self.text.write_string(value)
  true
}

///|
fn series_json(
  timeline : @inspect.WalTimeline,
  name : String,
  from : Int32,
  to : Int32,
  limit : Int32,
) -> String raise {
  guard from <= to else {
    raise CliError("The first revision must be at most the last revision")
  }
  ignore(timeline.commit(to))
  let through = from + Int32::min(to - from, limit)
  let next_from = if through < to { through.to_string() } else { "null" }
  let out : SeriesOutput = {
    text: StringBuilder(),
    remaining: 8 * 1024 * 1024 - 1,
  }
  let head = "{\"from\":\{from},\"through\":\{through},\"requested_to\":\{to},\"next_from\":\{next_from},\"entries\":["
  let mut first_change = true
  let finished = out.append(head) &&
    timeline.visit_adjacent_changes(name, from~, to=through, event => {
      match event {
        CommitStarted(before, after) => {
          first_change = true
          (before.revision == from || out.append(",")) &&
          out.append(
            "{\"from\":\{commit_json(before).stringify()},\"to\":\{commit_json(after).stringify()},\"entries\":[",
          )
        }
        CommitChange(change) => {
          let separator = first_change || out.append(",")
          first_change = false
          separator &&
          minimum_change_bytes(change) <= out.remaining &&
          out.append(versioned_change_json(change).stringify())
        }
        CommitFinished(_) => out.append("]}")
      }
    })
  guard finished && out.append("]}") else {
    raise CliError("WAL series exceeds the 8 MiB output budget; reduce --limit")
  }
  out.text.to_string()
}
