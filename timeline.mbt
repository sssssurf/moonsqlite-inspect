///|
/// A captured commit, or revision 0 for the baseline. WAL frames are one-based.
pub(all) struct WalCommit {
  revision : Int32
  first_frame : Int32
  last_frame : Int32
  page_count : Int32
}

///|
/// Offsets point to page payloads. WAL offsets exclude the 24-byte frame header.
pub(all) enum PageOrigin {
  MainPage(Int64)
  WalFrame(WalPageOrigin)
}

///|
pub(all) struct WalPageOrigin {
  frame : Int32
  revision : Int32
  offset : Int64
}

///|
priv struct PageVersion {
  origin : WalPageOrigin
  mut superseded_at : Int32?
}

///|
priv struct RevisionEntry {
  info : WalCommit
  main_pages : Int32
}

///|
/// Indexed committed snapshots in a single offline WAL capture.
pub struct WalTimeline {
  priv main : Bytes
  priv wal : Bytes
  priv revisions : Array[RevisionEntry]
  priv versions : Map[Int32, Array[PageVersion]]
  priv frame_pages : Array[UInt32]
  page_size : Int32
  valid_frames : Int32
  committed_frames : Int32
  ignored_wal_bytes : Int32
  stop_offset : Int64
  stop_reason : String
}

///|
/// Returns revision 0 followed by the complete commits in the validated WAL prefix.
pub fn WalTimeline::commits(self : WalTimeline) -> Array[WalCommit] {
  self.revisions.map(fn(entry) { entry.info })
}

///|
// Each active page is represented once in the heap. Only truncated pages are
// removed, even if the commit shrinks a large main-file prefix.
fn index_page_versions(
  base_pages : Int32,
  log : @sqlite.RangeWalInspection,
) -> (Array[RevisionEntry], Map[Int32, Array[PageVersion]]) raise InspectError {
  let revisions = [
    {
      info: {
        revision: 0,
        first_frame: 0,
        last_frame: 0,
        page_count: base_pages,
      },
      main_pages: base_pages,
    },
  ]
  let versions : Map[Int32, Array[PageVersion]] = Map([])
  let active : Map[Int32, PageVersion] = Map([])
  let highest : @priority_queue.PriorityQueue[Int32] = PriorityQueue([])
  let mut main_pages = base_pages
  let mut covered_growth = 0
  let mut start = 0
  for boundary in log.commits {
    let revision = revisions.length()
    let page_count = bounded(
      boundary.database_pages.to_uint64(),
      0x7fffffff,
      "WAL commit page count",
    )
    while highest.peek() is Some(page) && page > page_count {
      ignore(highest.pop())
      let previous = active[page]
      previous.superseded_at = Some(revision)
      active.remove(page)
      if page > main_pages {
        covered_growth -= 1
      }
    }
    main_pages = Int32::min(main_pages, page_count)
    for index in start..<boundary.frame_index {
      let frame = log.frames[index]
      if frame.page_number > page_count.reinterpret_as_uint() {
        continue
      }
      let page = frame.page_number.reinterpret_as_int()
      let version = {
        origin: {
          frame: frame.index,
          revision,
          offset: frame.byte_offset + 24L,
        },
        superseded_at: None,
      }
      match active.get(page) {
        Some(previous) => previous.superseded_at = Some(revision)
        None => {
          highest.push(page)
          if page > main_pages {
            covered_growth += 1
          }
        }
      }
      active[page] = version
      let page_versions = versions.get_or_init(page, () => [])
      page_versions.push(version)
    }
    guard covered_growth == page_count - main_pages else {
      raise Invalid(
        "WAL revision \{revision} is missing pages after growth or truncation",
      )
    }
    revisions.push({
      info: {
        revision,
        first_frame: start + 1,
        last_frame: boundary.frame_index,
        page_count,
      },
      main_pages,
    })
    start = boundary.frame_index
  }
  (revisions, versions)
}

