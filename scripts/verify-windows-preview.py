#!/usr/bin/env python3
"""Check preview worker boundaries and generated streams without activating providers."""
import argparse
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--native-harness", type=Path, help="Windows-only generated read-only stream checks; no installed provider activated")
    args = parser.parse_args()
    engine = args.engine.resolve(strict=True)
    windows = os.name == "nt"
    with tempfile.TemporaryDirectory(prefix="shou-preview-protocol-") as temporary:
        base = Path(temporary).resolve()
        records = base / "never-open-records"
        environment = dict(os.environ, SHOU_DATA_DIR=str(records))

        def request(data, expected, extra=(), exit_code=1):
            result = subprocess.run([str(engine), "--native-preview-worker", *extra], input=data,
                                    capture_output=True, env=environment, timeout=15)
            assert result.returncode == exit_code and not result.stderr, result
            assert len(result.stdout) < 1024 and len(result.stdout.splitlines()) == 1, result
            value = json.loads(result.stdout)
            assert value == {"version": 1, "kind": "error", "code": expected}, value
            assert not records.exists(), "Read-only worker opened the record store"

        request(b"{}", "invalid_preview", ("--json",), exit_code=2)
        for data in (b"", b"not-json", b"{}", b"[]", b"x" * 65537):
            request(data, "invalid_preview")
        identity = {"volume": 1, "file_id": "a" * 32, "owner_sid": "S-1-5-21-1234"}

        def entry(path, kind):
            return dict(path=path, kind=kind, device=1, inode=0, logical_bytes=4096, allocated_bytes=4096,
                        modified_nanoseconds=100, changed_nanoseconds=100, mode=32 if kind == "file" else 16,
                        owner=0, links=1, windows_identity=identity)

        payload = dict(version=1, parent_pid=os.getpid(), host_window=0, preview=dict(
            root_path="C:/shou-generated-preview-not-created", root_identity=entry(".", "directory"),
            file=entry("report.pdf", "file")))
        invalid = [payload]
        for name in ("../report.pdf", "folder\\..\\report.pdf", "report.pdf:stream", "report.pdf.exe", "script.js", "report.lnk", "page.html"):
            item = copy.deepcopy(payload)
            item["host_window"] = 1
            item["preview"]["file"]["path"] = name
            invalid.append(item)
        for field, value in (("version", 2), ("parent_pid", 0), ("host_window", -1), ("unknown", True)):
            item = copy.deepcopy(payload)
            item[field] = value
            invalid.append(item)
        item = copy.deepcopy(payload)
        item["host_window"] = 1
        item["preview"]["root_identity"].pop("windows_identity")
        invalid.append(item)
        for item in invalid:
            request(json.dumps(item).encode(), "invalid_preview")
        if not windows:
            payload["host_window"] = 1
            request(json.dumps(payload).encode(), "capability_unavailable")
        print(f"PASS {6 + len(invalid) + (not windows)} real preview worker argument/input/host/path/format/size boundaries and unopened record store; no installed provider activated", flush=True)
        if args.native_harness:
            assert windows, "Native preview stream harness requires Windows."
            subprocess.run([str(args.native_harness.resolve(strict=True)), str(base)], check=True, timeout=60, env=environment)
            assert not records.exists()


if __name__ == "__main__":
    main()
