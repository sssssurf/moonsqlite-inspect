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
    raise Invalid("page \{page} is referenced more than once in the B-tree")
  }
  seen[page] = true
}

///|
fn Snapshot::record_payload(
  self : Snapshot,
  cell : BytesView,
  payload : Int32,
  length : UInt64,
  maximum : Int32,
  seen : Map[Int32, Bool],
) -> Array[Value] raise InspectError {
  let size = bounded(length, 16 * 1024 * 1024, "record payload size")
  if size <= maximum {
    guard size <= cell.length() - payload else {
      raise Invalid("record payload extends beyond its B-tree cell")
    }
    return read_record(cell[payload:payload + size], encoding=self.encoding)
  }
  let chunk = self.usable_size - 4
  let minimum = (self.usable_size - 12) * 32 / 255 - 23
  let split = minimum + (size - minimum) % chunk
  let local_size = if split <= maximum { split } else { minimum }
  guard local_size + 4 <= cell.length() - payload else {
    raise Invalid("record payload extends beyond its B-tree cell")
  }
  let overflow_count = (size - local_size + chunk - 1) / chunk
  guard overflow_count < self.page_count else {
    raise Invalid(
      "record payload requires more overflow pages than the snapshot contains",
    )
  }
  let mut next = bounded(
    word(cell, payload + local_size, 4),
    self.page_count,
    "overflow page",
  )
  let buffer = FixedArray::make(size, b'\x00')
  for i in 0..<local_size {
    buffer[i] = cell[payload + i]
  }
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
  read_record(Bytes::from_array(buffer)[:], encoding=self.encoding)
}

///|
priv struct CellSlot {
  offset : Int32
  end : Int32
}

///|
priv enum PageArea {
  Cell(Int32, Int32)
  Freeblock(Int32, Int32)
}

///|
fn PageArea::offset(self : PageArea) -> Int32 {
  match self {
    Cell(offset, _) | Freeblock(offset, _) => offset
  }
}

///|
priv struct BtreePage {
  bytes : BytesView
  cells : Array[CellSlot]
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
  let areas = []
  for index in 0..<count {
    let cell = word(bytes, pointers + index * 2, 2).to_int()
    guard cell >= content && cell < bytes.length() else {
      raise Invalid("invalid B-tree cell offset on page \{number}")
    }
    areas.push(Cell(cell, index))
  }
  guard word(bytes, header + 7, 1) <= 60UL else {
    raise Invalid("invalid fragmented byte count on page \{number}")
  }
  let mut block = word(bytes, header + 1, 2).to_int()
  let mut previous_end = content
  while block != 0 {
    guard block >= previous_end && block <= bytes.length() - 4 else {
      raise Invalid("invalid freeblock offset on page \{number}")
    }
    let size = word(bytes, block + 2, 2).to_int()
    guard size >= 4 && size <= bytes.length() - block else {
      raise Invalid("invalid freeblock size on page \{number}")
    }
    previous_end = block + size
    areas.push(Freeblock(block, previous_end))
    block = word(bytes, block, 2).to_int()
  }
  // Pointers are stored in key order. Use physical order to bound each cell,
  // then keep those bounds in the original key order for traversal.
  areas.sort_by_key(fn(area : PageArea) { area.offset() })
  let cells = Array::make(count, { offset: 0, end: 0, })
  for index, area in areas {
    let end = if index + 1 < areas.length() {
      areas[index + 1].offset()
    } else {
      bytes.length()
    }
    guard area.offset() < end else {
      raise Invalid("overlapping B-tree cell or freeblock on page \{number}")
    }
    match area {
      Cell(offset, slot) => cells[slot] = { offset, end, }
      Freeblock(_, block_end) =>
        if block_end > end {
          raise Invalid("freeblock overlaps a B-tree cell on page \{number}")
        }
    }
  }
  { bytes, cells, right, }
}

///|
priv struct TableBranch {
  page : Int32
  depth : Int32
  lower : Int64?
  upper : Int64?
}

///|
fn TableBranch::contains(self : TableBranch, rowid : Int64) -> Bool {
  !(self.lower is Some(lower) && rowid <= lower) &&
  !(self.upper is Some(upper) && rowid > upper)
}

///|
priv struct TableLeaf {
  branch : TableBranch
  tree : BtreePage
  mut next_slot : Int32
}

