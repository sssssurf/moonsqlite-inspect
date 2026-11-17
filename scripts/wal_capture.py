"""Capture one SQLite WAL epoch from a connection owned by the caller."""

from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import stat


MAX_FILE_BYTES = 64 * 1024 * 1024


def read_capture_file(path, *, missing_ok=False):
    try:
        with path.open("rb") as stream:
            initial = os.fstat(stream.fileno())
            if not stat.S_ISREG(initial.st_mode):
                raise ValueError(f"{path.name} must be a regular capture file")
            if initial.st_size > MAX_FILE_BYTES:
                raise ValueError(f"{path.name} exceeds the 64 MiB capture limit")
            data = stream.read(initial.st_size + 1)
            final = os.fstat(stream.fileno())
    except FileNotFoundError:
        if missing_ok:
            return b""
        raise
    if (len(data) != initial.st_size or final.st_size != initial.st_size or
            final.st_mtime_ns != initial.st_mtime_ns or final.st_ctime_ns != initial.st_ctime_ns):
        raise OSError(f"{path.name} changed during capture")
    return data


@contextmanager
def writer_barrier(connection):
    if connection.in_transaction:
        raise ValueError("finish the current SQLite transaction before capturing")
    connection.execute("BEGIN IMMEDIATE")
    try:
        yield
    finally:
        connection.execute("ROLLBACK")


def file_claim(data):
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def write_bundle(output, baseline, wal):
    if wal and len(wal) < 32:
        raise ValueError("the captured WAL has a partial header")
    manifest = {
        "format": "moonsqlite-inspect.capture/1",
        "capture_order": ["checkpointed_baseline", "wal_after_commits"],
        "baseline": file_claim(baseline),
        "wal": {**file_claim(wal), "epoch": wal[12:24].hex() if wal else None},
    }
    output.mkdir(parents=True, exist_ok=True)
    artifacts = (
        ("baseline.sqlite", baseline),
        ("capture.wal", wal),
        ("capture.json", (json.dumps(manifest, indent=2) + "\n").encode("utf-8")),
    )
    created = []
    try:
        for name, data in artifacts:
            path = output / name
            with path.open("xb") as stream:
                created.append(path)
                stream.write(data)
    except BaseException:
        for path in reversed(created):
            path.unlink(missing_ok=True)
        raise


class HeldCapture:
    def __init__(self, connection, database, wal, baseline):
        self._connection = connection
        self._database = database
        self._wal = wal
        self._baseline = baseline
        self._active = True

    def export(self, output):
        """Save the baseline, current WAL and its manifest to an offline directory."""
        if not self._active:
            raise ValueError("capture is outside its protected SQLite session")
        with writer_barrier(self._connection):
            if read_capture_file(self._database) != self._baseline:
                raise ValueError("the database file changed after the baseline was captured")
            wal = read_capture_file(self._wal, missing_ok=True)
        write_bundle(Path(output), self._baseline, wal)


@contextmanager
def capture_wal(connection):
    """Pin a checkpointed baseline while the caller commits its write workload."""
    if connection.in_transaction:
        raise ValueError("finish the current SQLite transaction before starting capture")
    main_path = next(row[2] for row in connection.execute("PRAGMA database_list") if row[1] == "main")
    if not main_path or connection.execute("PRAGMA main.journal_mode").fetchone()[0] != "wal":
        raise ValueError("capture requires a file-backed main database in WAL mode")
    database = Path(main_path).resolve(strict=True)
    wal = database.with_name(database.name + "-wal")
    autocheckpoint = connection.execute("PRAGMA wal_autocheckpoint").fetchone()[0]
    connection.execute("PRAGMA wal_autocheckpoint=0")
    reader = None
    capture = None
    try:
        if tuple(connection.execute("PRAGMA main.wal_checkpoint(TRUNCATE)").fetchone()) != (0, 0, 0):
            raise RuntimeError("SQLite could not finish the truncate checkpoint")
        with writer_barrier(connection):
            if read_capture_file(wal, missing_ok=True):
                raise RuntimeError("WAL changed before the baseline read transaction began")
            reader = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, isolation_level=None)
            reader.execute("BEGIN")
            reader.execute("SELECT count(*) FROM sqlite_schema").fetchone()
            baseline = read_capture_file(database)
        capture = HeldCapture(connection, database, wal, baseline)
        yield capture
    finally:
        if capture is not None:
            capture._active = False
        if reader is not None:
            reader.close()
        connection.execute(f"PRAGMA wal_autocheckpoint={autocheckpoint}")
