///|
pub(all) enum RowChange {
  Added(Row)
  Removed(Row)
  Changed(Row, Row)
}

///|
/// Compare stored rowid-table records. The two catalog definitions must match.
pub fn diff_table(
  before : Snapshot,
  after : Snapshot,
  name : String,
) -> Array[RowChange] raise InspectError {
  let before_entry = before.table_entry(name)
  let after_entry = after.table_entry(name)
  guard before_entry.sql is Some(old_sql) && after_entry.sql == Some(old_sql) else {
    raise Unsupported("table definitions differ between snapshots")
  }
  let old = before.scan_root(before_entry.root_page)
  let new = after.scan_root(after_entry.root_page)
  let changes = []
  let mut i = 0
  let mut j = 0
  while i < old.length() && j < new.length() {
    let left = old[i]
    let right = new[j]
    if left.rowid < right.rowid {
      changes.push(Removed(left))
      i += 1
    } else if left.rowid > right.rowid {
      changes.push(Added(right))
      j += 1
    } else {
      if left.values != right.values {
        changes.push(Changed(left, right))
      }
      i += 1
      j += 1
    }
  }
  for index in i..<old.length() {
    changes.push(Removed(old[index]))
  }
  for index in j..<new.length() {
    changes.push(Added(new[index]))
  }
  changes
}
