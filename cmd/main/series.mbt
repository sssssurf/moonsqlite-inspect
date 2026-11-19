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
  let out = JsonOutput::new()
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
          separator && out.append_change(change)
        }
        CommitFinished(_) => out.append("]}")
      }
    })
  guard finished && out.append("]}") else {
    raise CliError("WAL series exceeds the 8 MiB output budget; reduce --limit")
  }
  out.text.to_string()
}
