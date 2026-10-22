#!/usr/bin/env python3
"""Verify saved scan coverage across space and large-file read-only requests."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, default=root / ".build/debug/shou")
    args = parser.parse_args()
    engine = args.engine.resolve(strict=True)
    spec = importlib.util.spec_from_file_location("desktop_fixture", root / "scripts/verify-desktop-bridge.py")
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    with tempfile.TemporaryDirectory(prefix="shou-coverage-", dir=root / ".build" if os.name == "nt" else None) as temporary:
        base = Path(temporary).resolve()
        folder = base / "generated 中文 & literal"
        folder.mkdir()
        for index in range(503):
            (folder / f"file-{index:03}.bin").write_bytes(b"generated read-only coverage fixture")
        (folder / "video.mp4").write_bytes(b"generated video extension fixture")
        bridge.set_fixture_owner(folder)
        environment = dict(os.environ, SHOU_DATA_DIR=str(base / "records"))

        def success(operation, values=None):
            result, reviewed = bridge.request(engine, environment, operation, values)
            assert result["ok"] and not reviewed, result
            return result["data"]

        def records():
            return {str(path.relative_to(base / "records")): (path.read_bytes(), path.stat().st_mtime_ns)
                    for path in (base / "records").rglob("*.json")}

        def payloads():
            return {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in folder.iterdir()}

        fields = ("scan_id", "root_path", "status", "entry_count", "issues", "coverage_notes")
        original = payloads()
        scan = success("storage.scan", dict(path=str(folder)))
        assert scan["status"] == "complete" and scan["entry_count"] == 505 and scan["coverage_notes"] == []
        before = records()
        show = success("storage.show", dict(scan_id=scan["scan_id"]))
        large = success("storage.large-files", dict(scan_id=scan["scan_id"], minimum_bytes=0))
        tail = success("storage.large-files", dict(scan_id=scan["scan_id"], minimum_bytes=0, cursor=large["next_cursor"]))
        video = success("storage.large-files", dict(scan_id=scan["scan_id"], minimum_bytes=0, type="video"))
        assert len(large["entries"]) == 500 and len(tail["entries"]) == 4 and video["total_count"] == 1
        for value in (show, large, tail, video):
            assert {key: value[key] for key in fields} == {key: scan[key] for key in fields}, value
        assert records() == before and payloads() == original
        print("PASS complete space/show/large-file/filter/paging share the same saved coverage without changing records or payloads", flush=True)

        bounded = subprocess.run([str(engine), "analysis", "scan", "--path", str(folder), "--max-entries", "2", "--json"],
                                 capture_output=True, env=environment, timeout=30)
        result = json.loads(bounded.stdout)
        assert bounded.returncode in (0, 6) and result.get("data", {}).get("status") == "partial", result
        partial = result["data"]
        before = records()
        show = success("storage.show", dict(scan_id=partial["scan_id"]))
        large = success("storage.large-files", dict(scan_id=partial["scan_id"], minimum_bytes=0))
        assert show["status"] == large["status"] == "partial" and show["entry_count"] == large["entry_count"] == 2
        assert show["issues"] == large["issues"] == partial["issues"] and show["coverage_notes"] == large["coverage_notes"]
        assert show["coverage_notes"] and len(show["coverage_notes"]) == len(show["issues"])
        for note, issue in zip(show["coverage_notes"], show["issues"]):
            code, _, path = issue.partition(": ")
            assert note["code"] == code and note["path"] == path and isinstance(note["system_managed"], bool)
        assert records() == before and payloads() == original
        for operation in ("storage.show", "storage.large-files"):
            rejected, reviewed = bridge.request(engine, environment, operation, dict(scan_id="missing_generated_scan"))
            assert not rejected["ok"] and not reviewed
        assert not list((base / "records/storage-plans").glob("*.json"))
        assert not list((base / "records/history").glob("*.json"))
        assert payloads() == original
        print("PASS real bounded partial scan preserves unknown coverage across views; missing scans refuse without deletion plans or history", flush=True)


if __name__ == "__main__":
    main()
