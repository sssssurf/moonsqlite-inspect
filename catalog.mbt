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
