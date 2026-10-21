#!/usr/bin/env python3
"""Verify native permanent cleanup using newly generated hard-linked fixtures only."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True,
                        help="New directory for generated files, records and retained evidence")
    args = parser.parse_args()
    engine = args.engine.resolve(strict=True)
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location("shou_bridge", Path(__file__).with_name("verify-desktop-bridge.py"))
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    workspace = evidence / "workspace"
    workspace.mkdir()
    payload = bytes(range(256)) * 4096
    retained = workspace / "retained.bin"
    retained.write_bytes(payload)
    before = hashlib.sha256(payload).hexdigest()
    targets = [workspace / "generated-a", workspace / "generated-b"]
    for target in targets:
        (target / "nested").mkdir(parents=True)
        os.link(retained, target / "a.bin")
        os.link(retained, target / "nested/z.bin")
        (target / "ordinary.bin").write_bytes(b"independent generated fixture")
    removed_inode = targets[0] / "only-selected.bin"
    removed_inode.write_bytes(payload)
    os.link(removed_inode, targets[1] / "only-selected.bin")
    environment = dict(os.environ, SHOU_DATA_DIR=str(evidence / "records"))

    def request(operation, values=None, confirmation="cancel"):
        result, _ = bridge.request(engine, environment, operation, values, confirmation=confirmation)
        assert result["ok"], result
        return result["data"]

    root = request("workspace.add", dict(path=str(workspace), root_ref="hardlink-fixture"))
    rule = dict(schema_version="1.0", id="test.permanent-hardlinks", version="1.0.0",
                name="Generated hard-link fixtures", description="Isolated native deletion verification.",
                platforms=["macos"],
                scope=dict(root_ref="hardlink-fixture", max_depth=8, follow_symlinks=False, cross_filesystems=False),
                match=dict(kind="directory", relative_patterns=["generated-*"]),
                conditions=dict(min_allocated_bytes=0), exclude=dict(relative_patterns=[]),
                risk=dict(declared_level="review", rebuild_note="Generated test data.", limitations=["Test data only."]),
                action=dict(type="trash"))
    request("rules.import", dict(json=json.dumps(rule)))
    request("rules.set", dict(workspace_id=root["id"], rule_id=rule["id"], enabled=True))
    scan = request("scan", dict(workspace_id=root["id"]))
    candidates = [item for item in scan["candidates"] if item["eligible"]]
    assert len(candidates) == 2, scan
    plan = request("plan", dict(scan_id=scan["scan_id"], candidate_ids=[item["id"] for item in candidates], action="permanent"))
    # Keep a read-only descriptor only for observing the inode's final link count.
    # Closing it after verification allows the OS to reclaim its remaining blocks.
    descriptor = os.open(removed_inode, os.O_RDONLY)
    try:
        receipt = request("plan.execute", dict(plan_id=plan["id"]), confirmation="accept")
        removed_links = os.fstat(descriptor).st_nlink
    finally:
        os.close(descriptor)
    after = hashlib.sha256(retained.read_bytes()).hexdigest()
    report = dict(engine=str(engine), receipt=receipt, selected_targets_absent=all(not target.exists() for target in targets),
                  retained_sha256_before=before, retained_sha256_after=after, retained_links=retained.stat().st_nlink,
                  selected_inode_remaining_links=removed_links)
    (evidence / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    assert receipt["state"] == "completed" and all(item["state"] == "purged" for item in receipt["items"]), report
    assert report["selected_targets_absent"] and before == after and report["retained_links"] == 1, report
    assert removed_links == 0, report
    fresh = request("scan", dict(workspace_id=root["id"]))
    assert fresh["total_count"] == 0, fresh
    print("PASS native hard-link cleanup: both targets absent, selected inode has zero links, retained file hash unchanged, fresh scan empty.")


if __name__ == "__main__":
    main()
