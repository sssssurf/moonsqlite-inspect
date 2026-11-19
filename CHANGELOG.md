# Changes

## 0.4.0

- Add `WalRevision::visit_table` and `visit_revision_changes` for incremental historical reads and arbitrary endpoint comparisons, including reverse comparisons. Returning `false` stops before another row is decoded. Existing array-returning APIs use the same traversal.
- Apply the 8 MiB UTF-8 JSON response budget to `wal-rows` and `wal-changes` as well as `wal-series`. Oversized responses now fail with exit code 2 and empty standard output. Library visitors support larger results within the existing record and scan limits.
- Add four seeded multi-page WAL workloads, checked against SQLite across 100 historical snapshots and 120 comparisons. Cover growth, vacuum shrink, regrowth, overflow values, rollback and writes to unrelated tables.
- Expand independent distribution verification to five public API tests on each backend, including cancellation before a later damaged record. Add output-budget checks for cumulative BLOBs, JSON escapes, multibyte text and near-limit successful responses.

## 0.3.2

- Publish the cross-backend package and verify installation from Mooncakes in an independent consumer project.
- Check historical snapshots and adjacent changes across all nine page-size/text-encoding combinations.
- Adapt decimal argument parsing and formatting to the current MoonBit toolchain.
