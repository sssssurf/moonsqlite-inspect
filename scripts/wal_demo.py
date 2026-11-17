"""Create a checkpointed SQLite baseline and a WAL containing four commits."""

import argparse
from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile

from wal_capture import capture_wal


WAL_PAGE_SIZE = 512
LOW_ROWID = -(2**63)
HIGH_ROWID = 2**63 - 1
WIDE_ROWID = 2**53 + 1


def make_capture(output):
    """Also return independently queried rows, page counts and WAL lengths."""
    queries = []
    page_counts = []
    wal_lengths = []
    with tempfile.TemporaryDirectory(prefix="sqlite-wal-demo-") as temporary:
        live = Path(temporary) / "demo.sqlite"
        live_wal = live.with_name(live.name + "-wal")
        with closing(sqlite3.connect(live)) as db:
            db.execute(f"PRAGMA page_size={WAL_PAGE_SIZE}")
            assert db.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
            db.executescript("""
                CREATE TABLE status(message, attachment);
                CREATE TABLE stable(note);
                CREATE TABLE compact(id PRIMARY KEY) WITHOUT ROWID;
                INSERT INTO stable VALUES ('baseline page');
            """)
            db.executemany("INSERT INTO status(rowid, message, attachment) VALUES (?, ?, ?)", [
                (LOW_ROWID, "remove me later", None),
                (41, "ready", b""),
                (WIDE_ROWID, "same page, same value", None),
            ])
            db.commit()

            def remember():
                queries.append(db.execute("SELECT rowid, * FROM status ORDER BY rowid").fetchall())
                page_counts.append(db.execute("PRAGMA page_count").fetchone()[0])
                wal_lengths.append(live_wal.stat().st_size)

            with capture_wal(db) as capture:
                remember()
                db.execute("UPDATE status SET message='waiting' WHERE rowid=41")
                db.commit()
                remember()
                db.execute("UPDATE status SET message='ready' WHERE rowid=41")
                db.commit()
                remember()
                db.execute("DELETE FROM status WHERE rowid=?", (LOW_ROWID,))
                db.execute("UPDATE status SET message=17 WHERE rowid=?", (WIDE_ROWID,))
                db.execute("INSERT INTO status(rowid, message, attachment) VALUES (?, ?, ?)",
                           (HIGH_ROWID, "vendor attachment", bytes(range(256)) * 10))
                db.commit()
                remember()
                db.execute("BEGIN")
                db.execute("ALTER TABLE status ADD COLUMN note TEXT")
                db.execute("UPDATE status SET note='stored in the new schema' WHERE rowid=41")
                db.commit()
                remember()
                capture.export(output)
    return queries, page_counts, wal_lengths


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    make_capture(args.output)
    print(f"Created baseline.sqlite, capture.wal and capture.json in {args.output}")
