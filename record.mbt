///|
pub(all) enum Value {
  Null
  Integer(Int64)
  Real(Double)
  Text(String)
  Blob(Bytes)
}

///|
pub impl Eq for Value with fn equal(self, other) {
  match (self, other) {
    (Null, Null) => true
    (Integer(left), Integer(right)) => left == right
    // Stored-value equality must be reflexive, including decoded IEEE NaNs.
    (Real(left), Real(right)) =>
      left == right || (left != left && right != right)
    (Text(left), Text(right)) => left == right
    (Blob(left), Blob(right)) => left == right
    _ => false
  }
}

///|
pub impl @debug.Debug for Value with fn to_repr(self) {
  match self {
    Null => @debug.Repr::ctor("Null", [])
    Integer(value) => variant_repr("Integer", value)
    Real(value) => variant_repr("Real", value)
    Text(value) => variant_repr("Text", value)
    Blob(value) => variant_repr("Blob", value)
  }
}

///|
pub extend Value with Eq::{equal, not_equal}

///|
pub extend Value with @debug.Debug::{to_repr}

///|
priv enum TextEncoding {
  Utf8
  Utf16Le
  Utf16Be
}

///|
fn TextEncoding::decode(
  self : TextEncoding,
  field : BytesView,
) -> String raise InspectError {
  try {
    match self {
      Utf8 => @utf8.decode(field)
      Utf16Le => @utf16.decode(field, endianness=Little)
      Utf16Be => @utf16.decode(field, endianness=Big)
    }
  } catch {
    _ => raise Invalid("malformed text in a SQLite record")
  }
}

///|
fn serial_size(serial : UInt64, maximum : Int32) -> Int32 raise InspectError {
  match serial {
    0UL | 8UL | 9UL => 0
    1UL => 1
    2UL => 2
    3UL => 3
    4UL => 4
    5UL => 6
    6UL | 7UL => 8
    10UL | 11UL => raise Invalid("reserved record serial type")
    _ => bounded((serial - 12UL) / 2UL, maximum, "record field length")
  }
}

///|
fn read_record(
  payload : BytesView,
  encoding~ : TextEncoding = Utf8,
) -> Array[Value] raise InspectError {
  let (header_size, first) = varint(payload, 0)
  let end = bounded(header_size, payload.length(), "record header size")
  guard end >= first else { raise Invalid("record header overlaps its length") }
  let header = payload[:end]
  let values = []
  let mut cursor = first
  let mut body = end
  while cursor < end {
    let (serial, next) = varint(header, cursor)
    cursor = next
    let size = serial_size(serial, payload.length() - body)
    require_span(payload, body, size)
    let field = payload[body:body + size]
    let value = match serial {
      0UL => Null
      8UL => Integer(0L)
      9UL => Integer(1L)
      7UL => Real(word(field, 0, 8).reinterpret_as_double())
      1UL | 2UL | 3UL | 4UL | 5UL | 6UL => {
        let shift = 64 - size * 8
        Integer((word(field, 0, size) << shift).reinterpret_as_int64() >> shift)
      }
      _ if (serial & 1UL) == 0UL => Blob(field.to_owned())
      _ => Text(encoding.decode(field))
    }
    values.push(value)
    body += size
  }
  guard body == payload.length() else {
    raise Invalid("record payload has unused bytes")
  }
  values
}
