///|
test "varints preserve all 64 bits and stop at the first terminal byte" {
  assert_eq(varint(b"\x81\x01\x00"[:], 0), (129UL, 2))
  assert_eq(
    varint(b"\xff\xff\xff\xff\xff\xff\xff\xff\xff"[:], 0),
    (0xffffffffffffffffUL, 9),
  )
}

///|
test "stored serial types retain signed values, binary data and BOM characters" {
  let record = b"\x06\x01\x03\x0e\x13\x08\xff\x80\x00\x00\xab\xef\xbb\xbf"
  assert_eq(read_record(record[:]), [
    Integer(-1L),
    Integer(-8388608L),
    Blob(b"\xab"),
    Text("\uFEFF"),
    Integer(0L),
  ])
}

///|
test "a reserved serial type is rejected" {
  let rejected = try {
    ignore(read_record(b"\x02\x0a"[:]))
    false
  } catch {
    Invalid(message) => message == "reserved record serial type"
    _ => false
  }
  assert_true(rejected)
}

///|
test "stored real comparisons are reflexive without hiding numeric or type changes" {
  let quiet = Real(0x7ff8000000000001UL.reinterpret_as_double())
  let signaling = Real(0x7ff0000000000001UL.reinterpret_as_double())
  let negative = Real(0xfff8000000000002UL.reinterpret_as_double())
  assert_eq(quiet, quiet)
  assert_eq(quiet, signaling)
  assert_eq(quiet, negative)
  assert_true(quiet != Null && quiet != Real(1.0))
  let infinity = Real(0x7ff0000000000000UL.reinterpret_as_double())
  assert_eq(infinity, infinity)
  assert_true(infinity != Real(0xfff0000000000000UL.reinterpret_as_double()))
  assert_true(infinity != quiet)
  assert_eq(Real(-0.0), Real(0.0))
  assert_true(Real(0.0) != Integer(0L))
  assert_true(Real(1.0) != Real(0x3ff0000000000001UL.reinterpret_as_double()))
}

///|
test "UTF-16 record text preserves its leading BOM and supplementary characters" {
  let little = b"\x02\x1d\xff\xfe\x2d\x4e\x3d\xd8\x00\xde"
  let big = b"\x02\x1d\xfe\xff\x4e\x2d\xd8\x3d\xde\x00"
  assert_eq(read_record(little[:], encoding=Utf16Le), [Text("\uFEFF中😀")])
  assert_eq(read_record(big[:], encoding=Utf16Be), [Text("\uFEFF中😀")])
  let rejected = try {
    ignore(read_record(b"\x02\x0f\x00"[:], encoding=Utf16Le))
    false
  } catch {
    Invalid(message) => message == "malformed text in a SQLite record"
    _ => false
  }
  assert_true(rejected)
}
