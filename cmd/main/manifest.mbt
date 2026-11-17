///|
extern "js" fn sha256(data : Bytes) -> String =
  #| (bytes) => require('node:crypto').createHash('sha256').update(bytes).digest('hex')

///|
fn manifest_option(options : ArrayView[String]) -> String? raise CliError {
  match options {
    [] => None
    ["--manifest", path] => Some(path)
    _ => raise CliError("Expected an optional --manifest FILE")
  }
}

///|
fn load_timeline(
  base_path : String,
  wal_path : String,
  manifest : String?,
) -> @inspect.WalTimeline raise {
  let base = load(base_path)
  let wal = load(wal_path)
  if manifest is Some(path) {
    verify_manifest(path, base, wal)
  }
  @inspect.open_wal_timeline(base, wal)
}

///|
fn verify_file_claim(
  role : String,
  claim : Json,
  bytes : Bytes,
) -> Unit raise CliError {
  guard claim is Object(fields) &&
    fields.get("bytes") is Some(Number(size, ..)) &&
    fields.get("sha256") is Some(String(digest)) else {
    raise CliError("Invalid capture manifest \{role} metadata")
  }
  guard size == bytes.length().to_double() else {
    raise CliError("Capture manifest \{role} size mismatch")
  }
  guard digest == sha256(bytes) else {
    raise CliError("Capture manifest \{role} SHA-256 mismatch")
  }
}

///|
fn verify_manifest(
  path : String,
  base : Bytes,
  wal : Bytes,
) -> Unit raise CliError {
  guard read_file(path, 8192) is Some(contents) else {
    raise CliError("Cannot read a stable capture manifest up to 8 KiB")
  }
  let parsed = @json.parse(
    @utf8.decode(contents[:]),
    max_nesting_depth=8,
    reject_duplicate_keys=true,
  ) catch {
    _ => raise CliError("Invalid capture manifest JSON")
  }
  guard parsed is Object(fields) &&
    fields.get("format") is Some(String("moonsqlite-inspect.capture/1")) &&
    fields.get("capture_order")
    is Some(
      Array([String("checkpointed_baseline"), String("wal_after_commits")])
    ) &&
    fields.get("baseline") is Some(base_claim) &&
    fields.get("wal") is Some(wal_claim) &&
    wal_claim is Object(wal_fields) &&
    wal_fields.get("epoch") is Some(epoch) else {
    raise CliError("Invalid capture manifest format or capture order")
  }
  verify_file_claim("baseline", base_claim, base)
  let expected_epoch = if wal.is_empty() {
    Json::null()
  } else {
    guard wal.length() >= 32 else { raise CliError("WAL header is truncated") }
    Json(blob_hex(wal[12:24].to_owned()))
  }
  guard epoch == expected_epoch else {
    raise CliError("Capture manifest WAL epoch mismatch")
  }
  verify_file_claim("WAL", wal_claim, wal)
}
