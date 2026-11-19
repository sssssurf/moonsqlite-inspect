"""Verify a packaged or registry-installed module from a separate MoonBit project."""

import argparse
from contextlib import closing
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import tempfile
from zipfile import ZipFile

from wal_demo import make_capture


ROOT = Path(__file__).resolve().parents[1]
CONSUMER = "verification/wal-consumer"
TARGETS = ("js", "native", "wasm", "wasm-gc")


def manifest_field(path, name):
    match = re.search(rf'(?m)^{name}\s*=\s*"([^"]+)"\s*$', path.read_text(encoding="utf-8"))
    if match is None:
        raise ValueError(f"{name} missing from {path}")
    return match.group(1)


def fixture_literal(path):
    return 'b"' + "".join(f"\\x{byte:02x}" for byte in path.read_bytes()) + '"'


def lazy_scan_fixtures(samples):
    """A valid early row followed by a record that fails only when decoded."""
    database = samples / "lazy.sqlite"
    with closing(sqlite3.connect(database)) as connection:
        connection.executescript("""
            PRAGMA page_size=512;
            CREATE TABLE items(value);
            INSERT INTO items VALUES ('first'), ('second');
        """)
        root, = connection.execute("SELECT rootpage FROM sqlite_schema WHERE name='items'").fetchone()
    original = database.read_bytes()
    damaged = bytearray(original)
    page = (root - 1) * 512
    assert damaged[page] == 13
    first, last = (page + int.from_bytes(damaged[page + slot:page + slot + 2], "big")
                   for slot in (8, 10))
    assert damaged[first:first + 4] == bytes((7, 1, 2, 23))
    assert damaged[last:last + 4] == bytes((8, 2, 2, 25))
    damaged[first + 4:first + 9] = b"alter"
    damaged[last + 3] = 10  # Reserved SQLite serial type in the second row.
    changed = samples / "lazy-damaged.sqlite"
    changed.write_bytes(damaged)
    return database, changed


def consumer_source(samples):
    source = r'''
///|
fn timeline() -> @inspect.WalTimeline raise @inspect.InspectError {
  @inspect.open_wal_timeline(BASE_BYTES, WAL_BYTES)
}

///|
test "installed library reads snapshots and preserves physical record values" {
  let base = @inspect.open_snapshot(BASE_BYTES)
  assert_eq(base.page_size, 512)
  let row = base.find_row("status", 41L).unwrap()
  assert_eq(row.values, [@inspect.Value::Text("ready"), @inspect.Value::Blob(b"")])
  let page = base.scan_rowid_range("status", -9223372036854775808L, 9223372036854775807L, limit=1)
  assert_eq(page.rows[0].rowid, -9223372036854775808L)
  assert_eq(page.next_rowid, Some(41L))
  let history = timeline()
  assert_eq(history.commits().length(), 5)
  assert_eq(history.commit(3).revision, 3)
  let first = history.snapshot(0)
  let waiting = history.snapshot(1)
  let restored = history.snapshot(2)
  let changes = @inspect.diff_revisions(first, waiting, "status")
  guard changes is [Changed(before, after)] else { fail("missing row update") }
  assert_eq(before.row.rowid, 41L)
  assert_eq(after.row.values[0], @inspect.Value::Text("waiting"))
  assert_true(before.origin is MainPage(_))
  assert_true(after.origin is WalFrame({revision: 1, ..}))
  assert_eq(@inspect.diff_revisions(first, restored, "status").length(), 0)
}

///|
test "installed visitor emits adjacent pairs and supports cancellation" {
  let history = timeline()
  let starts : Array[(Int32, Int32)] = []
  let finishes : Array[Int32] = []
  let rowids : Array[Int64] = []
  let complete = history.visit_adjacent_changes("status", from=0, to=3, event => {
    match event {
      CommitStarted(before, after) => starts.push((before.revision, after.revision))
      CommitChange(Added(row) | Removed(row) | Changed(_, row)) => rowids.push(row.row.rowid)
      CommitFinished(commit) => finishes.push(commit.revision)
    }
    true
  })
  assert_true(complete)
  assert_eq(starts, [(0, 1), (1, 2), (2, 3)])
  assert_eq(finishes, [1, 2, 3])
  assert_eq(rowids, [41L, 41L, -9223372036854775808L, 9007199254740993L, 9223372036854775807L])
  let mut changes = 0
  let mut finished = 0
  let completed = history.visit_adjacent_changes("status", from=0, to=3, event => {
    match event {
      CommitChange(_) => {
        changes += 1
        false
      }
      CommitFinished(_) => {
        finished += 1
        true
      }
      CommitStarted(_, _) => true
    }
  })
  assert_false(completed)
  assert_eq(changes, 1)
  assert_eq(finished, 0)
}

///|
test "installed row and pair visitors support arbitrary endpoints and completion" {
  let history = timeline()
  let first = history.snapshot(0)
  let last = history.snapshot(3)
  let expected = last.scan_table("status")
  let visited : Array[@inspect.VersionedRow] = []
  assert_true(last.visit_table("status", row => {
    visited.push(row)
    true
  }))
  assert_eq(visited.length(), expected.length())
  for index in 0..<expected.length() {
    assert_eq(visited[index].row.rowid, expected[index].row.rowid)
    assert_eq(visited[index].row.values, expected[index].row.values)
  }
  let rowids : Array[Int64] = []
  assert_true(@inspect.visit_revision_changes(first, last, "status", change => {
    match change {
      Added(row) | Removed(row) | Changed(_, row) => rowids.push(row.row.rowid)
    }
    true
  }))
  assert_eq(rowids, [-9223372036854775808L, 9007199254740993L, 9223372036854775807L])
  let mut calls = 0
  assert_true(@inspect.visit_revision_changes(first, history.snapshot(2), "status", _ => {
    calls += 1
    true
  }))
  assert_eq(calls, 0)
  assert_false(@inspect.visit_revision_changes(last, first, "status", _ => {
    calls += 1
    false
  }))
  assert_eq(calls, 1)
}

///|
test "installed visitors stop before decoding a later damaged record" {
  let first = @inspect.open_wal_timeline(LAZY_BYTES, b"").snapshot(0)
  let damaged = @inspect.open_wal_timeline(DAMAGED_BYTES, b"").snapshot(0)
  let rows : Array[@inspect.VersionedRow] = []
  assert_false(damaged.visit_table("items", row => {
    rows.push(row)
    false
  }))
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].row.values, [@inspect.Value::Text("alter")])
  let changes : Array[@inspect.VersionedChange] = []
  assert_false(@inspect.visit_revision_changes(first, damaged, "items", change => {
    changes.push(change)
    false
  }))
  guard changes is [Changed(before, after)] else { fail("expected the early update") }
  assert_eq(before.row.values, [@inspect.Value::Text("first")])
  assert_eq(after.row.values, [@inspect.Value::Text("alter")])
  let mut seen = 0
  let rejected = try {
    ignore(damaged.visit_table("items", _ => {
      seen += 1
      true
    }))
    false
  } catch {
    @inspect.InspectError::Invalid(_) => true
    _ => false
  }
  assert_true(rejected)
  assert_eq(seen, 1)
}

///|
test "installed API rejects incomplete budgets and incompatible table definitions" {
  let exhausted = try {
    ignore(@inspect.open_wal_timeline(BASE_BYTES, WAL_BYTES, max_frames=1))
    false
  } catch {
    @inspect.InspectError::Unsupported(_) => true
    _ => false
  }
  assert_true(exhausted)
  let history = timeline()
  let incompatible = try {
    ignore(@inspect.diff_revisions(history.snapshot(3), history.snapshot(4), "status"))
    false
  } catch {
    @inspect.InspectError::Unsupported(_) => true
    _ => false
  }
  assert_true(incompatible)
  assert_eq(@inspect.open_wal_timeline(BASE_BYTES, b"").commits().length(), 1)
}
'''
    lazy, damaged = lazy_scan_fixtures(samples)
    return source.replace("BASE_BYTES", fixture_literal(samples / "baseline.sqlite")).replace(
        "WAL_BYTES", fixture_literal(samples / "capture.wal")).replace(
        "LAZY_BYTES", fixture_literal(lazy)).replace("DAMAGED_BYTES", fixture_literal(damaged))


