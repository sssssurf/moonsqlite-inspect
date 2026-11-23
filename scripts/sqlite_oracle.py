"""Generate offline SQLite captures and compare the MoonBit CLI with SQLite."""

from contextlib import closing
from itertools import product
import json
import math
from pathlib import Path
import sqlite3
import subprocess
import tempfile

from wal_capture import capture_wal
from float_fixture import make_float_capture
from wal_demo import HIGH_ROWID, WAL_PAGE_SIZE, make_capture


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "_build/js/debug/build/cmd/main/main.js"


def run(*args, error=None):
    process = subprocess.run(["node", CLI, *args], capture_output=True, encoding="utf-8")
    if error is not None:
        assert process.returncode == 2 and error in process.stderr and not process.stdout, (args, process)
        return None
    assert process.returncode == 0, (args, process.stderr)
    if args[0] in ("wal-rows", "wal-row", "wal-range", "wal-changes", "wal-series"):
        assert len(process.stdout.encode("utf-8")) <= 8 * 1024 * 1024, "historical JSON exceeds its response budget"
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


def check_nonfinite_values(directory):
    bundle = directory / "nonfinite"
    expected = make_float_capture(bundle)
    base, wal = bundle / "baseline.sqlite", bundle / "capture.wal"
    baseline_bytes, wal_bytes = base.read_bytes(), wal.read_bytes()
    commits = run("wal-history", base, wal)["commits"]
    assert len(commits) == len(expected) == 6
    assert run("diff", base, base, "numbers")["entries"] == []
    snapshots = []
    for revision, sql_rows in enumerate(expected):
        report = run("wal-rows", base, wal, str(revision), "numbers")
        assert report["revision"] == commits[revision]
        rows = report["entries"]
        assert len(rows) == len(sql_rows)
        for row, (key, sql_value) in zip(rows, sql_rows, strict=True):
            assert int(row["rowid"]) == key
            value, = row["values"]
            if key in (1, 2, 3) and sql_value is None and (key != 2 or revision < 4):
                assert value["type"] == "real" and math.isnan(decoded(value))
            else:
                assert decoded(value) == sql_value
        check_origins(rows, baseline_bytes, wal_bytes, commits[revision]["last_frame"], 512)
        snapshots.append({int(row["rowid"]): row for row in rows})
    for before, after in ((0, 0), (0, 1), (1, 2), (0, 2), (2, 0), (5, 5)):
        assert run("wal-changes", base, wal, str(before), str(after), "numbers")["entries"] == []
    series = run("wal-series", base, wal, "0", "5", "numbers")
    assert [len(pair["entries"]) for pair in series["entries"]] == [0, 0, 1, 1, 1]
    for before, after, rowid in ((2, 3, 1), (3, 4, 2), (4, 5, 10)):
        expected_change = {"kind": "changed", "before": snapshots[before][rowid], "after": snapshots[after][rowid]}
        assert run("wal-changes", base, wal, str(before), str(after), "numbers")["entries"] == [expected_change]
        assert series["entries"][before]["entries"] == [expected_change]
    legacy = run("table", base, "numbers")["entries"]
    assert [row["values"] for row in legacy] == [row["values"] for row in snapshots[0].values()]
    assert base.read_bytes() == baseline_bytes and wal.read_bytes() == wal_bytes


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
    empty_wal = directory / "cell-layout.wal"
    empty_wal.write_bytes(b"")
    run("wal-rows", changed, empty_wal, "0", "packed", error="Invalid")
    damaged_rowid = original[start + 1]
    good_rowid = 3 - damaged_rowid
    good_value = b"\xaa" if good_rowid == 1 else b"\xbb"
    check_rows(run("row", changed, "packed", str(good_rowid)), [(good_rowid, good_value)])
    run("row", changed, "packed", str(damaged_rowid), error="record payload extends beyond its B-tree cell")
    if good_rowid < damaged_rowid:
        first_page = run("range", changed, "packed", str(good_rowid), str(damaged_rowid), "1")
        check_rows(first_page, [(good_rowid, good_value)])
        assert first_page["next_rowid"] == str(damaged_rowid)

    out_of_order = bytearray(original)
    out_of_order[start + 1] = good_rowid
    changed.write_bytes(out_of_order)
    run("row", changed, "packed", str(good_rowid), error="table rowids are out of order")


