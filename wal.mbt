///|
priv struct Wal {
  pages : Map[Int32, BytesView]
  page_count : Int32?
  frames_applied : Int32
  tail_bytes : Int32
}

///|
fn wal_word(
  data : BytesView,
  offset : Int32,
  big_endian : Bool,
) -> UInt32 raise InspectError {
  if big_endian {
    return word(data, offset, 4).to_uint()
  }
  let mut value = 0U
  for i in 0..<4 {
    value = value | (data[offset + i].to_uint() << (i * 8))
  }
  value
}

///|
fn wal_checksum(
  data : BytesView,
  big_endian : Bool,
  seed : (UInt32, UInt32),
) -> (UInt32, UInt32) raise InspectError {
  let mut first = seed.0
  let mut second = seed.1
  for i = 0; i < data.length(); i = i + 8 {
    first = first + wal_word(data, i, big_endian) + second
    second = second + wal_word(data, i + 4, big_endian) + first
  }
  (first, second)
}

///|
fn read_wal(data : BytesView, page_size : Int32) -> Wal raise InspectError {
  let pages : Map[Int32, BytesView] = Map([])
  if data.is_empty() {
    return { pages, page_count: None, frames_applied: 0, tail_bytes: 0, }
  }
  require_span(data, 0, 32)
  let big_endian = match word(data, 0, 4) {
    0x377f0682UL => false
    0x377f0683UL => true
    _ => raise Invalid("invalid WAL magic")
  }
  guard word(data, 4, 4) == 3007000UL else {
    raise Unsupported("unknown WAL format version")
  }
  guard word(data, 8, 4) == page_size.to_uint64() else {
    raise Invalid("WAL page size differs from the main database")
  }
  let salt = word(data, 16, 8)
  let mut checksum = wal_checksum(data[:24], big_endian, (0U, 0U))
  guard checksum == (word(data, 24, 4).to_uint(), word(data, 28, 4).to_uint()) else {
    raise Invalid("invalid WAL header checksum")
  }
  let pending : Map[Int32, BytesView] = Map([])
  let frame_size = page_size + 24
  let mut cursor = 32
  let mut commit_end = 32
  let mut page_count = None
  while frame_size <= data.length() - cursor {
    let frame = data[cursor:cursor + frame_size]
    if word(frame, 8, 8) != salt {
      break
    }
    let content = frame[24:]
    checksum = wal_checksum(
      content,
      big_endian,
      wal_checksum(frame[:8], big_endian, checksum),
    )
    if checksum != (word(frame, 16, 4).to_uint(), word(frame, 20, 4).to_uint()) {
      break
    }
    let page_no = bounded(word(frame, 0, 4), 0x7fffffff, "WAL page number")
    guard page_no > 0 else { raise Invalid("WAL frame refers to page zero") }
    pending[page_no] = content
    cursor += frame_size
    let size = word(frame, 4, 4)
    if size != 0UL {
      let count = bounded(size, 0x7fffffff, "WAL commit page count")
      let obsolete = pages.keys().filter(fn(key) { key > count }).to_array()
      for key in obsolete {
        pages.remove(key)
      }
      for key, value in pending {
        if key <= count {
          pages[key] = value
        }
      }
      pending.clear()
      page_count = Some(count)
      commit_end = cursor
    }
  }
  {
    pages,
    page_count,
    frames_applied: (commit_end - 32) / frame_size,
    tail_bytes: data.length() - commit_end,
  }
}
