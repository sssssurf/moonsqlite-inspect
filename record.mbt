///|
pub(all) enum Value {
  Null
  Integer(Int64)
  Real(Double)
  Text(String)
  Blob(Bytes)
} derive(Eq, @debug.Debug)

///|
pub extend Value with Eq::{equal, not_equal}

///|
pub extend Value with @debug.Debug::{to_repr}

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
fn read_record(payload : BytesView) -> Array[Value] raise InspectError {
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
      _ =>
        Text(
          @utf8.decode(field) catch {
            _ => raise Invalid("malformed UTF-8 record text")
          },
        )
    }
    values.push(value)
    body += size
  }
  guard body == payload.length() else {
    raise Invalid("record payload has unused bytes")
  }
  values
}
