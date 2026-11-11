"""Generate offline SQLite captures and compare the MoonBit CLI with SQLite."""

from contextlib import closing
from itertools import product
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "_build/js/debug/build/cmd/main/main.js"


def run(*args, error=None):
    process = subprocess.run(["node", CLI, *args], capture_output=True, encoding="utf-8")
    if error is not None:
        assert process.returncode == 2 and error in process.stderr and not process.stdout, (args, process)
        return None
    assert process.returncode == 0, (args, process.stderr)
    return json.loads(process.stdout)


def decoded(value):
    match value["type"]:
        case "null":
            return None
        case "integer":
            return int(value["value"])
        case "real":
            return float(value["value"])
        case "text":
            return value["value"]
        case "blob":
            return bytes.fromhex(value["value"])
        case _:
            raise AssertionError(value)


def check_rows(report, expected):
    rows = report["entries"]
    actual = [(int(row["rowid"]), *(decoded(field) for field in row["values"])) for row in rows]
    assert len(actual) == len(expected), (len(actual), len(expected))
    for left, right in zip(actual, expected, strict=True):
        assert left == right, (left[0], right[0])
    assert all(0 < row["page"] <= report["page_count"] and
               0 < row["cell_offset"] < report["page_size"] for row in rows)


def main_images(directory):
    total = 0
    for page_size, encoding in product((512, 4096, 65536), ("UTF-8", "UTF-16le", "UTF-16be")):
        db_path = directory / f"page-{page_size}-{encoding}.sqlite"
        with closing(sqlite3.connect(db_path)) as db:
            db.execute(f"PRAGMA page_size={page_size}")
            db.execute(f"PRAGMA encoding='{encoding}'")
            db.executescript("""
                CREATE TABLE samples(id INTEGER PRIMARY KEY, label TEXT, n INTEGER, r REAL, payload BLOB);
                CREATE INDEX samples_n ON samples(n);
                CREATE VIEW sample_names AS SELECT label FROM samples;
                CREATE TABLE compact(note TEXT, id TEXT, group_id INTEGER, PRIMARY KEY(group_id, id)) WITHOUT ROWID;
                CREATE TABLE empty(id TEXT);
            """)
            ids = [-2**63, -100, 0, *range(1, 241), 2**63 - 1]
            integers = [None, -2**63, -2**40, -2**31, -2**17, -32768, -128, 0, 1, 127,
                        128, 32768, 2**23, 2**31, 2**40, 2**63 - 1]
            db.executemany("INSERT INTO samples VALUES (?, ?, ?, ?, ?)", [
                (key, "\ufeff样本🙂\x00" + str(key), integers[index % len(integers)],
                 (index + 0.25) / 7, bytes(range(256)) * (page_size // 128 + 3) if index == 2 else b"abc")
                for index, key in enumerate(ids)
            ])
            db.executemany("INSERT INTO compact VALUES (?, ?, ?)", [
                ("长" * (page_size // 2) if i == 5 else f"条目{i}", f"id-{i:03}", i % 13)
                for i in range(180)
            ])
            db.commit()
            # Stored values keep the NULL serial for an INTEGER PRIMARY KEY alias.
            rows = db.execute("SELECT rowid, NULL, label, n, r, payload FROM samples ORDER BY rowid").fetchall()
            catalog = db.execute("SELECT type, name, tbl_name, rootpage, sql FROM sqlite_schema ORDER BY rowid").fetchall()
            indexed = db.execute("SELECT n, rowid FROM samples ORDER BY n, rowid").fetchall()
            compact = db.execute("SELECT group_id, id, note FROM compact ORDER BY group_id, id").fetchall()
        report = run("table", db_path, "samples")
        assert report["page_size"] == page_size
        assert report["text_encoding"] == encoding
        check_rows(report, rows)
        entries = run("catalog", db_path)["entries"]
        assert [(e["kind"], e["name"], e["table"], e["root_page"], e["sql"]) for e in entries] == catalog
        assert run("table", db_path, "empty")["entries"] == []
        run("table", db_path, "compact", error="not a rowid-table")
        run("table", db_path, "missing", error="NotFound")
        for name, expected in (("samples_n", indexed), ("compact", compact)):
            entries = run("index", db_path, name)["entries"]
            assert [tuple(decoded(field) for field in e["values"]) for e in entries] == expected
        total += len(rows) + len(indexed) + len(compact)
        if page_size == 512 and encoding == "UTF-8":
            bad_path = directory / "bad-pointer.sqlite"
            image = bytearray(db_path.read_bytes())
            root_page = next(entry[3] for entry in catalog if entry[1] == "samples")
            root = (root_page - 1) * page_size
            assert image[root] == 5, "fixture should have an interior table page"
            image[root + 12:root + 14] = b"\0\0"
            bad_path.write_bytes(image)
            run("table", bad_path, "samples", error="invalid B-tree cell offset")
            image = bytearray(db_path.read_bytes())
            first_cell = root + int.from_bytes(image[root + 12:root + 14], "big")
            assert 0 < image[first_cell + 4] < 128, "fixture should have a positive one-byte separator"
            image[first_cell + 4] = 0
            bad_path.write_bytes(image)
            run("table", bad_path, "samples", error="rowid is outside its B-tree range")
    invalid = directory / "truncated.sqlite"
    invalid.write_bytes(db_path.read_bytes()[:-1])
    run("catalog", invalid, error="incomplete main image")
    return total


def check_cell_boundaries(directory):
    database = directory / "cell-layout.sqlite"
    changed = directory / "damaged-layout.sqlite"
    with closing(sqlite3.connect(database)) as db:
        db.executescript("""
            PRAGMA page_size=512;
            CREATE TABLE packed(data);
            INSERT INTO packed VALUES (X'AA'), (X'BB');
            CREATE TABLE fragmented(data);
        """)
        db.executemany("INSERT INTO fragmented VALUES (?)", [("a" * 20 + str(i),) for i in range(12)])
        db.execute("DELETE FROM fragmented WHERE rowid IN (3, 7, 11)")
        db.commit()
        expected = db.execute("SELECT rowid, data FROM fragmented ORDER BY rowid").fetchall()
        roots = dict(db.execute("SELECT name, rootpage FROM sqlite_schema"))

    check_rows(run("table", database, "fragmented"), expected)
    original = database.read_bytes()
    page = (roots["fragmented"] - 1) * 512
    first_free = int.from_bytes(original[page + 1:page + 3], "big")
    assert original[page] == 13 and first_free > 0, "fixture should have an on-page freeblock"
    loop = bytearray(original)
    loop[page + first_free:page + first_free + 2] = first_free.to_bytes(2, "big")
    changed.write_bytes(loop)
    run("table", changed, "fragmented", error="invalid freeblock offset")

    page = (roots["packed"] - 1) * 512
    first, following = sorted(int.from_bytes(original[page + slot:page + slot + 2], "big") for slot in (8, 10))
    overlap = bytearray(original)
    start = page + first
    length = following - first - 1
    assert overlap[start] == 3 and overlap[start + 2] == 2 and 3 < length < 60
    overlap[start] = length
    overlap[start + 3] = 12 + 2 * (length - 2)
    changed.write_bytes(overlap)
    run("table", changed, "packed", error="record payload extends beyond its B-tree cell")
    run("diff", database, changed, "packed", error="record payload extends beyond its B-tree cell")


def wal_capture(directory):
    db_path = directory / "live.sqlite"
    capture = directory / "capture.sqlite"
    log = directory / "capture.wal"
    wal_path = db_path.with_name(db_path.name + "-wal")
    db = sqlite3.connect(db_path)
    try:
        db.execute("PRAGMA page_size=512")
        assert db.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
        db.execute("PRAGMA wal_autocheckpoint=0")
        db.executescript("CREATE TABLE samples(value TEXT); INSERT INTO samples VALUES ('checkpointed');")
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        db.execute("UPDATE samples SET value='committed edit'")
        db.commit()
        earlier = wal_path.read_bytes()
        db.execute("CREATE TABLE wal_only(value TEXT)")
        db.execute("INSERT INTO wal_only VALUES ('created in WAL')")
        db.execute("INSERT INTO samples VALUES ('committed insert')")
        db.commit()
        expected = db.execute("SELECT rowid, value FROM samples ORDER BY rowid").fetchall()
        committed = wal_path.read_bytes()
        db.executescript("PRAGMA cache_size=4; PRAGMA cache_spill=ON; BEGIN;")
        db.executemany("INSERT INTO samples VALUES (?)", [("pending" * 80,) for _ in range(100)])
        log_bytes = wal_path.read_bytes()
        assert len(log_bytes) > len(committed), "SQLite did not spill uncommitted frames"
        capture.write_bytes(db_path.read_bytes())
        log.write_bytes(log_bytes)
        db.rollback()
    finally:
        db.close()

    check_rows(run("table", capture, "samples"), [(1, "checkpointed")])
    run("table", capture, "wal_only", error="NotFound")
    report = run("table", capture, "samples", "--wal", log)
    check_rows(report, expected)
    check_rows(run("table", capture, "wal_only", "--wal", log), [(1, "created in WAL")])
    assert report["wal_frames_applied"] == (len(committed) - 32) // (512 + 24)
    assert report["wal_tail_bytes"] == len(log_bytes) - len(committed)
    changes = run("wal-diff", capture, "samples", "--wal", log)["entries"]
    assert [(c["kind"], c["after"]["rowid"]) for c in changes] == [("changed", "1"), ("added", "2")]
    log.write_bytes(committed + b"partial frame")
    truncated = run("table", capture, "samples", "--wal", log)
    check_rows(truncated, expected)
    assert truncated["wal_tail_bytes"] == len(b"partial frame")
    damaged = bytearray(committed)
    damaged[len(earlier) + 24] ^= 1
    log.write_bytes(damaged)
    prefix = run("table", capture, "samples", "--wal", log)
    check_rows(prefix, [(1, "committed edit")])
    assert prefix["wal_tail_bytes"] == len(committed) - len(earlier)
    log.write_bytes(committed[:24] + bytes([committed[24] ^ 1]) + committed[25:])
    run("table", capture, "samples", "--wal", log, error="invalid WAL header checksum")


def wal_resize(directory):
    live = directory / "resizing.sqlite"
    main = directory / "resizing-capture.sqlite"
    wal = directory / "resizing-capture.wal"
    with closing(sqlite3.connect(live)) as db:
        db.executescript("PRAGMA page_size=512; PRAGMA auto_vacuum=FULL;")
        assert db.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
        db.executescript("PRAGMA wal_autocheckpoint=0; CREATE TABLE samples(value TEXT);")
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        main.write_bytes(live.read_bytes())
        counts = []
        for command in (
            "WITH RECURSIVE r(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM r WHERE i<50) INSERT INTO samples SELECT printf('%0400d',i) FROM r;",
            "DELETE FROM samples WHERE rowid>2;",
            "WITH RECURSIVE r(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM r WHERE i<20) INSERT INTO samples SELECT printf('%0400d',i+100) FROM r;",
        ):
            db.executescript(command)
            counts.append(db.execute("PRAGMA page_count").fetchone()[0])
            wal.write_bytes(live.with_name(live.name + "-wal").read_bytes())
            report = run("table", main, "samples", "--wal", wal)
            assert report["page_count"] == counts[-1]
            check_rows(report, db.execute("SELECT rowid, value FROM samples ORDER BY rowid").fetchall())
        assert counts[0] > counts[1] and counts[1] < counts[2], counts


def compare_backups(directory):
    before = directory / "before.sqlite"
    after = directory / "after.sqlite"
    with closing(sqlite3.connect(before)) as db, closing(sqlite3.connect(after)) as updated:
        db.executescript("CREATE TABLE items(value); INSERT INTO items(rowid, value) VALUES(-1, 'old'), (2, X'AB'), (4, 42);")
        db.backup(updated)
        updated.executescript("DELETE FROM items WHERE rowid=-1; UPDATE items SET value=X'CD' WHERE rowid=2; INSERT INTO items VALUES ('added');")
        old = dict(db.execute("SELECT rowid, value FROM items"))
        new = dict(updated.execute("SELECT rowid, value FROM items"))
    result = run("diff", before, after, "items")["entries"]
    assert [change["kind"] for change in result] == ["removed", "changed", "added"]
    assert [(int(change["before"]["rowid"]), decoded(change["before"]["values"][0]))
            for change in result if "before" in change] == [(-1, old[-1]), (2, old[2])]
    assert [(int(change["after"]["rowid"]), decoded(change["after"]["values"][0]))
            for change in result if "after" in change] == [(2, new[2]), (5, new[5])]
    with closing(sqlite3.connect(after)) as updated:
        updated.execute("ALTER TABLE items ADD COLUMN extra DEFAULT 42")
        updated.commit()
    run("diff", before, after, "items", error="table definitions differ")


def main():
    build = (ROOT / "_build").resolve()
    temp = tempfile.TemporaryDirectory(prefix="sqlite-oracle-", dir=build)
    directory = Path(temp.name).resolve()
    if directory.parent != build:
        raise RuntimeError("unexpected test directory")
    with temp:
        total = main_images(directory)
        check_cell_boundaries(directory)
        wal_capture(directory)
        wal_resize(directory)
        compare_backups(directory)
    print(f"SQLite {sqlite3.sqlite_version}: {total} records matched across 3 page sizes and 3 encodings; page boundaries, WAL and backup diff cases passed")


if __name__ == "__main__":
    main()
