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
        return Some(
          self.snapshot.with_origin({
            rowid,
            values: record.values.map(stored_value),
            page: record.page_number,
            cell_offset: record.cell_offset,
          }),
        )
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
fn WalRevision::with_origin(
  self : WalRevision,
  row : Row,
) -> VersionedRow raise InspectError {
  { row, origin: self.page_origin(row.page), }
}

///|
fn WalRevision::rowid_cursor(
  self : WalRevision,
  name : String,
  range : RowidRange,
) -> TableCursor raise InspectError {
  let root = self.table_entry(name).root_page
  let header = self.database.header()
  let encoding = match header.text_encoding {
    0 | 1 => Utf8
    2 => Utf16Le
    3 => Utf16Be
    _ => raise Unsupported("unknown SQLite text encoding")
  }
  let view : BtreeView = {
    read_page: number => {
      let bytes = self.database.read_page(number) catch {
        error => raise inspect_error(error)
      }
      bytes[:]
    },
    page_count: self.info.page_count,
    page_size: header.page_size,
    usable_size: header.usable_size,
    encoding,
  }
  view.table_cursor(root, range~)
}

///|
/// Seek one signed rowid in an ordinary table at this revision.
/// None means the key is absent. Only the lookup path and its payload are read.
pub fn WalRevision::find_row(
  self : WalRevision,
  name : String,
  rowid : Int64,
) -> VersionedRow? raise InspectError {
  let cursor = self.rowid_cursor(name, { first: rowid, last: rowid, })
  guard cursor.next() is Some(row) else { return None }
  Some(self.with_origin(row))
}

///|
/// Visit up to limit stored rows in an inclusive range in signed rowid order.
/// If accept returns false, the current row remains the first unaccepted key.
/// Use the returned key as the lower bound in the same revision and range.
/// None means the range is exhausted. Errors may follow earlier callbacks.
pub fn WalRevision::visit_rowid_range(
  self : WalRevision,
  name : String,
  first : Int64,
  last : Int64,
  limit~ : Int32,
  accept : (VersionedRow) -> Bool,
) -> Int64? raise InspectError {
  guard first <= last else {
    raise Invalid("the first rowid must be at most the last rowid")
  }
  guard limit > 0 else { raise Invalid("the row limit must be positive") }
  let cursor = self.rowid_cursor(name, { first, last, })
  for _ in 0..<limit {
    guard cursor.next() is Some(row) else { return None }
    if !accept(self.with_origin(row)) {
      return Some(row.rowid)
    }
  }
  cursor.peek_rowid()
}

///|
/// Visit stored rows in signed rowid order, with their cell origins.
/// Return false from emit to stop before reading another record. The result is
/// true only when the scan reaches its end; errors may follow earlier callbacks.
pub fn WalRevision::visit_table(
  self : WalRevision,
  name : String,
  emit : (VersionedRow) -> Bool,
) -> Bool raise InspectError {
  let cursor = self.table_cursor(self.table_entry(name).root_page)
  while cursor.next() is Some(row) {
    if !emit(row) {
      return false
    }
  }
  true
}

///|
/// Read the stored records of a rowid table in this revision, with cell origins.
pub fn WalRevision::scan_table(
  self : WalRevision,
  name : String,
) -> Array[VersionedRow] raise InspectError {
  let rows = []
  ignore(
    self.visit_table(name, row => {
      rows.push(row)
      true
    }),
  )
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
  let changes = []
  ignore(
    visit_revision_changes(before, after, name, change => {
      changes.push(change)
      true
    }),
  )
  changes
}

///|
/// Visit differences between any two historical views, in signed rowid order.
/// Both endpoints must have the same stored table definition. Returning false
/// stops the comparison immediately. A true result means both scans completed;
/// errors may follow earlier callbacks, so consumers must handle partial work.
pub fn visit_revision_changes(
  before : WalRevision,
  after : WalRevision,
  name : String,
  emit : (VersionedChange) -> Bool,
) -> Bool raise InspectError {
  visit_revision_pair(
    before,
    before.table_entry(name),
    after,
    after.table_entry(name),
    emit,
  )
}

///|
fn visit_revision_pair(
  before : WalRevision,
  before_entry : @sqlite.SchemaEntry,
  after : WalRevision,
  after_entry : @sqlite.SchemaEntry,
  emit : (VersionedChange) -> Bool,
) -> Bool raise InspectError {
  guard before_entry.sql is Some(sql) && after_entry.sql == Some(sql) else {
    raise Unsupported("table definitions differ between revisions")
  }
  let old = before.table_cursor(before_entry.root_page)
  let new = after.table_cursor(after_entry.root_page)
  merge_stored_rows(() => old.next(), () => new.next(), row => row.row, change => {
    emit(
      match change {
        RowAdded(row) => VersionedChange::Added(row)
        RowRemoved(row) => VersionedChange::Removed(row)
        RowChanged(left, right) => VersionedChange::Changed(left, right)
      },
    )
  })
}
