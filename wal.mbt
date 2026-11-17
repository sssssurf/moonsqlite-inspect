///|
fn inspect_error(error : @sqlite.SqliteError) -> InspectError {
  match error {
    Invalid(message) => Invalid(message)
    Unsupported(message) => Unsupported(message)
    LimitExceeded(message) => Unsupported("resource limit: \{message}")
  }
}

///|
fn stop_reason_name(reason : @sqlite.WalStopReason) -> String {
  match reason {
    WalEndOfFile => "end_of_file"
    WalTruncatedFrame => "truncated_frame"
    WalSaltMismatch => "salt_mismatch"
    WalChecksumMismatch => "checksum_mismatch"
    WalInvalidFrame => "invalid_frame"
    WalFrameLimit => "frame_limit"
  }
}

///|
#cfg(target="js")
// Both the input and the slices remain immutable for the life of the source.
extern "js" fn range_bytes(view : Bytes, start : Int32, end : Int32) -> Bytes =
  #| (bytes, start, end) => bytes.subarray(start, end)

///|
#cfg(not(target="js"))
fn range_bytes(view : Bytes, start : Int32, end : Int32) -> Bytes {
  view[start:end].to_owned()
}

///|
priv struct WalBytesSource {
  data : Bytes
}

///|
impl @sqlite.RangeSource for WalBytesSource with fn byte_length64(self) {
  self.data.length().to_int64()
}

///|
impl @sqlite.RangeSource for WalBytesSource with fn read_range64(
  self,
  offset,
  count,
) {
  let size = self.data.length().to_int64()
  guard offset >= 0L &&
    offset <= size &&
    count >= 0 &&
    count.to_int64() <= size - offset else {
    raise RangeOutOfBounds("byte range is outside the WAL")
  }
  let start = offset.to_int()
  range_bytes(self.data, start, start + count)
}
