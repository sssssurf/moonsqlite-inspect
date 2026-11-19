"""Reproduce seeded, multi-page WAL workloads against SQLite's own query results."""

from contextlib import closing
from itertools import product
from pathlib import Path
import random
import sqlite3
import tempfile

from sqlite_oracle import ROOT, check_origins, check_rows, run
from wal_capture import capture_wal


SEEDS = (20261119, 8675309)
PAGE_SIZES = (512, 4096)
COMMITS = 24
QUERY = "SELECT rowid, label, amount, payload FROM items ORDER BY rowid"


def values(rng, revision):
    label = f"{revision}:" + rng.choice(("ready", "恢复🙂", "\ufeff状态\x00"))
    amount = rng.choice((None, -(2**63), 2**63 - 1, revision + 0.25))
    payload = rng.randbytes(rng.choice((0, 1, 31, 480, 1400)))
    return label, amount, payload


def insert_rows(connection, rng, revision, count):
    keys = {row[0] for row in connection.execute("SELECT rowid FROM items")}
    additions = []
    while len(additions) < count:
        key = rng.randrange(-(10**15), 10**15)
        if key not in keys:
            keys.add(key)
            additions.append((key, *values(rng, revision)))
    connection.executemany("INSERT INTO items(rowid, label, amount, payload) VALUES (?, ?, ?, ?)", additions)


def make_workload(directory, seed, page_size):
    rng = random.Random(seed)
    database = directory / "live.sqlite"
    bundle = directory / "capture"
    with closing(sqlite3.connect(database)) as connection:
        connection.execute(f"PRAGMA page_size={page_size}")
        connection.execute("PRAGMA auto_vacuum=FULL")
        assert connection.execute("PRAGMA journal_mode=WAL").fetchone() == ("wal",)
        connection.executescript("""
            PRAGMA cache_size=5;
            CREATE TABLE items(label, amount, payload);
            CREATE INDEX items_label ON items(label);
            CREATE TABLE unrelated(value);
            INSERT INTO unrelated VALUES (0);
        """)
        boundary_keys = (-(2**63), -(2**53) - 1, -1, 0, 2**53 + 1, 2**63 - 1)
        connection.executemany("INSERT INTO items(rowid, label, amount, payload) VALUES (?, ?, ?, ?)",
                               [(key, *values(rng, 0)) for key in boundary_keys])
        insert_rows(connection, rng, 0, 256)
        connection.commit()
        expected = [connection.execute(QUERY).fetchall()]
        sizes = [connection.execute("PRAGMA page_count").fetchone()[0]]
        root, = connection.execute("SELECT rootpage FROM sqlite_schema WHERE name='items'").fetchone()
        with capture_wal(connection) as capture:
            for revision in range(1, COMMITS + 1):
                keys = [row[0] for row in connection.execute("SELECT rowid FROM items ORDER BY rowid")]
                selected = rng.sample(keys, min(40, len(keys)))
                match revision % 8:
                    case 0:
                        connection.execute("UPDATE unrelated SET value=?", (revision,))
                    case 1:
                        connection.executemany("UPDATE items SET label=?, amount=?, payload=? WHERE rowid=?",
                                               [(*values(rng, revision), key) for key in selected])
                    case 2:
                        connection.executemany("DELETE FROM items WHERE rowid=?", [(key,) for key in selected])
                    case 3:
                        insert_rows(connection, rng, revision, 40)
                    case 4:
                        connection.execute("BEGIN")
                        connection.execute("SAVEPOINT undone")
                        connection.execute("UPDATE items SET label='must be rolled back'")
                        connection.execute("ROLLBACK TO undone")
                        connection.execute("RELEASE undone")
                        connection.executemany("UPDATE items SET payload=? WHERE rowid=?",
                                               [(rng.randbytes(8192 if i == 0 else 700), key)
                                                for i, key in enumerate(selected)])
                    case 5:
                        connection.execute("UPDATE items SET payload=zeroblob(2048), label='rolled back'")
                        connection.rollback()
                        connection.execute("UPDATE unrelated SET value=?", (revision,))
                    case 6:
                        connection.executemany("DELETE FROM items WHERE rowid=?", [(key,) for key in keys[16:]])
                    case 7:
                        insert_rows(connection, rng, revision, 256)
                connection.commit()
                assert connection.execute("PRAGMA integrity_check").fetchone() == ("ok",)
                expected.append(connection.execute(QUERY).fetchall())
                sizes.append(connection.execute("PRAGMA page_count").fetchone()[0])
            capture.export(bundle)
    base = (bundle / "baseline.sqlite").read_bytes()
    assert base[(root - 1) * page_size] == 5, "fixture must use a multi-page table"
    assert any(left > right for left, right in zip(sizes, sizes[1:])), "fixture must shrink"
    assert any(left < right for left, right in zip(sizes, sizes[1:])), "fixture must regrow"
    return bundle, expected, sizes