def check_rowid_lookup(directory):
    database = directory / "lookup.sqlite"
    lowest, highest = -(2**63), 2**63 - 1
    beyond_js_integer = 2**53 + 1
    keys = [lowest, *range(-1200, 1200, 2), beyond_js_integer, highest]
    with closing(sqlite3.connect(database)) as db:
        db.executescript("""
            PRAGMA page_size=512;
            CREATE TABLE items(payload);
            CREATE TABLE empty(payload);
            CREATE TABLE compact(id PRIMARY KEY) WITHOUT ROWID;
        """)
        db.executemany("INSERT INTO items(rowid, payload) VALUES (?, ?)", [
            (key, bytes(range(256)) * 12 if key == 0 else ("记录" * 25 + str(key))) for key in keys
        ])
        db.commit()
        check_rows(run("row", database, "items", "+0000"),
                   db.execute("SELECT rowid, payload FROM items WHERE rowid=0").fetchall())
        for key in (lowest, -1200, -2, 0, 998, beyond_js_integer, highest, -1, 1, highest - 1):
            expected = db.execute("SELECT rowid, payload FROM items WHERE rowid=?", (key,)).fetchall()
            check_rows(run("row", database, "items", str(key)), expected)
        for first, last, limit in ((-13, 23, 4), (lowest, -1192, 2), (highest, highest, 1), (1201, 1300, 3)):
            expected = db.execute("SELECT rowid, payload FROM items WHERE rowid BETWEEN ? AND ? ORDER BY rowid",
                                  (first, last)).fetchall()
            for start in range(0, max(1, len(expected)), limit):
                report = run("range", database, "items", str(first), str(last), str(limit))
                check_rows(report, expected[start:start + limit])
                next_index = start + limit
                next_key = expected[next_index][0] if next_index < len(expected) else None
                assert report["next_rowid"] == (None if next_key is None else str(next_key)), report
                if next_key is not None:
                    first = int(report["next_rowid"])
        root_page = db.execute("SELECT rootpage FROM sqlite_schema WHERE name='items'").fetchone()[0]

    assert run("row", database, "empty", "1")["entries"] == []
    run("row", database, "compact", "1", error="not a rowid-table")
    run("row", database, "missing", "1", error="NotFound")
    run("row", database, "items", str(highest + 1), error="64-bit decimal rowid")
    run("row", database, "items", str(lowest - 1), error="64-bit decimal rowid")
    for key in ("0x0", "-0X1", "0b10", "+0o2"):
        run("row", database, "items", key, error="64-bit decimal rowid")
    run("range", database, "items", "1", "0", "1", error="first rowid must be at most")
    run("range", database, "items", "0", "1", "0", error="row limit must be positive")
    run("range", database, "items", "0", "1", "0x1", error="decimal row limit")

    raw = bytearray(database.read_bytes())
    root = (root_page - 1) * 512
    first_cell = root + int.from_bytes(raw[root + 12:root + 14], "big")
    left_child = int.from_bytes(raw[first_cell:first_cell + 4], "big")
    assert raw[root] == 5 and raw[(left_child - 1) * 512] == 5, "lookup fixture needs multiple interior levels"
    low_record = run("row", database, "items", str(lowest))["entries"][0]
    high_record = run("row", database, "items", str(highest))["entries"][0]
    assert low_record["page"] != high_record["page"]
    raw[(high_record["page"] - 1) * 512] = 0
    damaged = directory / "unrelated-page.sqlite"
    damaged.write_bytes(raw)
    assert run("row", damaged, "items", str(lowest))["entries"] == [low_record]
    run("row", damaged, "items", str(highest), error="not a rowid-table")
    run("table", damaged, "items", error="not a rowid-table")

    # A historical seek must not visit the damaged, disjoint leaf.
    empty_wal = directory / "lookup-empty.wal"
    empty_wal.write_bytes(b"")
    report = run("wal-row", damaged, empty_wal, "0", "items", str(lowest))
    assert report["entries"] == [{**low_record, "source": {
        "kind": "main", "page_offset": str((low_record["page"] - 1) * 512),
    }}]
    run("wal-row", damaged, empty_wal, "0", "items", str(highest), error="not a rowid-table")
    run("wal-range", damaged, empty_wal, "0", "items", str(lowest), str(highest), "2000",
        error="not a rowid-table")

    bundle = directory / "historical-lookup"
    point_keys = (lowest, -4, -1, 0, 998, 1201, beyond_js_integer, highest)
    ranges = ((-13, 23, 4), (lowest, -1192, 2), (highest, highest, 1), (1201, 1300, 3))
    expected = []
    with closing(sqlite3.connect(database)) as db:
        assert db.execute("PRAGMA journal_mode=WAL").fetchone() == ("wal",)
        with capture_wal(db) as capture:
            for revision in range(3):
                if revision == 1:
                    db.execute("UPDATE items SET payload=? WHERE rowid=0", (bytes(range(256)) * 24,))
                    db.execute("INSERT INTO items(rowid, payload) VALUES (1201, 'added in WAL')")
                    db.commit()
                if revision == 2:
                    db.executemany("DELETE FROM items WHERE rowid=?", [(lowest,), (-4,), (highest,)])
                    db.commit()
                query = "SELECT rowid, payload FROM items"
                points = [db.execute(query + " WHERE rowid=?", (key,)).fetchall() for key in point_keys]
                intervals = [db.execute(query + " WHERE rowid BETWEEN ? AND ? ORDER BY rowid",
                                        (first, last)).fetchall() for first, last, _ in ranges]
                expected.append((points, intervals))
            capture.export(bundle)
    base, wal, manifest = (bundle / name for name in ("baseline.sqlite", "capture.wal", "capture.json"))
    base_bytes, wal_bytes = base.read_bytes(), wal.read_bytes()
    commits = run("wal-verify", base, wal, manifest)["timeline"]["commits"]
    assert len(commits) == len(expected)

    def check_lookup(report, rows, revision):
        commit = commits[revision]
        assert report["revision"] == commit
        check_rows({**report, "page_size": 512, "page_count": commit["page_count"]}, rows)
        check_origins(report["entries"], base_bytes, wal_bytes, commit["last_frame"], 512)

    for revision, (points, intervals) in enumerate(expected):
        args = (base, wal, str(revision), "items")
        for key, rows in zip(point_keys, points, strict=True):
            report = run("wal-row", *args, str(key), "--manifest", manifest)
            check_lookup(report, rows, revision)
            if key == 0 and revision == 1:
                assert report["entries"][0]["source"]["revision"] == 1
        for (first, last, limit), rows in zip(ranges, intervals, strict=True):
            for start in range(0, max(1, len(rows)), limit):
                report = run("wal-range", *args, str(first), str(last), str(limit))
                check_lookup(report, rows[start:start + limit], revision)
                first = rows[start + limit][0] if start + limit < len(rows) else None
                assert report["next_rowid"] == (None if first is None else str(first))

    assert run("wal-row", base, wal, "2", "empty", "1")["entries"] == []
    assert run("wal-range", base, wal, "2", "empty", "-1", "1", "1")["next_rowid"] is None
    run("wal-row", base, wal, "2", "compact", "1", error="not a rowid-table")
    run("wal-row", base, wal, "2", "missing", "1", error="NotFound")
    run("wal-row", base, wal, "3", "items", "1", error="revision 3 does not exist")
    for key in (str(highest + 1), str(lowest - 1), "0x2"):
        run("wal-row", base, wal, "2", "items", key, error="64-bit decimal rowid")
    run("wal-range", base, wal, "2", "items", "1", "0", "1", error="first rowid must be at most")
    run("wal-range", base, wal, "2", "items", "0", "1", "0", error="row limit must be positive")
    assert base.read_bytes() == base_bytes and wal.read_bytes() == wal_bytes


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
        db.execute("BEGIN")
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
    check_rows(run("row", capture, "samples", "2"), [])
    check_rows(run("row", capture, "samples", "2", "--wal", log), [expected[1]])
    first_page = run("range", capture, "samples", "1", "10", "1", "--wal", log)
    check_rows(first_page, [expected[0]])
    assert first_page["next_rowid"] == "2"
    assert report["wal_frames_applied"] == (len(committed) - 32) // (512 + 24)
    assert report["wal_tail_bytes"] == len(log_bytes) - len(committed)
    history = run("wal-history", capture, log)
    assert history["stop_reason"] == "end_of_file"
    assert history["valid_frames"] > history["committed_frames"]
    assert history["ignored_wal_bytes"] == len(log_bytes) - len(committed)
    assert len(history["commits"]) == 3
    run("wal-rows", capture, log, "3", "samples", error="revision 3 does not exist")
    assert run("wal-row", capture, log, "2", "samples", "3")["entries"] == []
    assert run("wal-row", capture, log, "2", "wal_only", "1")["entries"][0]["source"]["revision"] == 2
    run("wal-row", capture, log, "1", "wal_only", "1", error="NotFound")
    changes = run("wal-diff", capture, "samples", "--wal", log)["entries"]
    assert [(c["kind"], c["after"]["rowid"]) for c in changes] == [("changed", "1"), ("added", "2")]
    log.write_bytes(committed + b"partial frame")
    truncated = run("table", capture, "samples", "--wal", log)
    check_rows(truncated, expected)
    assert truncated["wal_tail_bytes"] == len(b"partial frame")
    history = run("wal-history", capture, log)
    assert history["stop_reason"] == "truncated_frame"
    assert int(history["stop_offset"]) == len(committed)
    damaged = bytearray(committed)
    damaged[len(earlier) + 24] ^= 1
    log.write_bytes(damaged)
    prefix = run("table", capture, "samples", "--wal", log)
    check_rows(prefix, [(1, "committed edit")])
    assert prefix["wal_tail_bytes"] == len(committed) - len(earlier)
    history = run("wal-history", capture, log)
    assert history["stop_reason"] == "checksum_mismatch"
    assert int(history["stop_offset"]) == len(earlier)
    assert len(history["commits"]) == 2
    log.write_bytes(committed[:24] + bytes([committed[24] ^ 1]) + committed[25:])
    run("table", capture, "samples", "--wal", log, error="WAL header checksum")


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
        expected = [db.execute("SELECT rowid, value FROM samples ORDER BY rowid").fetchall()]
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
            expected.append(db.execute("SELECT rowid, value FROM samples ORDER BY rowid").fetchall())
            check_rows(report, expected[-1])
        assert counts[0] > counts[1] and counts[1] < counts[2], counts
    for revision in range(1, 4):
        report = run("wal-rows", main, wal, str(revision), "samples")
        assert report["revision"]["page_count"] == counts[revision - 1]
        check_rows({**report, "page_size": 512, "page_count": counts[revision - 1]}, expected[revision])
    series = run("wal-series", main, wal, "0", "3", "samples")
    assert [entry["to"]["page_count"] for entry in series["entries"]] == counts
    for revision, entry in enumerate(series["entries"], start=1):
        assert entry == run("wal-changes", main, wal, str(revision - 1), str(revision), "samples")


