///|
fn commit_frames(
  groups : Array[(Array[Int32], Int32)],
) -> @sqlite.RangeWalInspection {
  let frames : Array[@sqlite.RangeWalFrame] = []
  let commits : Array[@sqlite.RangeWalCommit] = []
  for group in groups {
    let (pages, size) = group
    for i, page in pages {
      let index = frames.length() + 1
      frames.push({
        index,
        page_number: page.reinterpret_as_uint(),
        database_pages: if i == pages.length() - 1 {
          size.reinterpret_as_uint()
        } else {
          0U
        },
        byte_offset: 32L + (index - 1).to_int64() * 536L,
        checksum1: 0U,
        checksum2: 0U,
      })
    }
    commits.push({
      frame_index: frames.length(),
      database_pages: size.reinterpret_as_uint(),
    })
  }
  {
    header: None,
    frames,
    commits,
    committed_frames: frames.length(),
    database_pages: commits.last().map(fn(commit) { commit.database_pages }),
    stop_reason: WalEndOfFile,
    stop_offset: 32L + frames.length().to_int64() * 536L,
    trailing_bytes: 0L,
  }
}

///|
test "historical pages retain only the last write in a commit and survive until truncated" {
  let log = commit_frames([([2, 4, 2], 4), ([1], 2), ([3, 4], 4), ([1], 4)])
  let (revisions, versions) = index_page_versions(4, log)
  let timeline : WalTimeline = {
    main: b"",
    wal: b"",
    revisions,
    versions,
    page_size: 512,
    valid_frames: 7,
    committed_frames: 7,
    ignored_wal_bytes: 0,
    stop_offset: log.stop_offset,
    stop_reason: "end_of_file",
  }
  let base : RevisionView = { timeline, entry: revisions[0], }
  let first : RevisionView = { timeline, entry: revisions[1], }
  let third : RevisionView = { timeline, entry: revisions[3], }
  let last : RevisionView = { timeline, entry: revisions[4], }
  assert_true(base.page_origin(2) is MainPage(512L))
  assert_true(
    first.page_origin(2) is WalFrame({ frame: 3, revision: 1, offset: 1128L, }),
  )
  assert_true(first.page_origin(4) is WalFrame({ frame: 2, .. }))
  assert_true(third.page_origin(4) is WalFrame({ frame: 6, revision: 3, .. }))
  assert_true(last.page_origin(2) is WalFrame({ frame: 3, revision: 1, .. }))
  assert_true(last.page_origin(4) is WalFrame({ frame: 6, revision: 3, .. }))
}

///|
test "regrowth cannot reuse truncated baseline pages or expired WAL versions" {
  let log = commit_frames([([2, 4], 4), ([1], 2), ([3], 4)])
  let failure = try {
    ignore(index_page_versions(4, log))
    false
  } catch {
    Invalid(message) =>
      message == "WAL revision 3 is missing pages after growth or truncation"
    _ => false
  }
  assert_true(failure)
}

///|
test "range reads straddle main and WAL pages and normalize the commit page count" {
  let log = commit_frames([([2], 2)])
  let (revisions, versions) = index_page_versions(2, log)
  let timeline : WalTimeline = {
    main: Bytes::from_array(FixedArray::make(1024, b'A')),
    wal: Bytes::from_array(FixedArray::make(568, b'W')),
    revisions,
    versions,
    page_size: 512,
    valid_frames: 1,
    committed_frames: 1,
    ignored_wal_bytes: 0,
    stop_offset: 568L,
    stop_reason: "end_of_file",
  }
  let view : RevisionView = { timeline, entry: revisions[1], }
  let source : &@sqlite.RangeSource = view
  assert_eq(source.read_range64(510L, 4), b"AAWW")
  assert_eq(source.read_range64(27L, 6), b"A\x00\x00\x00\x02A")
  assert_eq(source.read_range64(31L, 2), b"\x02A")
  assert_eq(source.read_range64(1024L, 0), b"")
  let outside = try {
    ignore(source.read_range64(1024L, 1))
    false
  } catch {
    @sqlite.SourceError::RangeOutOfBounds(_) => true
    _ => false
  }
  assert_true(outside)
}
