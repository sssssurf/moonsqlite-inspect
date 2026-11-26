# Changes

## 0.5.1

- Use page membership tracking that compiles with warnings denied on MoonBit 1.0.0-rc1 and 0.10.21.
- Check the compiler version in CI against the November acceptance floor of 0.10.16 and map the nine requirements to repository evidence.

## 0.5.0

- Seek a row or an inclusive rowid interval at any validated revision. `WalRevision::find_row` and `WalRevision::visit_rowid_range` reuse the range cursor and return each cell's source.
- Add `wal-row` and `wal-range` with manifest checks. Range pages reserve room for a lossless signed 64-bit continuation and stop at the requested row limit or the 8 MiB response budget.
- Verify historical seeks and ranges against SQLite queries and raw WAL frames. Cover multiple B-tree levels, pruned branches, insertions and deletions, overflow, page sizes and encodings, row and byte limits, and independent installation on all four targets.

## 0.4.1

- Fix false changes when a stored REAL contains an IEEE NaN. Unchanged NaNs compare equal in backup, historical pair and adjacent comparisons. Storage-class changes and finite numeric changes remain visible. NaN payload bits are outside value comparison.
- Check real SQLite files with quiet, negative and signaling NaN patterns, infinities, signed zeros, a subnormal value and an integer-to-REAL transition. Run the public regression on all four backends through the independent consumer.
- Add `--help` and `-h` with successful exit status. Verify the README's history commands from a clean extracted distribution, including all seven JSON results, in CI.

## 0.4.0

- Add `WalRevision::visit_table` and `visit_revision_changes` for incremental historical reads and arbitrary endpoint comparisons, including reverse comparisons. Returning `false` stops before another row is decoded. Existing array-returning APIs use the same traversal.
- Apply the 8 MiB UTF-8 JSON response budget to `wal-rows` and `wal-changes` as well as `wal-series`. Oversized responses now fail with exit code 2 and empty standard output. Library visitors support larger results within the existing record and scan limits.
- Add four seeded multi-page WAL workloads, checked against SQLite across 100 historical snapshots and 120 comparisons. Cover growth, vacuum shrink, regrowth, overflow values, rollback and writes to unrelated tables.
- Expand independent distribution verification to five public API tests on each backend, including cancellation before a later damaged record. Add output-budget checks for cumulative BLOBs, JSON escapes, multibyte text and near-limit successful responses.

## 0.3.2

- Publish the cross-backend package and verify installation from Mooncakes in an independent consumer project.
- Check historical snapshots and adjacent changes across all nine page-size/text-encoding combinations.
- Adapt decimal argument parsing and formatting to the current MoonBit toolchain.