def read_varint(data, offset):
    value = 0
    for i in range(9):
        byte = data[offset + i]
        if i == 8:
            return (value << 8) | byte, offset + 9
        value = (value << 7) | (byte & 0x7f)
        if byte < 0x80:
            return value, offset + i + 1


def check_origins(rows, baseline_bytes, wal_bytes, last_frame, page_size):
    """Independently replay unmodified SQLite frame headers and inspect raw cells."""
    frames = {}
    frame_size = page_size + 24
    revision = 1
    for number in range(1, last_frame + 1):
        offset = 32 + (number - 1) * frame_size
        page = int.from_bytes(wal_bytes[offset:offset + 4], "big")
        db_pages = int.from_bytes(wal_bytes[offset + 4:offset + 8], "big")
        frames[page] = dict(kind="wal", frame=number, revision=revision, page_offset=str(offset + 24))
        if db_pages:
            frames = {key: value for key, value in frames.items() if key <= db_pages}
            revision += 1
    for row in rows:
        page = row["page"]
        expected = frames.get(page, dict(kind="main", page_offset=str((page - 1) * page_size)))
        assert row["source"] == expected
        raw = baseline_bytes if expected["kind"] == "main" else wal_bytes
        offset = int(expected["page_offset"])
        cell = row["cell_offset"]
        image = raw[offset:offset + page_size]
        header = 100 if page == 1 else 0
        assert image[header] == 13
        size = int.from_bytes(image[header + 3:header + 5], "big")
        pointers = range(header + 8, header + 8 + size * 2, 2)
        assert any(int.from_bytes(image[start:start + 2], "big") == cell for start in pointers)
        _, key_offset = read_varint(image, cell)
        key, _ = read_varint(image, key_offset)
        assert int(row["rowid"]) == (key if key < 2**63 else key - 2**64)