///|
/// Open a checkpointed baseline taken before the first write in this WAL epoch.
/// The inputs must stay immutable. The caller is responsible for capture order
/// and preventing other checkpoints or WAL resets through the final capture.
/// Only complete commits before the first invalid frame are indexed.
pub fn open_wal_timeline(
  base : Bytes,
  wal : Bytes,
  max_frames~ : Int32 = 100000,
) -> WalTimeline raise InspectError {
  let database = @sqlite.open_range_source(@sqlite.BytesSource::new(base)) catch {
    error => raise inspect_error(error)
  }
  let header = database.header()
  if !wal.is_empty() {
    guard header.write_version == 2 && header.read_version == 2 else {
      raise Invalid("a nonempty WAL requires a WAL-mode baseline")
    }
  }
  let log = @sqlite.inspect_wal_source(
    WalBytesSource::{ data: wal, },
    max_frames~,
  ) catch {
    error => raise inspect_error(error)
  }
  guard log.stop_reason != WalFrameLimit else {
    raise Unsupported("WAL frame budget exhausted before end of capture")
  }
  if log.header is Some(wal_header) && wal_header.page_size != header.page_size {
    raise Invalid("WAL page size differs from the baseline")
  }
  let (revisions, versions) = index_page_versions(database.page_count(), log)
  let prefix_bytes = if wal.is_empty() {
    0
  } else {
    32 + log.committed_frames * (header.page_size + 24)
  }
  {
    main: base,
    wal,
    revisions,
    versions,
    frame_pages: Array::makei(log.committed_frames, i => {
      log.frames[i].page_number
    }),
    page_size: header.page_size,
    valid_frames: log.frames.length(),
    committed_frames: log.committed_frames,
    ignored_wal_bytes: wal.length() - prefix_bytes,
    stop_offset: log.stop_offset,
    stop_reason: stop_reason_name(log.stop_reason),
  }
}

///|
priv struct RevisionView {
  timeline : WalTimeline
  entry : RevisionEntry
}

///|
fn RevisionView::page_origin(
  self : RevisionView,
  page : Int32,
) -> PageOrigin raise InspectError {
  let revision = self.entry.info.revision
  guard page >= 1 && page <= self.entry.info.page_count else {
    raise Invalid("page \{page} is outside WAL revision \{revision}")
  }
  if self.timeline.versions.get(page) is Some(versions) {
    // Upper bound by revision also selects the last frame when one transaction
    // writes the same page more than once.
    let mut low = 0
    let mut high = versions.length()
    while low < high {
      let mid = low + (high - low) / 2
      if versions[mid].origin.revision <= revision {
        low = mid + 1
      } else {
        high = mid
      }
    }
    if low > 0 {
      let version = versions[low - 1]
      if version.superseded_at is None ||
        version.superseded_at.unwrap() > revision {
        return WalFrame(version.origin)
      }
    }
  }
  guard page <= self.entry.main_pages else {
    raise Invalid("page \{page} is missing from WAL revision \{revision}")
  }
  MainPage((page - 1).to_int64() * self.timeline.page_size.to_int64())
}

///|
fn RevisionView::read_page_slice(
  self : RevisionView,
  page : Int32,
  start : Int32,
  count : Int32,
) -> BytesView raise @sqlite.SourceError {
  let origin = self.page_origin(page) catch {
    Invalid(message) | Unsupported(message) | NotFound(message) =>
      raise HostFailure(message)
  }
  let (data, offset) = match origin {
    MainPage(offset) => (self.timeline.main, offset.to_int())
    WalFrame(frame) => (self.timeline.wal, frame.offset.to_int())
  }
  let begin = offset + start
  data[begin:begin + count]
}

///|
impl @sqlite.RangeSource for RevisionView with fn byte_length64(self) {
  self.entry.info.page_count.to_int64() * self.timeline.page_size.to_int64()
}