///|
priv struct TableCursor {
  snapshot : Snapshot
  seen : Map[Int32, Bool]
  stack : Array[TableBranch]
  mut leaf : TableLeaf?
  mut previous : Int64?
}

///|
fn Snapshot::table_cursor(self : Snapshot, root : Int32) -> TableCursor {
  {
    snapshot: self,
    seen: Map([]),
    stack: [{ page: root, depth: 0, lower: None, upper: None, }],
    leaf: None,
    previous: None,
  }
}

///|
fn TableCursor::push_children(
  self : TableCursor,
  branch : TableBranch,
  tree : BtreePage,
  right : Int32,
) -> Unit raise InspectError {
  let mut child = right
  let mut upper = branch.upper
  for i in 0..<tree.cells.length() {
    let slot = tree.cells[tree.cells.length() - 1 - i]
    let cell = tree.bytes[slot.offset:slot.end]
    let (bits, _) = varint(cell, 4)
    let rowid = bits.reinterpret_as_int64()
    guard branch.contains(rowid) &&
      !(i > 0 && upper is Some(next) && rowid >= next) else {
      raise Invalid("invalid rowid separator on page \{branch.page}")
    }
    self.stack.push({
      page: child,
      depth: branch.depth + 1,
      lower: Some(rowid),
      upper,
    })
    child = bounded(
      word(cell, 0, 4),
      self.snapshot.page_count,
      "left child page",
    )
    upper = Some(rowid)
  }
  self.stack.push({
    page: child,
    depth: branch.depth + 1,
    lower: branch.lower,
    upper,
  })
}

///|
fn TableCursor::next(self : TableCursor) -> Row? raise InspectError {
  while true {
    if self.leaf is Some(leaf) && leaf.next_slot < leaf.tree.cells.length() {
      let slot = leaf.tree.cells[leaf.next_slot]
      let cell = leaf.tree.bytes[slot.offset:slot.end]
      let (length, rowid_start) = varint(cell, 0)
      let (bits, payload) = varint(cell, rowid_start)
      let rowid = bits.reinterpret_as_int64()
      guard leaf.branch.contains(rowid) else {
        raise Invalid(
          "rowid is outside its B-tree range on page \{leaf.branch.page}",
        )
      }
      if self.previous is Some(last) && rowid <= last {
        raise Invalid("table rowids are out of order")
      }
      let values = self.snapshot.record_payload(
        cell,
        payload,
        length,
        self.snapshot.usable_size - 35,
        self.seen,
      ) catch {
        Invalid(message) =>
          raise Invalid(
            "page \{leaf.branch.page}, cell \{slot.offset}: \{message}",
          )
        error => raise error
      }
      leaf.next_slot += 1
      self.previous = Some(rowid)
      return Some({
        rowid,
        page: leaf.branch.page,
        cell_offset: slot.offset,
        values,
      })
    }
    self.leaf = None
    guard self.stack.pop() is Some(branch) else { break }
    guard branch.depth <= 64 else {
      raise Invalid("table B-tree exceeds the depth limit")
    }
    mark_page(self.seen, branch.page)
    let tree = self.snapshot.btree_page(branch.page, false)
    if tree.right is Some(right) {
      self.push_children(branch, tree, right)
    } else {
      self.leaf = Some({ branch, tree, next_slot: 0, })
    }
  }
  None
}

///|
/// Read stored records from a rowid-table root page in signed rowid order.
pub fn Snapshot::scan_root(
  self : Snapshot,
  root : Int32,
) -> Array[Row] raise InspectError {
  let cursor = self.table_cursor(root)
  let rows = []
  while cursor.next() is Some(row) {
    rows.push(row)
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
  for slot in tree.cells {
    let cell = tree.bytes[slot.offset:slot.end]
    let start = if tree.right is Some(_) {
      let child = bounded(word(cell, 0, 4), self.page_count, "left child page")
      self.walk_index(child, depth + 1, seen, records)
      4
    } else {
      0
    }
    let (length, payload) = varint(cell, start)
    let values = self.record_payload(cell, payload, length, maximum, seen) catch {
      Invalid(message) =>
        raise Invalid("page \{number}, cell \{slot.offset}: \{message}")
      error => raise error
    }
    records.push({ page: number, cell_offset: slot.offset, values, })
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