def compare_history(directory):
    demo = directory / "history"
    expected_rows, page_counts, wal_lengths = make_capture(demo)
    baseline, wal = demo / "baseline.sqlite", demo / "capture.wal"
    manifest = demo / "capture.json"
    baseline_bytes, wal_bytes = baseline.read_bytes(), wal.read_bytes()
    last_frames = [0] + [(length - 32) // (WAL_PAGE_SIZE + 24) for length in wal_lengths[1:]]
    history = run("wal-history", baseline, wal)
    assert run("wal-verify", baseline, wal, manifest) == {
        "manifest_verified": True, "timeline": history,
    }
    assert run("wal-history", baseline, wal, "--manifest", manifest) == history
    assert history["page_size"] == WAL_PAGE_SIZE and history["committed_frames"] == last_frames[-1]
    assert history["valid_frames"] == last_frames[-1] and history["ignored_wal_bytes"] == 0
    assert history["stop_reason"] == "end_of_file" and int(history["stop_offset"]) == len(wal_bytes)
    assert history["commits"] == [
        dict(revision=i, first_frame=last_frames[i - 1] + 1 if i else 0,
             last_frame=last_frames[i], page_count=count)
        for i, count in enumerate(page_counts)
    ]
    actual_rows = []
    for revision, expected in enumerate(expected_rows):
        report = run("wal-rows", baseline, wal, str(revision), "status")
        assert report["revision"] == history["commits"][revision]
        if revision == 4:
            # ALTER TABLE projects a trailing NULL in SQL for untouched rows.
            # Only the subsequently updated row stores the new field on disk.
            expected = [row if row[0] == 41 else row[:-1] for row in expected]
        check_rows({**report, "page_size": WAL_PAGE_SIZE, "page_count": page_counts[revision]}, expected)
        check_origins(report["entries"], baseline_bytes, wal_bytes, last_frames[revision], WAL_PAGE_SIZE)
        actual_rows.append({int(row["rowid"]): row for row in report["entries"]})
    stable = run("wal-rows", baseline, wal, "3", "stable")["entries"]
    assert stable[0]["source"]["kind"] == "main"
    check_origins(stable, baseline_bytes, wal_bytes, last_frames[3], WAL_PAGE_SIZE)
    assert int(actual_rows[3][HIGH_ROWID]["source"]["revision"]) == 3
    assert actual_rows[1][41]["source"]["frame"] != actual_rows[2][41]["source"]["frame"]

    pairs = {}
    for before, after in ((0, 1), (1, 2), (0, 2), (2, 3), (3, 0), (3, 3)):
        report = run("wal-changes", baseline, wal, str(before), str(after), "status")
        pairs[before, after] = report
        assert report["from"] == history["commits"][before] and report["to"] == history["commits"][after]
        old, new = ({row[0]: row[1:] for row in expected_rows[i]} for i in (before, after))
        expected = []
        for key in sorted(old.keys() | new.keys()):
            if key not in old:
                expected.append(dict(kind="added", after=actual_rows[after][key]))
            elif key not in new:
                expected.append(dict(kind="removed", before=actual_rows[before][key]))
            elif old[key] != new[key]:
                expected.append(dict(kind="changed", before=actual_rows[before][key], after=actual_rows[after][key]))
        assert report["entries"] == expected
    assert pairs[0, 2]["entries"] == []
    first = run("wal-series", baseline, wal, "0", "3", "status", "--limit", "2", "--manifest", manifest)
    assert first == {
        "from": 0, "through": 2, "requested_to": 3, "next_from": 2,
        "entries": [pairs[0, 1], pairs[1, 2]],
    }
    last = run("wal-series", baseline, wal, str(first["next_from"]), "3", "status",
               "--manifest", manifest, "--limit", "2")
    assert last == {
        "from": 2, "through": 3, "requested_to": 3, "next_from": None, "entries": [pairs[2, 3]],
    }
    empty_series = run("wal-series", baseline, wal, "3", "3", "status")
    assert empty_series == {"from": 3, "through": 3, "requested_to": 3, "next_from": None, "entries": []}
    run("wal-series", baseline, wal, "0", "4", "status", error="table definitions differ")
    run("wal-series", baseline, wal, "0", "9", "status", "--limit", "1", error="revision 9 does not exist")
    run("wal-series", baseline, wal, "3", "0", "status", error="first revision must be at most")
    run("wal-series", baseline, wal, "0", "3", "status", "--limit", "1025", error="at most 1024")
    run("wal-changes", baseline, wal, "3", "4", "status", error="table definitions differ")
    run("wal-rows", baseline, wal, "4", "compact", error="Invalid")
    run("wal-rows", baseline, wal, "4", "missing", error="NotFound")
    run("wal-rows", baseline, wal, "-1", "status", error="must be nonnegative")
    run("wal-rows", baseline, wal, "0o1", "status", error="Expected a nonnegative revision")
    assert baseline.read_bytes() == baseline_bytes and wal.read_bytes() == wal_bytes

    empty = directory / "empty.wal"
    empty.write_bytes(b"")
    assert run("wal-history", baseline, empty)["commits"] == history["commits"][:1]
    assert run("wal-rows", baseline, empty, "0", "status")["entries"] == list(actual_rows[0].values())


def check_capture_manifest(directory):
    live = directory / "capture-session.sqlite"
    first, second = directory / "first-epoch", directory / "second-epoch"
    empty = directory / "empty-capture"
    occupied = directory / "occupied-capture"
    occupied.mkdir()
    (occupied / "capture.json").write_text("keep me", encoding="utf-8")
    post_checkpoint = directory / "post-checkpoint.sqlite"
    with closing(sqlite3.connect(live, timeout=0)) as db:
        assert db.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
        db.executescript("PRAGMA wal_autocheckpoint=7; CREATE TABLE items(note); INSERT INTO items VALUES ('abc');")
        with capture_wal(db) as capture:
            capture.export(empty)
            db.execute("UPDATE items SET note='def'")
            db.commit()
            with closing(sqlite3.connect(live, timeout=0)) as other:
                busy, frames, applied = other.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
            assert busy == 1 and frames > 0 and applied == 0
            capture.export(first)
            try:
                capture.export(occupied)
            except FileExistsError:
                assert [path.name for path in occupied.iterdir()] == ["capture.json"]
                assert (occupied / "capture.json").read_text(encoding="utf-8") == "keep me"
            else:
                raise AssertionError("capture must preserve a pre-existing manifest")
        assert db.execute("PRAGMA wal_autocheckpoint").fetchone()[0] == 7
        assert db.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone() == (0, 0, 0)
        post_checkpoint.write_bytes(live.read_bytes())
        with capture_wal(db) as capture:
            db.execute("UPDATE items SET note='ghi'")
            db.commit()
            capture.export(second)

    for bundle, revision_count in ((empty, 1), (first, 2), (second, 2)):
        report = run("wal-verify", bundle / "baseline.sqlite", bundle / "capture.wal", bundle / "capture.json")
        assert report["manifest_verified"] and len(report["timeline"]["commits"]) == revision_count
    baseline, wal, manifest = (first / name for name in ("baseline.sqlite", "capture.wal", "capture.json"))
    assert baseline.stat().st_size == post_checkpoint.stat().st_size
    run("wal-history", post_checkpoint, wal, "--manifest", manifest, error="baseline SHA-256 mismatch")
    run("wal-row", post_checkpoint, wal, "1", "items", "1", "--manifest", manifest,
        error="baseline SHA-256 mismatch")
    replacement_wal = second / "capture.wal"
    assert wal.stat().st_size == replacement_wal.stat().st_size
    run("wal-verify", baseline, replacement_wal, manifest, error="WAL epoch mismatch")
    run("wal-range", baseline, replacement_wal, "1", "items", "1", "2", "1", "--manifest", manifest,
        error="WAL epoch mismatch")
    corrupt_wal = directory / "edited-capture.wal"
    edited = bytearray(wal.read_bytes())
    edited[-1] ^= 1
    corrupt_wal.write_bytes(edited)
    run("wal-series", baseline, corrupt_wal, "0", "1", "items", "--manifest", manifest,
        error="WAL SHA-256 mismatch")
    corrupt_wal.write_bytes(edited[:-1])
    run("wal-verify", baseline, corrupt_wal, manifest, error="WAL size mismatch")
    invalid_manifest = directory / "duplicate-capture.json"
    original = manifest.read_text(encoding="utf-8")
    invalid_manifest.write_text('{"format":"moonsqlite-inspect.capture/1",' + original[1:], encoding="utf-8")
    run("wal-verify", baseline, wal, invalid_manifest, error="Invalid capture manifest JSON")
    swapped_order = json.loads(original)
    swapped_order["capture_order"].reverse()
    invalid_manifest.write_text(json.dumps(swapped_order), encoding="utf-8")
    run("wal-verify", baseline, wal, invalid_manifest, error="Invalid capture manifest format or capture order")


def check_series_overflow(directory):
    live = directory / "overflow-series.sqlite"
    output = directory / "overflow-series"
    with closing(sqlite3.connect(live)) as db:
        db.execute("PRAGMA page_size=512")
        assert db.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
        db.executescript("""
            CREATE TABLE tracked(payload, label);
            CREATE TABLE unrelated(value);
            INSERT INTO tracked VALUES (zeroblob(4096), 'initial');
            INSERT INTO unrelated VALUES (0);
        """)
        root = db.execute("SELECT rootpage FROM sqlite_schema WHERE name='tracked'").fetchone()[0]
        query = "SELECT rowid, payload, label FROM tracked"
        expected = [db.execute(query).fetchone()]
        with capture_wal(db) as capture:
            for revision in range(1, 9):
                if revision == 6:
                    if hasattr(db, "blobopen"):
                        db.execute("BEGIN")
                        with db.blobopen("tracked", "payload", 1) as blob:
                            blob.seek(-1, 2)
                            blob.write(b"\xab")
                    else:
                        db.execute("UPDATE tracked SET payload=?", (bytes(4095) + b"\xab",))
                elif revision == 8:
                    db.execute("UPDATE tracked SET label='changed'")
                else:
                    db.execute("UPDATE unrelated SET value=value+1")
                db.commit()
                expected.append(db.execute(query).fetchone())
            capture.export(output)
    baseline, wal, manifest = (output / name for name in ("baseline.sqlite", "capture.wal", "capture.json"))
    result = run("wal-series", baseline, wal, "0", "8", "tracked", "--manifest", manifest)
    assert [entry["to"]["revision"] for entry in result["entries"]] == list(range(1, 9))
    assert result["next_from"] is None
    for i, entry in enumerate(result["entries"]):
        before, after = expected[i:i + 2]
        if before == after:
            assert entry["entries"] == []
            continue
        change, = entry["entries"]
        assert change["kind"] == "changed"
        for field, row in (("before", before), ("after", after)):
            record = change[field]
            assert (int(record["rowid"]), *(decoded(value) for value in record["values"])) == row
    if hasattr(sqlite3.Connection, "blobopen"):
        overflow_only = result["entries"][5]
        data = wal.read_bytes()
        frames = range(overflow_only["from"]["last_frame"], overflow_only["to"]["last_frame"])
        offsets = [32 + index * (512 + 24) for index in frames]
        assert offsets and root not in {int.from_bytes(data[offset:offset + 4], "big") for offset in offsets}
        change, = overflow_only["entries"]
        assert change["before"]["page"] == change["after"]["page"] == root
        assert change["before"]["source"] == change["after"]["source"]


def check_series_budget(directory):
    output = directory / "large-series"
    with closing(sqlite3.connect(directory / "large-series.sqlite")) as db:
        assert db.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
        db.execute("CREATE TABLE large_rows(payload)")
        with capture_wal(db) as capture:
            db.execute("INSERT INTO large_rows VALUES (zeroblob(2300000))")
            db.commit()
            db.execute("DELETE FROM large_rows")
            db.commit()
            db.execute("INSERT INTO large_rows VALUES (zeroblob(4194305))")
            db.commit()
            db.execute("DELETE FROM large_rows")
            db.execute("INSERT INTO large_rows VALUES (zeroblob(2100000))")
            db.execute("INSERT INTO large_rows VALUES (?)", ("\x00" * 700000,))
            db.commit()
            db.execute("DELETE FROM large_rows")
            db.execute("INSERT INTO large_rows VALUES (?)", ("\x00" * 1398102,))
            db.commit()
            db.execute("DELETE FROM large_rows")
            db.execute("INSERT INTO large_rows VALUES (?)", ("中" * 2796203,))
            db.commit()
            capture.export(output)
    baseline, wal = output / "baseline.sqlite", output / "capture.wal"
    run("wal-series", baseline, wal, "0", "2", "large_rows", error="8 MiB output budget")
    small = run("wal-series", baseline, wal, "0", "2", "large_rows", "--limit", "1")
    assert small["next_from"] == 1 and small["entries"][0]["entries"][0]["kind"] == "added"
    run("wal-series", baseline, wal, "2", "3", "large_rows", error="8 MiB output budget")
    assert len(run("wal-rows", baseline, wal, "1", "large_rows")["entries"]) == 1
    assert run("wal-changes", baseline, wal, "0", "1", "large_rows")["entries"][0]["kind"] == "added"
    for revision in range(3, 7):
        run("wal-rows", baseline, wal, str(revision), "large_rows", error="8 MiB output budget")
        run("wal-changes", baseline, wal, "0", str(revision), "large_rows", error="8 MiB output budget")
    # The second row fits the raw byte estimate but not after JSON escaping.
    first = run("wal-range", baseline, wal, "4", "large_rows", "1", "2", "10")
    assert first["next_rowid"] == "2"
    blob, = first["entries"]
    assert blob["rowid"] == "1" and decoded(blob["values"][0]) == bytes(2100000)
    second = run("wal-range", baseline, wal, "4", "large_rows", first["next_rowid"], "2", "10")
    text, = second["entries"]
    assert text["rowid"] == "2" and decoded(text["values"][0]) == "\x00" * 700000
    assert second["next_rowid"] is None
    for revision in (3, 5, 6):
        run("wal-row", baseline, wal, str(revision), "large_rows", "1", error="8 MiB output budget")
        run("wal-range", baseline, wal, str(revision), "large_rows", "1", "2", "10",
            error="8 MiB output budget")
    run("wal-changes", baseline, wal, "3", "1", "large_rows", error="8 MiB output budget")
    near_limit = directory / "near-limit"
    with closing(sqlite3.connect(directory / "near-limit.sqlite")) as db:
        assert db.execute("PRAGMA journal_mode=WAL").fetchone() == ("wal",)
        db.execute("CREATE TABLE items(payload)")
        with capture_wal(db) as capture:
            db.execute("INSERT INTO items VALUES (zeroblob(4194000))")
            db.commit()
            capture.export(near_limit)
    base, log = near_limit / "baseline.sqlite", near_limit / "capture.wal"
    near_rows = run("wal-rows", base, log, "1", "items")
    assert len(decoded(near_rows["entries"][0]["values"][0])) == 4194000
    assert run("wal-row", base, log, "1", "items", "1") == near_rows
    assert run("wal-range", base, log, "1", "items", "1", "1", "3") == {**near_rows, "next_rowid": None}
    assert run("wal-changes", base, log, "0", "1", "items")["entries"][0]["kind"] == "added"


def check_history_encodings(directory):
    for page_size, encoding in product((512, 4096, 65536), ("UTF-8", "UTF-16le", "UTF-16be")):
        bundle = directory / f"history-{page_size}-{encoding}"
        live = directory / f"history-{page_size}-{encoding}.sqlite"
        with closing(sqlite3.connect(live)) as db:
            db.execute(f"PRAGMA page_size={page_size}")
            db.execute(f"PRAGMA encoding='{encoding}'")
            assert db.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
            db.execute("CREATE TABLE items(label, payload)")
            payload = bytes(range(256)) * (page_size // 256 + 2)
            db.execute("INSERT INTO items(rowid, label, payload) VALUES (?, ?, ?)",
                       (-(2**63), "\ufeff原始🙂\x00", payload))
            db.commit()
            query = "SELECT rowid, label, payload FROM items ORDER BY rowid"
            expected = [db.execute(query).fetchall()]
            sizes = [db.execute("PRAGMA page_count").fetchone()[0]]
            with capture_wal(db) as capture:
                db.execute("UPDATE items SET label=?", ("\ufeff更新中🙂\x00",))
                db.commit()
                expected.append(db.execute(query).fetchall())
                sizes.append(db.execute("PRAGMA page_count").fetchone()[0])
                db.execute("UPDATE items SET payload=?", (payload[:-1] + b"\x00",))
                db.commit()
                expected.append(db.execute(query).fetchall())
                sizes.append(db.execute("PRAGMA page_count").fetchone()[0])
                db.execute("INSERT INTO items(rowid, label, payload) VALUES (?, ?, ?)",
                           (2**63 - 1, "新记录", b""))
                db.commit()
                expected.append(db.execute(query).fetchall())
                sizes.append(db.execute("PRAGMA page_count").fetchone()[0])
                capture.export(bundle)
        baseline, wal, manifest = (bundle / name for name in ("baseline.sqlite", "capture.wal", "capture.json"))
        history = run("wal-verify", baseline, wal, manifest)["timeline"]
        assert len(history["commits"]) == 4 and history["page_size"] == page_size
        rows_by_revision = []
        for revision in range(4):
            report = run("wal-rows", baseline, wal, str(revision), "items")
            check_rows({**report, "page_size": page_size, "page_count": sizes[revision]}, expected[revision])
            rows_by_revision.append(report["entries"])
        target = run("wal-row", baseline, wal, "2", "items", str(-(2**63)))
        assert target["entries"] == rows_by_revision[2]
        interval = run("wal-range", baseline, wal, "3", "items", str(-(2**63)), str(2**63 - 1), "1")
        assert interval["entries"] == rows_by_revision[3][:1] and interval["next_rowid"] == str(2**63 - 1)
        series = run("wal-series", baseline, wal, "0", "3", "items", "--manifest", manifest)
        for revision, pair in enumerate(series["entries"], start=1):
            change, = pair["entries"]
            if revision < 3:
                assert change == {
                    "kind": "changed",
                    "before": rows_by_revision[revision - 1][0],
                    "after": rows_by_revision[revision][0],
                }
            else:
                assert change == {"kind": "added", "after": rows_by_revision[revision][1]}


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
        check_nonfinite_values(directory)
        check_cell_boundaries(directory)
        check_rowid_lookup(directory)
        wal_capture(directory)
        wal_resize(directory)
        compare_history(directory)
        check_capture_manifest(directory)
        check_series_overflow(directory)
        check_series_budget(directory)
        check_history_encodings(directory)
        compare_backups(directory)
    print(f"SQLite {sqlite3.sqlite_version}: {total} legacy records matched across 3 page sizes and 3 encodings")
    print("SQLite WAL timeline: 5 revisions, 6 diff pairs, raw cell provenance, resize and invalid-tail cases passed")
    print("WAL series and capture: pagination, overflow updates, response budget, pinned checkpoint and manifest mismatch cases passed")
    print("Historical snapshots and adjacent changes: all 9 page-size and text-encoding combinations matched SQLite")
    print("Stored IEEE values: NaN self-comparison, unchanged commits, infinities and genuine value/type changes passed")
    print("Historical rowid lookup: signed keys, pruned branches, nine encoding/size combinations, origins and byte-bounded continuation passed")


if __name__ == "__main__":
    main()
