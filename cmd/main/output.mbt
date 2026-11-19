///|
extern "js" fn utf8_byte_length(value : String) -> Int32 =
  #| (value) => Buffer.byteLength(value, 'utf8')

///|
// Reject oversized values before allocating a hexadecimal or JSON encoding.
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
priv struct JsonOutput {
  text : StringBuilder
  mut remaining : Int32
}

///|
fn JsonOutput::new() -> JsonOutput {
  // println adds one byte after the complete document.
  { text: StringBuilder(), remaining: 8 * 1024 * 1024 - 1, }
}

///|
fn JsonOutput::append(self : JsonOutput, value : String) -> Bool {
  let size = utf8_byte_length(value)
  guard size <= self.remaining else { return false }
  self.remaining -= size
  self.text.write_string(value)
  true
}

///|
fn JsonOutput::append_row(
  self : JsonOutput,
  row : @inspect.VersionedRow,
) -> Bool {
  minimum_row_bytes(row) <= self.remaining &&
  self.append(versioned_row_json(row).stringify())
}

///|
fn JsonOutput::append_change(
  self : JsonOutput,
  change : @inspect.VersionedChange,
) -> Bool {
  minimum_change_bytes(change) <= self.remaining &&
  self.append(versioned_change_json(change).stringify())
}
