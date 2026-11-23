"""Create IEEE edge-case records and a controlled WAL, checked by SQLite itself."""

from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile

from wal_capture import capture_wal


def make_float_capture(output):
    """Return SQLite query results at each revision, including SQL's NaN-to-NULL projection."""
    expected = []
    with tempfile.TemporaryDirectory(prefix="sqlite-float-fixture-") as temporary:
        database = Path(temporary) / "floats.sqlite"
        with closing(sqlite3.connect(database)) as connection:
            connection.execute("PRAGMA page_size=512")
            assert connection.execute("PRAGMA journal_mode=WAL").fetchone() == ("wal",)
            connection.executescript("""
                CREATE TABLE numbers(value);
                CREATE TABLE unrelated(value);
                INSERT INTO unrelated VALUES (0);
            """)
            connection.executemany("INSERT INTO numbers VALUES (?)", [(value,) for value in (
                1.5, 2.5, 3.5, float("inf"), float("-inf"), -0.0, 0.0, 5e-324, 1e308, 42, None,
            )])
            connection.commit()
            root, = connection.execute("SELECT rootpage FROM sqlite_schema WHERE name='numbers'").fetchone()
        # SQL bindings normalize NaN to NULL. Inject known serial-7 IEEE patterns
        # into a real SQLite leaf so the reader's raw storage contract is tested.
        image = bytearray(database.read_bytes())
        page = (root - 1) * 512
        assert image[page] == 13
        for slot, bits in enumerate((0x7ff8000000000001, 0xfff8000000000002, 0x7ff0000000000001)):
            pointer = page + 8 + 2 * slot
            cell = page + int.from_bytes(image[pointer:pointer + 2], "big")
            assert image[cell:cell + 4] == bytes((10, slot + 1, 2, 7))
            image[cell + 4:cell + 12] = bits.to_bytes(8, "big")
        database.write_bytes(image)
        with closing(sqlite3.connect(database)) as connection:
            assert connection.execute("PRAGMA integrity_check").fetchone() == ("ok",)
            assert connection.execute("SELECT value FROM numbers WHERE rowid<=3").fetchall() == [(None,)] * 3

            def remember():
                expected.append(connection.execute("SELECT rowid, value FROM numbers ORDER BY rowid").fetchall())

            with capture_wal(connection) as capture:
                remember()
                for value in (1, 2):
                    connection.execute("UPDATE unrelated SET value=?", (value,))
                    connection.commit()
                    remember()
                connection.execute("UPDATE numbers SET value=8.5 WHERE rowid=1")
                connection.commit()
                remember()
                connection.execute("UPDATE numbers SET value=NULL WHERE rowid=2")
                connection.commit()
                remember()
                connection.execute("UPDATE numbers SET value=42.0 WHERE rowid=10")
                connection.commit()
                remember()
                capture.export(output)
    return expected
