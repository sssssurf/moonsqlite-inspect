///|
pub struct Row {
  rowid : Int64
  page : Int32
  cell_offset : Int32
  values : Array[Value]
}

///|
fn mark_page(seen : Map[Int32, Bool], page : Int32) -> Unit raise InspectError {
  guard !seen.contains(page) else {
    raise Invalid("page \{page} is referenced more than once in the table")
  }
  seen[page] = true
}

///|
fn Snapshot::record_payload(
  self : Snapshot,
  page : BytesView,
  payload : Int32,
  length : UInt64,
  maximum : Int32,
  seen : Map[Int32, Bool],
) -> Array[Value] raise InspectError {
  let size = bounded(length, 16 * 1024 * 1024, "record payload size")
  if size <= maximum {
    require_span(page, payload, size)
    return read_record(page[payload:payload + size])
  }
  let chunk = self.usable_size - 4
  let minimum = (self.usable_size - 12) * 32 / 255 - 23
  let split = minimum + (size - minimum) % chunk
  let local_size = if split <= maximum { split } else { minimum }
  require_span(page, payload, local_size + 4)
  let buffer = FixedArray::make(size, b'\x00')
  for i in 0..<local_size {
    buffer[i] = page[payload + i]
  }
  let mut next = bounded(
    word(page, payload + local_size, 4),
    self.page_count,
    "overflow page",
  )
  let mut copied = local_size
  while copied < size {
    mark_page(seen, next)
    let block = self.page(next)
    next = bounded(word(block, 0, 4), self.page_count, "overflow page")
    let take = if chunk < size - copied { chunk } else { size - copied }
    for i in 0..<take {
      buffer[copied + i] = block[4 + i]
    }
    copied += take
  }
  guard next == 0 else {
    raise Invalid("overflow chain extends beyond the record payload")
  }
  read_record(Bytes::from_array(buffer)[:])
}

///|
priv struct BtreePage {
  bytes : BytesView
  cells : Array[Int32]
  right : Int32?
}

///|
fn Snapshot::btree_page(
  self : Snapshot,
  number : Int32,
  index_tree : Bool,
) -> BtreePage raise InspectError {
  let bytes = self.page(number)[:self.usable_size]
  let header = if number == 1 { 100 } else { 0 }
  let page_type = word(bytes, header, 1)
  let (interior_type, leaf_type, family) = if index_tree {
    (2UL, 10UL, "index")
  } else {
    (5UL, 13UL, "rowid-table")
  }
  guard page_type == interior_type || page_type == leaf_type else {
    raise Unsupported("page \{number} is not a \{family} B-tree page")
  }
  let right = if page_type == interior_type {
    Some(
      bounded(word(bytes, header + 8, 4), self.page_count, "right child page"),
    )
  } else {
    None
  }
  let pointers = header + (if right is Some(_) { 12 } else { 8 })
  let count = word(bytes, header + 3, 2).to_int()
  let content = word(bytes, header + 5, 2).to_int()
  let content = if content == 0 && self.page_size == 65536 {
    65536
  } else {
    content
  }
  guard pointers + count * 2 <= content && content <= bytes.length() else {
    raise Invalid("invalid B-tree cell pointer array on page \{number}")
  }
  let seen : Map[Int32, Bool] = Map([])
  let cells = []
  for index in 0..<count {
    let cell = word(bytes, pointers + index * 2, 2).to_int()
    guard cell >= content && cell < bytes.length() && !seen.contains(cell) else {
      raise Invalid("invalid B-tree cell offset on page \{number}")
    }
    seen[cell] = true
    cells.push(cell)
  }
  { bytes, cells, right, }
}

///|
/// Read stored records from a rowid-table root page in signed rowid order.
pub fn Snapshot::scan_root(
  self : Snapshot,
  root : Int32,
) -> Array[Row] raise InspectError {
  let seen : Map[Int32, Bool] = Map([])
  let stack = [(root, 0)]
  let rows = []
  let mut previous = None
  while stack.pop() is Some((number, depth)) {
    guard depth <= 64 else {
      raise Invalid("table B-tree exceeds the depth limit")
    }
    mark_page(seen, number)
    let tree = self.btree_page(number, false)
    let page = tree.bytes
    if tree.right is Some(right) {
      stack.push((right, depth + 1))
      for i in 0..<tree.cells.length() {
        let cell = tree.cells[tree.cells.length() - 1 - i]
        let child = bounded(
          word(page, cell, 4),
          self.page_count,
          "left child page",
        )
        ignore(varint(page, cell + 4))
        stack.push((child, depth + 1))
      }
    } else {
      for cell in tree.cells {
        let (length, rowid_start) = varint(page, cell)
        let (bits, payload) = varint(page, rowid_start)
        let rowid = bits.reinterpret_as_int64()
        let values = self.record_payload(
          page,
          payload,
          length,
          self.usable_size - 35,
          seen,
        )
        if previous is Some(last) && rowid <= last {
          raise Invalid("table rowids are out of order")
        }
        previous = Some(rowid)
        rows.push({ rowid, page: number, cell_offset: cell, values, })
      }
    }
  }
  rows
}

///|
pub struct IndexRecord {
  page : Int32
  cell_offset : Int32
  values : Array[Value]
}

///|
fn Snapshot::walk_index(
  self : Snapshot,
  number : Int32,
  depth : Int32,
  seen : Map[Int32, Bool],
  records : Array[IndexRecord],
) -> Unit raise InspectError {
  guard depth <= 64 else {
    raise Invalid("index B-tree exceeds the depth limit")
  }
  mark_page(seen, number)
  let tree = self.btree_page(number, true)
  let maximum = (self.usable_size - 12) * 64 / 255 - 23
  for cell in tree.cells {
    let start = if tree.right is Some(_) {
      let child = bounded(
        word(tree.bytes, cell, 4),
        self.page_count,
        "left child page",
      )
      self.walk_index(child, depth + 1, seen, records)
      cell + 4
    } else {
      cell
    }
    let (length, payload) = varint(tree.bytes, start)
    let values = self.record_payload(tree.bytes, payload, length, maximum, seen)
    records.push({ page: number, cell_offset: cell, values, })
  }
  if tree.right is Some(right) {
    self.walk_index(right, depth + 1, seen, records)
  }
}

///|
/// Read stored index entries or WITHOUT ROWID records in physical key order.
pub fn Snapshot::scan_index_root(
  self : Snapshot,
  root : Int32,
) -> Array[IndexRecord] raise InspectError {
  let records = []
  self.walk_index(root, 0, Map([]), records)
  records
}
