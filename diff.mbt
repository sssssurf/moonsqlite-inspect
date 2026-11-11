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
  let old = before.table_cursor(before_entry.root_page)
  let new = after.table_cursor(after_entry.root_page)
  let changes = []
  let mut old_row = old.next()
  let mut new_row = new.next()
  while (old_row, new_row) is (Some(left), Some(right)) {
    if left.rowid < right.rowid {
      changes.push(Removed(left))
      old_row = old.next()
    } else if left.rowid > right.rowid {
      changes.push(Added(right))
      new_row = new.next()
    } else {
      if left.values != right.values {
        changes.push(Changed(left, right))
      }
      old_row = old.next()
      new_row = new.next()
    }
  }
  while old_row is Some(row) {
    changes.push(Removed(row))
    old_row = old.next()
  }
  while new_row is Some(row) {
    changes.push(Added(row))
    new_row = new.next()
  }
  changes
}
