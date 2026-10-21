#!/usr/bin/env python3
"""Check analysis discovery, paging, selections and refusal without a TTY."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
binary = (Path(sys.argv[1]) if len(sys.argv) > 1 else root / ".build/debug/shou").resolve()
checks = 0
with tempfile.TemporaryDirectory(prefix="shou-storage-cli-") as temporary:
    base = Path(temporary).resolve()
    workspace = base / "files"
    (workspace / "build/cache").mkdir(parents=True)
    (workspace / "build/cache/generated.bin").write_bytes(b"generated" * 4096)
    (workspace / "personal.txt").write_text("retain fixture content")
    env = dict(os.environ, SHOU_DATA_DIR=str(base / "records"))

    def run(*args, success=True):
        global checks
        p = subprocess.run([str(binary), *args, "--json"], env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, start_new_session=True, timeout=30)
        result = json.loads(p.stdout)
        assert result["ok"] == success, (args, p.returncode, result, p.stderr)
        checks += 1
        return result

    scan = run("analysis", "scan", "--path", str(workspace))["data"]
    scan_id = scan["scan_id"]
    assert scan["status"] == "complete"
    assert run("workspaces", "list")["data"] == []
    summary = run("analysis", "summary", "--scan-id", scan_id)["data"]
    assert summary["root"]["allocated_bytes"] > 0
    page = run("analysis", "children", "--scan-id", scan_id, "--limit", "1")["data"]
    assert page["total"] == 2 and page["next_cursor"]
    second = run("analysis", "children", "--scan-id", scan_id, "--limit", "1", "--cursor", page["next_cursor"])["data"]
    assert page["entries"][0]["node"]["path"] != second["entries"][0]["node"]["path"]
    run("analysis", "children", "--scan-id", scan_id, "--path", "build", "--cursor", page["next_cursor"], success=False)
    context = run("analysis", "context", "--scan-id", scan_id, "--path", "build", "--locale", "zh-CN")["data"]
    assert context["context"]["presentation"]["scan_id"] == scan_id
    assert "analysis children" in context["text"] and str(workspace / "build/cache") in context["text"]
    assert context["context"]["selected_paths"] == []
    nested = run("analysis", "map", "--scan-id", scan_id, "--path", "build")["data"]
    assert nested["scope"]["node"]["path"] == "build"
    assert any(item["node"]["path"] == "build/cache/generated.bin" for item in nested["items"])
    assert nested["extensions"]["items"][0]["suffix"] == "bin"
    run("analysis", "context", "--scan-id", scan_id, "--path", "../", success=False)
    for mode in ("trash", "permanent"):
        plan = run("analysis", "plan", "--scan-id", scan_id, "--path", "build", "--path", "build/cache", "--path", "personal.txt", "--mode", mode)["data"]
        assert len(plan["items"]) == 2 and plan["action"] == mode
        assert run("analysis", "plan", "show", "--plan-id", plan["id"])["data"]["digest"] == plan["digest"]
        refused = run("analysis", "remove", "--plan-id", plan["id"], success=False)
        assert refused["error"]["code"] == "confirmation_required"
    for path in (".", "../personal.txt", "/personal.txt", "missing", "build//cache"):
        run("analysis", "plan", "--scan-id", scan_id, "--path", path, success=False)
    run("analysis", "scan", "--path", str(workspace), "--max-entries", "0", success=False)
    partial = run("analysis", "scan", "--path", str(workspace), "--max-entries", "2", success=False)["data"]
    assert partial["status"] == "partial"
    assert (workspace / "personal.txt").read_text() == "retain fixture content"
    assert (workspace / "build/cache/generated.bin").read_bytes() == b"generated" * 4096
    assert run("history", "list")["data"] == []
print(f"{checks} storage CLI checks passed; no file removal was authorized.")
