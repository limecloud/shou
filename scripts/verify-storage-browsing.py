#!/usr/bin/env python3
"""Check paged browsing and shared selection against a real, isolated desktop bridge."""
import argparse
import os
from pathlib import Path
import tempfile
from importlib.util import module_from_spec, spec_from_file_location

spec = spec_from_file_location("desktop_bridge_checks", Path(__file__).with_name("verify-desktop-bridge.py"))
bridge = module_from_spec(spec)
spec.loader.exec_module(bridge)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine", type=Path, required=True)
    args = parser.parse_args()
    engine = args.engine.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="shou-browse-", dir=Path.home() if os.name == "nt" else None) as temporary:
        root = Path(temporary).resolve()
        workspace = root / "project 中文 & literal"
        workspace.mkdir()
        for index in range(203):
            (workspace / f"entry-{index:03}.txt").write_text("generated fixture", encoding="utf-8")
        for path in ["parent/a/file.bin", "parent/b/keep.bin", "blocked/retain.bin"]:
            target = workspace / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"generated fixture" * 256)
        bridge.set_fixture_owner(workspace)
        environment = dict(os.environ, SHOU_DATA_DIR=str(root / "records"))

        def success(operation, values=None):
            result, reviewed = bridge.request(engine, environment, operation, values)
            assert result["ok"] and not reviewed, result
            return result["data"]

        def snapshot():
            return {str(path.relative_to(root / "records")): (path.read_bytes(), path.stat().st_mtime_ns)
                    for path in (root / "records").rglob("*.json")}

        registered = success("workspace.add", dict(path=str(workspace), root_ref="browse-fixture"))
        success("exclusions.set", dict(workspace_id=registered["id"], pattern="blocked/**", remove=False))
        scan = success("storage.scan", dict(path=str(workspace)))
        assert len(scan["directory"]["children"]) == 200 and scan["directory"]["total_count"] == 205
        assert scan["directory"]["next_offset"] == 200
        identifier = scan["scan_id"]
        before = snapshot()
        browse = success("storage.browse", dict(scan_id=identifier, path="."))
        assert browse["directory"]["total_count"] == 205 and len(browse["directory"]["children"]) == 200
        assert browse["removal_reasons"]["blocked"] == "This selection contains excluded content."
        tail = success("storage.browse", dict(scan_id=identifier, path=".", offset=200))
        first_paths = {item["node"]["path"] for item in browse["directory"]["children"]}
        tail_paths = {item["node"]["path"] for item in tail["directory"]["children"]}
        assert len(tail_paths) == 5 and first_paths.isdisjoint(tail_paths) and tail["directory"].get("next_offset") is None
        nested = success("storage.browse", dict(scan_id=identifier, path="parent/a"))
        assert [item["node"]["path"] for item in nested["directory"]["children"]] == ["parent/a/file.bin"]
        print("PASS bounded initial results, exact pagination, nested navigation and current exclusion reasons", flush=True)

        def selection(paths, targets, selected):
            return success("storage.selection", dict(scan_id=identifier, paths=paths, targets=targets, selected=selected))

        parent = selection([], ["parent", "parent/a/file.bin"], True)
        assert parent["paths"] == ["parent"]
        reduced = selection(parent["paths"], ["parent/a/file.bin"], False)
        assert reduced["paths"] == ["parent/b"] and reduced["allocated_bytes"] < parent["allocated_bytes"]
        combined = selection(reduced["paths"], ["entry-000.txt", "parent"], True)
        assert combined["paths"] == ["entry-000.txt", "parent"]
        assert selection(combined["paths"], ["parent"], False)["paths"] == ["entry-000.txt"]
        assert snapshot() == before
        assert not list((root / "records" / "storage-plans").glob("*.json"))
        print("PASS parent-child normalization, covered-child exclusion, retained siblings and deduplicated capacity", flush=True)
        valid = dict(scan_id=identifier, paths=[], targets=["parent"], selected=True)
        for operation, values in [
            ("storage.browse", dict(scan_id=identifier, path="../parent")),
            ("storage.browse", dict(scan_id=identifier, offset=0.5)),
            ("storage.browse", dict(scan_id=identifier, path=False)),
            ("storage.browse", dict(scan_id=identifier, extra=True)),
            ("storage.selection", dict(valid, selected="true")),
            ("storage.selection", dict(valid, targets=["parent", "parent"])),
            ("storage.selection", dict(valid, targets=["."])),
            ("storage.selection", dict(valid, targets=["absent"])),
            ("storage.selection", dict(valid, targets=["blocked"])),
            ("storage.selection", dict(valid, targets=[f"entry-{index}.txt" for index in range(5001)])),
            ("storage.selection", dict(valid, extra=True))]:
            result, reviewed = bridge.request(engine, environment, operation, values)
            assert not result["ok"] and not reviewed, result
        assert snapshot() == before
        success("exclusions.set", dict(workspace_id=registered["id"], pattern="parent/b/**", remove=False))
        refreshed = success("storage.browse", dict(scan_id=identifier))
        assert refreshed["removal_reasons"]["parent"] == "This selection contains excluded content."
        result, reviewed = bridge.request(engine, environment, "storage.selection", valid)
        assert not result["ok"] and not reviewed and result["error"]["code"] == "permission_denied"
        assert (workspace / "parent/b/keep.bin").exists() and (workspace / "blocked/retain.bin").exists()
        print("PASS malformed, absent, root, oversized and newly protected selections refused without mutations", flush=True)


if __name__ == "__main__":
    main()
