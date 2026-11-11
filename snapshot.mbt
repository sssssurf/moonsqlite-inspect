///|
pub struct Snapshot {
  priv main : Bytes
  priv overlay : Map[Int32, BytesView]
  priv encoding : TextEncoding
  page_size : Int32
  page_count : Int32
  usable_size : Int32
  wal_frames_applied : Int32
  wal_tail_bytes : Int32
}

///|
/// Return the text encoding used to decode records from this snapshot.
pub fn Snapshot::text_encoding(self : Snapshot) -> String {
  match self.encoding {
    Utf8 => "UTF-8"
    Utf16Le => "UTF-16le"
    Utf16Be => "UTF-16be"
  }
}

///|
fn Snapshot::page(
  self : Snapshot,
  number : Int32,
) -> BytesView raise InspectError {
  guard number >= 1 && number <= self.page_count else {
    raise Invalid("page \{number} is outside the snapshot")
  }
  if self.overlay.get(number) is Some(bytes) {
    return bytes
  }
  guard number <= self.main.length() / self.page_size else {
    raise Invalid("page \{number} is missing from the snapshot")
  }
  let offset = (number - 1) * self.page_size
  self.main[offset:offset + self.page_size]
}

///|
/// Open an offline main database image with an optional WAL from the same capture.
pub fn open_snapshot(main : Bytes, wal? : Bytes) -> Snapshot raise InspectError {
  let data = main[:]
  require_span(data, 0, 100)
  guard data[:16] == b"SQLite format 3\x00"[:] else {
    raise Invalid("invalid SQLite file signature")
  }
  let raw_size = word(data, 16, 2).to_int()
  let page_size = if raw_size == 1 { 65536 } else { raw_size }
  guard page_size >= 512 &&
    (page_size & (page_size - 1)) == 0 &&
    main.length() % page_size == 0 else {
    raise Invalid("invalid SQLite page size or incomplete main image")
  }
  let write_version = word(data, 18, 1)
  let read_version = word(data, 19, 1)
  guard (write_version == 1UL || write_version == 2UL) &&
    (read_version == 1UL || read_version == 2UL) else {
    raise Unsupported("unknown SQLite journal format")
  }
  if wal is Some(log) &&
    !log.is_empty() &&
    (write_version != 2UL || read_version != 2UL) {
    raise Invalid("a nonempty WAL requires a WAL-mode main image")
  }
  let wal = read_wal(wal.unwrap_or(b"")[:], page_size)
  let physical_pages = main.length() / page_size
  let main_count = word(data, 28, 4)
  let page_count = match wal.page_count {
    Some(count) => count
    None if main_count != 0UL && word(data, 24, 4) == word(data, 92, 4) =>
      bounded(main_count, physical_pages, "main page count")
    None => physical_pages
  }
  let header = wal.pages.get(1).unwrap_or(data[:page_size])
  guard header[:16] == data[:16] && word(header, 16, 2) == raw_size.to_uint64() else {
    raise Invalid("effective page 1 is inconsistent with the main header")
  }
  let encoding = match word(header, 56, 4) {
    1UL => Utf8
    2UL => Utf16Le
    3UL => Utf16Be
    0UL if word(header, 44, 4) == 0UL => Utf8
    _ => raise Unsupported("unknown SQLite text encoding")
  }
  let usable_size = page_size - word(header, 20, 1).to_int()
  guard usable_size >= 480 && word(header, 21, 3) == 0x402020UL else {
    raise Invalid("invalid SQLite usable page size or payload fractions")
  }
  {
    main,
    overlay: wal.pages,
    encoding,
    page_size,
    page_count,
    usable_size,
    wal_frames_applied: wal.frames_applied,
    wal_tail_bytes: wal.tail_bytes,
  }
}
