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
