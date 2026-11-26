///|
/// Ordered events within a history export. Each successful pair ends with
/// CommitFinished, including pairs with zero changed rows.
pub(all) enum WalChangeEvent {
  CommitStarted(WalCommit, WalCommit)
  CommitChange(VersionedChange)
  CommitFinished(WalCommit)
}

///|
priv struct TracedRevision {
  view : RevisionView
  pages : Map[Int32, Unit]
}

///|
impl @sqlite.RangeSource for TracedRevision with fn byte_length64(self) {
  @sqlite.RangeSource::byte_length64(self.view)
}

///|
impl @sqlite.RangeSource for TracedRevision with fn read_range64(
  self,
  offset,
  count,
) {
  let bytes = @sqlite.RangeSource::read_range64(self.view, offset, count)
  if count > 0 {
    let page_size = self.view.timeline.page_size.to_int64()
    let first = (offset / page_size).to_int() + 1
    let last = ((offset + count.to_int64() - 1L) / page_size).to_int() + 1
    for page in first..<=last {
      self.pages[page] = ()
    }
  }
  bytes
}

///|
fn WalTimeline::unchanged_pages(
  self : WalTimeline,
  before : WalCommit,
  after : WalCommit,
  pages : Map[Int32, Unit],
) -> Bool {
  if before.page_count != after.page_count {
    return false
  }
  for index in before.last_frame..<after.last_frame {
    if pages.contains(self.frame_pages[index].reinterpret_as_int()) {
      return false
    }
  }
  true
}

///|
/// Compare FROM→FROM+1 through TO-1→TO using the same WAL index. Records stream
/// in rowid order. Treat each pair as complete only after its CommitFinished
/// event; a later error may stop the visitor partway through a pair.
/// Returns false if the visitor stopped the export by returning false.
pub fn WalTimeline::visit_adjacent_changes(
  self : WalTimeline,
  name : String,
  from~ : Int32,
  to~ : Int32,
  emit : (WalChangeEvent) -> Bool,
) -> Bool raise InspectError {
  guard from <= to else {
    raise Invalid("the first revision must be at most the last revision")
  }
  let first = self.revision_entry(from)
  ignore(self.revision_entry(to))
  if from == to {
    return true
  }
  let mut baseline = self.open_revision(first, None)
  let mut baseline_entry = baseline.table_entry(name)
  let mut baseline_pages = None
  for revision in (from + 1)..<=to {
    let previous = self.revisions[revision - 1].info
    let entry = self.revisions[revision]
    if !emit(CommitStarted(previous, entry.info)) {
      return false
    }
    // The last successful scan traced the header, schema and table including
    // overflow pages. An equal size and disjoint frame list preserve that view.
    if baseline_pages is Some(pages) &&
      self.unchanged_pages(previous, entry.info, pages) {
      if !emit(CommitFinished(entry.info)) {
        return false
      }
      continue
    }
    let pages = Map([])
    let next = self.open_revision(entry, Some(pages))
    let next_entry = next.table_entry(name)
    let finished = visit_revision_pair(
      baseline,
      baseline_entry,
      next,
      next_entry,
      change => emit(CommitChange(change)),
    )
    if !finished || !emit(CommitFinished(entry.info)) {
      return false
    }
    baseline = next
    baseline_entry = next_entry
    baseline_pages = Some(pages)
  }
  true
}