def changes_between(before, after, rows_before, rows_after):
    old, new = ({row[0]: row[1:] for row in rows} for rows in (before, after))
    result = []
    for key in sorted(old.keys() | new.keys()):
        if key not in old:
            result.append(dict(kind="added", after=rows_after[key]))
        elif key not in new:
            result.append(dict(kind="removed", before=rows_before[key]))
        elif old[key] != new[key]:
            result.append(dict(kind="changed", before=rows_before[key], after=rows_after[key]))
    return result


def check_workload(directory, seed, page_size):
    bundle, expected, sizes = make_workload(directory, seed, page_size)
    base, wal, manifest = (bundle / name for name in ("baseline.sqlite", "capture.wal", "capture.json"))
    baseline_bytes, wal_bytes = base.read_bytes(), wal.read_bytes()
    history = run("wal-verify", base, wal, manifest)["timeline"]
    commits = history["commits"]
    assert len(commits) == COMMITS + 1, (seed, page_size, len(commits))
    actual = []
    for revision, rows in enumerate(expected):
        report = run("wal-rows", base, wal, str(revision), "items")
        assert report["revision"] == commits[revision]
        assert commits[revision]["page_count"] == sizes[revision]
        check_rows({**report, "page_count": sizes[revision], "page_size": page_size}, rows)
        check_origins(report["entries"], baseline_bytes, wal_bytes, commits[revision]["last_frame"], page_size)
        actual.append({int(row["rowid"]): row for row in report["entries"]})

    def expected_pair(before, after):
        return {"from": commits[before], "to": commits[after],
                "entries": changes_between(expected[before], expected[after], actual[before], actual[after])}

    pairs = []
    start = 0
    while start < COMMITS:
        batch = run("wal-series", base, wal, str(start), str(COMMITS), "items", "--limit", "7")
        assert batch["from"] == start and batch["requested_to"] == COMMITS
        through = min(COMMITS, start + 7)
        assert batch["through"] == through
        assert batch["next_from"] == (through if through < COMMITS else None)
        pairs.extend(batch["entries"])
        start = through
    for revision, pair in enumerate(pairs, start=1):
        assert pair == expected_pair(revision - 1, revision), (seed, page_size, revision)
        if revision % 8 in (0, 5):
            assert pair["entries"] == [], "unrelated writes and rollbacks cannot create item changes"
    assert len(pairs) == COMMITS
    endpoints = ((0, COMMITS), (COMMITS, 0), (3, 3), (6, 7), (6, 22), (17, 2))
    for before, after in endpoints:
        pair = run("wal-changes", base, wal, str(before), str(after), "items")
        assert pair == expected_pair(before, after), (seed, page_size, before, after)
    assert base.read_bytes() == baseline_bytes and wal.read_bytes() == wal_bytes
    return len(expected), len(pairs) + len(endpoints)


def main():
    build = ROOT / "_build"
    build.mkdir(exist_ok=True)
    snapshots = comparisons = 0
    with tempfile.TemporaryDirectory(prefix="history-stress-", dir=build) as temporary:
        for seed, page_size in product(SEEDS, PAGE_SIZES):
            directory = Path(temporary) / f"{seed}-{page_size}"
            directory.mkdir()
            checked_snapshots, checked_pairs = check_workload(directory, seed, page_size)
            snapshots += checked_snapshots
            comparisons += checked_pairs
    print(f"SQLite {sqlite3.sqlite_version}: {snapshots} historical snapshots and {comparisons} comparisons matched")
    print(f"Seeds {SEEDS}, page sizes {PAGE_SIZES}, {COMMITS} commits per capture: "
          "B-tree growth, vacuum shrink, overflow, rollback and unrelated-write cases passed")


if __name__ == "__main__":
    main()
