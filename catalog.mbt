///|
pub struct CatalogEntry {
  kind : String
  name : String
  table : String
  root_page : Int32
  sql : String?
}

///|
/// Read the five stored fields of each sqlite_schema record.
pub fn Snapshot::catalog(
  self : Snapshot,
) -> Array[CatalogEntry] raise InspectError {
  let result = []
  for row in self.scan_root(1) {
    match row.values {
      [Text(kind), Text(name), Text(table), Integer(root), sql] => {
        guard root >= 0L && root <= self.page_count.to_int64() else {
          raise Invalid("invalid catalog root page")
        }
        let sql = match sql {
          Null => None
          Text(value) => Some(value)
          _ => raise Invalid("catalog SQL must be text or null")
        }
        result.push({ kind, name, table, root_page: root.to_int(), sql, })
      }
      _ => raise Invalid("unexpected sqlite_schema record layout")
    }
  }
  result
}

///|
/// Read stored values for a table with the exact name used in sqlite_schema.
pub fn Snapshot::scan_table(
  self : Snapshot,
  name : String,
) -> Array[Row] raise InspectError {
  self.scan_root(self.table_entry(name).root_page)
}

///|
/// Find a stored record by its signed rowid. A missing row returns None.
pub fn Snapshot::find_row(
  self : Snapshot,
  name : String,
  rowid : Int64,
) -> Row? raise InspectError {
  let root = self.table_entry(name).root_page
  self.table_cursor(root, range={ first: rowid, last: rowid, }).next()
}

///|
pub struct RowidPage {
  rows : Array[Row]
  next_rowid : Int64?
}

///|
/// Read up to limit records from an inclusive rowid range in ascending order.
/// Pass next_rowid as the next call's first bound to continue, when present.
pub fn Snapshot::scan_rowid_range(
  self : Snapshot,
  name : String,
  first : Int64,
  last : Int64,
  limit~ : Int32,
) -> RowidPage raise InspectError {
  guard first <= last else {
    raise Invalid("the first rowid must be at most the last rowid")
  }
  guard limit > 0 else { raise Invalid("the row limit must be positive") }
  let root = self.table_entry(name).root_page
  let cursor = self.table_cursor(root, range={ first, last, })
  let rows = []
  while rows.length() < limit {
    guard cursor.next() is Some(row) else { return { rows, next_rowid: None, } }
    rows.push(row)
  }
  { rows, next_rowid: cursor.peek_rowid(), }
}

///|
fn Snapshot::table_entry(
  self : Snapshot,
  name : String,
) -> CatalogEntry raise InspectError {
  for entry in self.catalog() {
    if entry.kind == "table" && entry.name == name {
      guard entry.root_page > 0 else {
        raise Unsupported("table has no stored B-tree")
      }
      return entry
    }
  }
  raise NotFound(name)
}

///|
/// Read an index or WITHOUT ROWID table named in sqlite_schema.
pub fn Snapshot::scan_index(
  self : Snapshot,
  name : String,
) -> Array[IndexRecord] raise InspectError {
  for entry in self.catalog() {
    if (entry.kind == "index" || entry.kind == "table") && entry.name == name {
      guard entry.root_page > 0 else {
        raise Unsupported("object has no stored B-tree")
      }
      return self.scan_index_root(entry.root_page)
    }
  }
  raise NotFound(name)
}
