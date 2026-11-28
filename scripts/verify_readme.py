"""Run the README history example from a newly extracted distribution."""

import argparse
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from zipfile import ZipFile

from verify_distribution import manifest_field


ROOT = Path(__file__).resolve().parents[1]


def verify(skip_update=False, archive=None):
    moon = shutil.which("moon")
    if moon is None:
        raise RuntimeError("install MoonBit and put moon on PATH")
    build = (ROOT / "_build").resolve()
    build.mkdir(exist_ok=True)
    if archive is None:
        subprocess.run([moon, "package", "--frozen"], cwd=ROOT, check=True)
        module = manifest_field(ROOT / "moon.mod", "name")
        version = manifest_field(ROOT / "moon.mod", "version")
        archive = build / "publish" / f"{module.replace('/', '-')}-{version}.zip"
    with tempfile.TemporaryDirectory(prefix="readme-check-", dir=build) as temporary:
        workspace = Path(temporary).resolve()
        assert workspace.parent == build
        with ZipFile(archive) as package:
            package.extractall(workspace)
        assert not (workspace / ".mooncakes").exists()
        assert not (workspace / "_build").exists()
        readme = (workspace / "README.md").read_text(encoding="utf-8")
        section = readme.split("## Reproduce a WAL history", 1)[1]
        match = re.search(r"```sh\s*\n(.*?)\n```", section, re.S)
        if match is None:
            raise RuntimeError("README history example has no shell command block")
        commands = [shlex.split(line) for line in match[1].splitlines() if line.strip()]
        reports = []
        executed = 0
        for documented in commands:
            command = list(documented)
            if command == ["moon", "update"] and skip_update:
                continue
            if command[0] == "moon":
                command[0] = moon
            elif command[0] in ("python", "python3"):
                command[0] = sys.executable
                command.insert(1, "-B")
            elif command[0] != "node":
                raise RuntimeError(f"unexpected README command {documented[0]}")
            process = subprocess.run(command, cwd=workspace, capture_output=True, encoding="utf-8")
            if process.returncode:
                raise RuntimeError(f"README command failed: {documented}\n{process.stdout}\n{process.stderr}")
            executed += 1
            if documented[0] == "node":
                if documented[-1] == "--help":
                    assert "wal-changes" in process.stdout and not process.stderr
                else:
                    reports.append((documented[2], json.loads(process.stdout)))
        assert [name for name, _ in reports] == [
            "wal-verify", "wal-history", "wal-rows", "wal-row", "wal-range", "wal-range",
            "wal-changes", "wal-changes", "wal-changes", "wal-series",
        ]
        verified, history, waiting, seek, first, last, forward, restored, net, series = (value for _, value in reports)
        assert verified == {"manifest_verified": True, "timeline": history}
        assert len(history["commits"]) == 5
        row, = [row for row in waiting["entries"] if row["rowid"] == "41"]
        assert row["values"][0] == {"type": "text", "value": "waiting"}
        assert seek == {"revision": waiting["revision"], "entries": [row]}
        assert seek["entries"][0]["source"]["revision"] == 1
        assert first["revision"] == last["revision"] == history["commits"][3]
        assert [entry["rowid"] for entry in first["entries"]] == ["41", "9007199254740993"]
        assert first["next_rowid"] == "9223372036854775807"
        assert [entry["rowid"] for entry in last["entries"]] == [first["next_rowid"]]
        assert last["next_rowid"] is None
        for result, old, new in ((forward, "ready", "waiting"), (restored, "waiting", "ready")):
            change, = result["entries"]
            assert change["kind"] == "changed" and change["after"]["rowid"] == "41"
            assert change["before"]["values"][0] == {"type": "text", "value": old}
            assert change["after"]["values"][0] == {"type": "text", "value": new}
        assert net["entries"] == []
        assert series["next_from"] == 2 and series["through"] == 2 and series["requested_to"] == 3
        assert series["entries"] == [forward, restored]
    print(f"README clean distribution demo: {len(commands)} documented commands ({executed} executed), "
          f"{len(reports)} JSON results validated")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-update", action="store_true", help="Use a registry index already present in MOON_HOME")
    parser.add_argument("--archive", type=Path, help="Use a downloaded release ZIP")
    options = parser.parse_args()
    verify(options.skip_update, options.archive)
