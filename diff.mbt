///|
pub(all) enum RowChange {
  Added(Row)
  Removed(Row)
  Changed(Row, Row)
}

///|
priv enum StoredChange[R] {
  RowAdded(R)
  RowRemoved(R)
  RowChanged(R, R)
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
  merge_stored_rows(() => old.next(), () => new.next(), row => row, change => {
    changes.push(
      match change {
        RowAdded(row) => RowChange::Added(row)
        RowRemoved(row) => RowChange::Removed(row)
        RowChanged(left, right) => RowChange::Changed(left, right)
      },
    )
  })
  changes
}

///|
fn[R] merge_stored_rows(
  before : () -> R? raise InspectError,
  after : () -> R? raise InspectError,
  row : (R) -> Row,
  emit : (StoredChange[R]) -> Unit,
) -> Unit raise InspectError {
  let mut old_row = before()
  let mut new_row = after()
  while (old_row, new_row) is (Some(old), Some(new)) {
    let left = row(old)
    let right = row(new)
    if left.rowid < right.rowid {
      emit(RowRemoved(old))
      old_row = before()
    } else if left.rowid > right.rowid {
      emit(RowAdded(new))
      new_row = after()
    } else {
      if left.values != right.values {
        emit(RowChanged(old, new))
      }
      old_row = before()
      new_row = after()
    }
  }
  while old_row is Some(old) {
    emit(RowRemoved(old))
    old_row = before()
  }
  while new_row is Some(new) {
    emit(RowAdded(new))
    new_row = after()
  }
}
