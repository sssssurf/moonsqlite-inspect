///|
/// The origin refers to the B-tree cell page, which may point to overflow pages.
pub(all) struct VersionedRow {
  row : Row
  origin : PageOrigin
}

///|
pub(all) enum VersionedChange {
  Added(VersionedRow)
  Removed(VersionedRow)
  Changed(VersionedRow, VersionedRow)
}

///|
priv struct RevisionCursor {
  snapshot : WalRevision
  cursor : @sqlite.BTreeCursor
}

///|
fn WalRevision::table_entry(
  self : WalRevision,
  name : String,
) -> @sqlite.SchemaEntry raise InspectError {
  let entries = self.database.schema() catch {
    error => raise inspect_error(error)
  }
  for entry in entries {
    if entry.object_type == "table" && entry.name == name {
      guard entry.root_page > 0 else {
        raise Unsupported("table has no stored B-tree")
      }
      return entry
    }
  }
  raise NotFound(name)
}

///|
fn WalRevision::table_cursor(
  self : WalRevision,
  root_page : Int32,
) -> RevisionCursor raise InspectError {
  let cursor = self.database.scan_cursor(root_page, table_only=true) catch {
    error => raise inspect_error(error)
  }
  { snapshot: self, cursor, }
}

///|
fn stored_value(value : @sqlite.Value) -> Value {
  match value {
    Null => Null
    Integer(number) => Integer(number)
    Real(number) => Real(number)
    Text(text) => Text(text)
    Blob(bytes) => Blob(bytes)
  }
}

///|
fn RevisionCursor::next(
  self : RevisionCursor,
) -> VersionedRow? raise InspectError {
  while true {
    let event = self.cursor.next() catch { error => raise inspect_error(error) }
    match event {
      NeedPage(page) =>
        self.cursor.provide_page(page, self.snapshot.database.read_page(page)) catch {
          error => raise inspect_error(error)
        }
      RecordReady(record) => {
        guard record.rowid is Some(rowid) else {
          raise Unsupported("historical row scans require a rowid table")
        }
        let origin = self.snapshot.page_origin(record.page_number)
        return Some({
          row: {
            rowid,
            values: record.values.map(stored_value),
            page: record.page_number,
            cell_offset: record.cell_offset,
          },
          origin,
        })
      }
      ScanFinished(summary) => {
        guard summary.completion is Complete else {
          raise Unsupported("historical row scan exceeded its record budget")
        }
        return None
      }
    }
  } nobreak {
    abort("historical scan ended without a result")
  }
}

///|
/// Read the stored records of a rowid table in this revision, with cell origins.
pub fn WalRevision::scan_table(
  self : WalRevision,
  name : String,
) -> Array[VersionedRow] raise InspectError {
  let cursor = self.table_cursor(self.table_entry(name).root_page)
  let rows = []
  while cursor.next() is Some(row) {
    rows.push(row)
  }
  rows
}

///|
/// Compare two historical views by signed rowid and stored values.
/// Both endpoints must have the same stored table definition.
pub fn diff_revisions(
  before : WalRevision,
  after : WalRevision,
  name : String,
) -> Array[VersionedChange] raise InspectError {
  let before_entry = before.table_entry(name)
  let after_entry = after.table_entry(name)
  guard before_entry.sql is Some(sql) && after_entry.sql == Some(sql) else {
    raise Unsupported("table definitions differ between revisions")
  }
  let old = before.table_cursor(before_entry.root_page)
  let new = after.table_cursor(after_entry.root_page)
  let changes = []
  merge_stored_rows(() => old.next(), () => new.next(), row => row.row, change => {
    changes.push(
      match change {
        RowAdded(row) => VersionedChange::Added(row)
        RowRemoved(row) => VersionedChange::Removed(row)
        RowChanged(left, right) => VersionedChange::Changed(left, right)
      },
    )
  })
  changes
}
