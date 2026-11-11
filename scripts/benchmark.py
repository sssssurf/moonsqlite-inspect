"""Measure the built CLI on deterministic WAL and backup workloads."""

import argparse
from contextlib import closing
import json
from pathlib import Path
import shutil
import sqlite3
from statistics import median
import subprocess
import tempfile
from time import perf_counter


ROOT = Path(__file__).resolve().parents[1]
WAL_COMMITS = 12_000
BACKUP_ROWS = 8_000


def make_wal(directory):
    active = directory / "active.sqlite"
    main = directory / "snapshot.sqlite"
    wal = directory / "snapshot.wal"
    with closing(sqlite3.connect(active, isolation_level=None)) as db:
        db.execute("PRAGMA page_size=512")
        assert db.execute("PRAGMA journal_mode=WAL").fetchone() == ("wal",)
        db.executescript("PRAGMA synchronous=OFF; PRAGMA wal_autocheckpoint=0; CREATE TABLE items(payload);")
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        db.executemany("INSERT INTO items VALUES (zeroblob(400))", [()] * WAL_COMMITS)
        assert db.execute("SELECT count(*) FROM items").fetchone() == (WAL_COMMITS,)
        shutil.copyfile(active, main)
        shutil.copyfile(active.with_name(active.name + "-wal"), wal)
    return ["catalog", main, "--wal", wal], wal.stat().st_size


def make_backups(directory):
    before = directory / "before.sqlite"
    after = directory / "after.sqlite"
    with closing(sqlite3.connect(before)) as source, closing(sqlite3.connect(after)) as target:
        source.execute("PRAGMA page_size=4096")
        source.execute("CREATE TABLE items(payload)")
        source.executemany("INSERT INTO items VALUES (zeroblob(3584))", [()] * BACKUP_ROWS)
        source.commit()
        source.backup(target)
        target.execute("UPDATE items SET payload='edited' WHERE rowid=4000")
        target.commit()
    return ["diff", before, after, "items"], before.stat().st_size + after.stat().st_size


def sample(cli, preload, command):
    start = perf_counter()
    process = subprocess.run(["node", "--require", preload, cli, *command],
                             check=True, capture_output=True, encoding="utf-8")
    milliseconds = (perf_counter() - start) * 1000
    report = json.loads(process.stdout)
    # Older CLI versions do not report encoding in their catalog metadata.
    report.pop("text_encoding", None)
    return milliseconds, int(process.stderr), report


def measure(clis, preload, command, runs):
    samples = {name: [] for name, _ in clis}
    expected = None
    for trial in range(runs):
        order = clis if trial % 2 == 0 else reversed(clis)
        for name, cli in order:
            milliseconds, max_rss_kib, report = sample(cli, preload, command)
            if expected is None:
                expected = report
            assert report == expected, "CLI outputs differ on the benchmark fixture"
            samples[name].append((milliseconds, max_rss_kib))
    return {
        name: {
            "median_ms": round(median(value[0] for value in values), 1),
            "median_peak_rss_mib": round(median(value[1] for value in values) / 1024, 1),
        }
        for name, values in samples.items()
    }, expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, default=ROOT / "_build/js/debug/build/cmd/main/main.js")
    parser.add_argument("--baseline", type=Path, help="Compiled CLI from an earlier version")
    parser.add_argument("--runs", type=int, default=5)
    options = parser.parse_args()
    if options.runs < 1:
        parser.error("--runs must be positive")
    clis = [("current", options.cli.resolve(strict=True))]
    if options.baseline:
        clis.insert(0, ("baseline", options.baseline.resolve(strict=True)))

    build = (ROOT / "_build").resolve()
    temp = tempfile.TemporaryDirectory(prefix="sqlite-benchmark-", dir=build)
    directory = Path(temp.name).resolve()
    if directory.parent != build:
        raise RuntimeError("unexpected benchmark directory")
    with temp:
        preload = directory / "memory.cjs"
        preload.write_text("process.on('exit', () => console.error(process.resourceUsage().maxRSS));\n", encoding="utf-8")
        wal_command, wal_bytes = make_wal(directory)
        wal, catalog = measure(clis, preload, wal_command, options.runs)
        assert catalog["wal_frames_applied"] >= WAL_COMMITS and catalog["wal_tail_bytes"] == 0
        diff_command, backup_bytes = make_backups(directory)
        diff, report = measure(clis, preload, diff_command, options.runs)
        assert [(entry["kind"], entry["after"]["rowid"]) for entry in report["entries"]] == [("changed", "4000")]
    print(json.dumps({
        "node": subprocess.check_output(["node", "--version"], text=True).strip(),
        "sqlite": sqlite3.sqlite_version,
        "runs_per_cli": options.runs,
        "wal": {"commits": WAL_COMMITS, "bytes": wal_bytes, "results": wal},
        "diff": {"rows_per_snapshot": BACKUP_ROWS, "input_bytes": backup_bytes, "results": diff},
    }, indent=2))


if __name__ == "__main__":
    main()