def verify(registry, version):
    moon = shutil.which("moon")
    if moon is None:
        raise RuntimeError("install MoonBit and put moon on PATH")
    module = manifest_field(ROOT / "moon.mod", "name")
    build = ROOT / "_build"
    build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="distribution-check-", dir=build) as temporary:
        workspace = Path(temporary)
        consumer = workspace / "consumer"
        samples = workspace / "samples"
        consumer.mkdir()
        make_capture(samples)
        (consumer / "moon.mod").write_text(
            f'name = "{CONSUMER}"\nversion = "0.1.0"\nimport {{\n  "{module}@{version}",\n}}\n',
            encoding="utf-8",
        )
        (consumer / "moon.pkg").write_text(
            f'import {{\n  "{module}" @inspect,\n}} for "test"\n', encoding="utf-8",
        )
        (consumer / "api_test.mbt").write_text(consumer_source(samples), encoding="utf-8")
        workdir = consumer
        if not registry:
            if version != manifest_field(ROOT / "moon.mod", "version"):
                raise ValueError("packaged version must match moon.mod")
            subprocess.run([moon, "package", "--frozen"], cwd=ROOT, check=True)
            archive = build / "publish" / f"{module.replace('/', '-')}-{version}.zip"
            with ZipFile(archive) as package:
                if package.testzip() is not None:
                    raise RuntimeError("distribution archive is corrupt")
                package.extractall(workspace / "distribution")
            (workspace / "moon.work").write_text(
                'members = ["./distribution", "./consumer"]\n', encoding="utf-8",
            )
            workdir = workspace
        for target in TARGETS:
            subprocess.run(
                [moon, "test", "-p", CONSUMER, "--target", target, "--deny-warn"],
                cwd=workdir, check=True,
            )
        if registry:
            installed = consumer / ".mooncakes" / module / "moon.mod"
            if manifest_field(installed, "version") != version:
                raise RuntimeError("installed registry version differs from the requested release")
        mode = "registry" if registry else "packaged"
        print(f"{module}@{version}: {mode} consumer passed 5 API tests on each of {', '.join(TARGETS)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", action="store_true", help="Install from Mooncakes into a fresh project")
    parser.add_argument("--version", default=manifest_field(ROOT / "moon.mod", "version"))
    options = parser.parse_args()
    verify(options.registry, options.version)
