#!/usr/bin/env python3
"""Verify scan scope inspection and configuration-only removal in isolated fixtures."""
import argparse
import json
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
    with tempfile.TemporaryDirectory(prefix="shou-scope-", dir=Path.home() if os.name == "nt" else None) as temporary:
        root = Path(temporary).resolve()
        workspace = root / "extra 中文 project"
        workspace.mkdir()
        (workspace / "generated").mkdir()
        (workspace / "generated/keep.txt").write_text("retain fixture data", encoding="utf-8")
        other = root / "other project"
        other.mkdir()
        bridge.set_fixture_owner(workspace)
        environment = dict(os.environ, SHOU_DATA_DIR=str(root / "records"))

        def success(operation, values=None):
            result, _ = bridge.request(engine, environment, operation, values)
            assert result["ok"], result
            return result["data"]

        def config():
            return success("configuration")["configuration"]

        def snapshot():
            return {str(path.relative_to(root / "records")): (path.read_bytes(), path.stat().st_mtime_ns)
                    for path in (root / "records").rglob("*.json")}

        platform = success("capabilities")["platform"]
        registered = success("workspace.add", dict(path=str(workspace), root_ref="scope-fixture"))
        remaining = success("workspace.add", dict(path=str(other), root_ref="other-fixture"))
        rule = dict(schema_version="1.0", id="test.scope-fixture", version="0.1.0", name="Generated fixture",
                    description="Only generated test data", platforms=[platform],
                    scope=dict(root_ref="scope-fixture", max_depth=3, follow_symlinks=False, cross_filesystems=False),
                    match=dict(kind="directory", relative_patterns=["generated"]),
                    conditions=dict(min_allocated_bytes=0, newest_descendant_modified_days_at_least=0),
                    exclude=dict(relative_patterns=[]),
                    risk=dict(declared_level="review", rebuild_note="Generated fixture", limitations=["Test data only"]),
                    action=dict(type="trash"))
        success("rules.import", dict(json=json.dumps(rule)))
        success("rules.set", dict(workspace_id=registered["id"], rule_id=rule["id"], enabled=True))
        success("exclusions.set", dict(workspace_id=registered["id"], pattern="retain-unrelated", remove=False))
        success("presets.save", dict(workspace_id=registered["id"], name="Scope fixture", configuration_revision=config()["revision"]))
        before = snapshot()
        inventory = success("locations.scan")
        entry = next(item for item in inventory["entries"] if item.get("workspace_id") == registered["id"])
        assert entry["origin"] == "included" and entry["can_remove"] and entry["availability"] == "available", entry
        assert all(not item["can_remove"] for item in inventory["entries"] if item["origin"] != "included")
        assert inventory["configuration_revision"] == config()["revision"] and snapshot() == before
        assert not list((root / "records" / "scans").glob("*.json"))
        print("PASS metadata-only inventory preserves configuration and creates no scan", flush=True)
        values = dict(workspace_id=registered["id"], configuration_revision=inventory["configuration_revision"])
        for operation, invalid in [("locations.scan", dict(path=str(workspace))),
                                   ("workspace.remove", dict(values, extra=True)),
                                   ("workspace.remove", dict(workspace_id=registered["id"])),
                                   ("workspace.remove", dict(values, workspace_id=3)),
                                   ("workspace.remove", dict(values, workspace_id="automatic-or-foreign"))]:
            result, confirmed = bridge.request(engine, environment, operation, invalid)
            assert not result["ok"] and not confirmed, result
        assert snapshot() == before
        print("PASS unknown input, malformed IDs and unmanaged locations rejected before review", flush=True)
        for control in ["cancel", "wrong", "wrong-digest", "eof"]:
            result, confirmed = bridge.request(engine, environment, "workspace.remove", values, control)
            assert confirmed and not result["ok"], result
            assert snapshot() == before and (workspace / "generated/keep.txt").read_text() == "retain fixture data"
        print("PASS cancellation, mismatched confirmation and disconnected review preserve scope", flush=True)
        success("exclusions.set", dict(pattern="unrelated-global", remove=False))
        result, confirmed = bridge.request(engine, environment, "workspace.remove", values, "accept")
        assert not confirmed and not result["ok"] and result["error"]["code"] == "plan_stale", result
        values["configuration_revision"] = success("locations.scan")["configuration_revision"]

        def change_during_review(review):
            assert review["review"]["items"][0]["path"] == str(workspace).replace("\\", "/"), review
            success("exclusions.set", dict(pattern="changed-during-review", remove=False))

        result, confirmed = bridge.request(engine, environment, "workspace.remove", values, "accept", change_during_review)
        assert confirmed and not result["ok"] and result["error"]["code"] == "plan_stale", result
        assert any(item["id"] == registered["id"] for item in config()["workspaces"])
        print("PASS configuration changes before and during confirmation invalidate removal", flush=True)
        current = config()
        values["configuration_revision"] = success("locations.scan")["configuration_revision"]
        result, confirmed = bridge.request(engine, environment, "workspace.remove", values, "accept")
        assert confirmed and result["ok"] and result["data"]["removed"], result
        after = config()
        assert [item["id"] for item in after["workspaces"]] == [remaining["id"]]
        assert not after["bindings"] and not after["presets"]
        assert after["rules"] == current["rules"] and after["global_exclusions"] == current["global_exclusions"]
        assert (workspace / "generated/keep.txt").read_text() == "retain fixture data"
        assert not any(item.get("workspace_id") == registered["id"] for item in success("locations.scan")["entries"])
        print("PASS confirmed removal detaches only the reviewed extra folder and retains files and rules", flush=True)


if __name__ == "__main__":
    main()