///|
impl @sqlite.RangeSource for RevisionView with fn read_range64(
  self,
  offset,
  count,
) {
  let size = @sqlite.RangeSource::byte_length64(self)
  guard offset >= 0L &&
    offset <= size &&
    count >= 0 &&
    count.to_int64() <= size - offset else {
    raise RangeOutOfBounds(
      "byte range is outside WAL revision \{self.entry.info.revision}",
    )
  }
  if count == 0 {
    return b""
  }
  let page_size = self.timeline.page_size.to_int64()
  let end = offset + count.to_int64()
  let page = (offset / page_size).to_int() + 1
  let in_page = (offset % page_size).to_int()
  let replace_page_count = self.entry.info.revision > 0 &&
    offset < 32L &&
    end > 28L
  if !replace_page_count && count <= self.timeline.page_size - in_page {
    let span = self.read_page_slice(page, in_page, count)
    let start = span.start_offset()
    return range_bytes(span.data(), start, start + count)
  }
  let output : FixedArray[Byte] = FixedArray::make(count, 0)
  let mut copied = 0
  while copied < count {
    let position = offset + copied.to_int64()
    let page = (position / page_size).to_int() + 1
    let in_page = (position % page_size).to_int()
    let length = Int32::min(count - copied, self.timeline.page_size - in_page)
    let input = self.read_page_slice(page, in_page, length)
    for i in 0..<length {
      output[copied + i] = input[i]
    }
    copied += length
  }
  // open_range_source derives the size from page 1. Present the authoritative
  // WAL commit size in this read-only view; B-tree bytes and inputs are intact.
  if replace_page_count {
    for i in Int64::max(offset, 28L)..<Int64::min(end, 32L) {
      let shift = (31L - i).to_int() * 8
      output[(i - offset).to_int()] = (self.entry.info.page_count >> shift).to_byte()
    }
  }
  Bytes::from_array(output)
}

///|
/// One committed database view. Open multiple revisions from the same index.
pub struct WalRevision {
  priv view : RevisionView
  priv database : @sqlite.Database
  info : WalCommit
}

///|
pub fn WalTimeline::snapshot(
  self : WalTimeline,
  revision : Int32,
) -> WalRevision raise InspectError {
  self.open_revision(self.revision_entry(revision), None)
}

///|
fn WalTimeline::revision_entry(
  self : WalTimeline,
  revision : Int32,
) -> RevisionEntry raise InspectError {
  guard revision >= 0 && revision < self.revisions.length() else {
    raise Invalid("WAL revision \{revision} does not exist")
  }
  self.revisions[revision]
}

///|
/// Return a revision's boundary and page count without opening its view.
pub fn WalTimeline::commit(
  self : WalTimeline,
  revision : Int32,
) -> WalCommit raise InspectError {
  self.revision_entry(revision).info
}

///|
fn WalTimeline::open_revision(
  self : WalTimeline,
  entry : RevisionEntry,
  reads : Map[Int32, Unit]?,
) -> WalRevision raise InspectError {
  let view : RevisionView = { timeline: self, entry, }
  let source : &@sqlite.RangeSource = match reads {
    None => (view : &@sqlite.RangeSource)
    Some(pages) => (TracedRevision::{ view, pages, } : &@sqlite.RangeSource)
  }
  let database = @sqlite.open_range_source(source) catch {
    error => raise inspect_error(error)
  }
  guard database.header().page_size == self.page_size &&
    database.page_count() == entry.info.page_count else {
    raise Invalid(
      "page 1 is inconsistent with WAL revision \{entry.info.revision}",
    )
  }
  { view, database, info: entry.info, }
}

///|
/// Return the source of one logical page in this revision.
pub fn WalRevision::page_origin(
  self : WalRevision,
  page : Int32,
) -> PageOrigin raise InspectError {
  self.view.page_origin(page)
}
