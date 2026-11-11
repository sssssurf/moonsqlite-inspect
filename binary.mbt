///|
pub suberror InspectError {
  Invalid(String)
  Unsupported(String)
  NotFound(String)
} derive(@debug.Debug)

///|
pub extend InspectError with @debug.Debug::{to_repr}

///|
fn require_span(
  data : BytesView,
  start : Int32,
  count : Int32,
) -> Unit raise InspectError {
  guard start >= 0 &&
    start <= data.length() &&
    count >= 0 &&
    count <= data.length() - start else {
    raise Invalid("byte range is outside the available data")
  }
}

///|
fn word(
  data : BytesView,
  offset : Int32,
  size : Int32,
) -> UInt64 raise InspectError {
  require_span(data, offset, size)
  let mut result = 0UL
  for index in 0..<size {
    result = (result << 8) | data[offset + index].to_uint64()
  }
  result
}

///|
fn bounded(
  value : UInt64,
  maximum : Int32,
  field : String,
) -> Int32 raise InspectError {
  guard value <= maximum.to_uint64() else {
    raise Invalid("\{field} is out of range")
  }
  value.to_int()
}

///|
fn varint(
  data : BytesView,
  offset : Int32,
) -> (UInt64, Int32) raise InspectError {
  let mut result = 0UL
  let mut cursor = offset
  for index in 0..<9 {
    require_span(data, cursor, 1)
    let byte = data[cursor].to_uint64()
    cursor += 1
    if index == 8 {
      return ((result << 8) | byte, cursor)
    }
    result = (result << 7) | (byte & 127UL)
    if byte < 128UL {
      return (result, cursor)
    }
  }
  raise Invalid("unterminated SQLite varint")
}
