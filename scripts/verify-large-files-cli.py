#!/usr/bin/env python3
"""Verify saved large-file discovery and reviewed removal refusal on fixtures."""
from pathlib import Path
import argparse
from datetime import datetime
import hashlib
import json
import os
import subprocess
import tempfile


root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary", nargs="?", type=Path, default=root / ".build/release/shou")
parser.add_argument("--evidence-dir", type=Path)
args = parser.parse_args()
binary = args.binary.resolve()
evidence = (args.evidence_dir or root / ".build" / ("storage-large-files-" + datetime.now().strftime("%Y%m%d-%H%M%S"))).resolve()
evidence.mkdir(parents=True, exist_ok=True)
checks = 0

with tempfile.TemporaryDirectory(prefix="shou-large-files-cli-") as temporary:
    base = Path(temporary).resolve()
    workspace = base / "files"
    workspace.mkdir()
    contents = {
        "a/video.MP4": 65_536, "z/video.mp4": 65_536, "song.FLAC": 32_768,
        "photo.NEF": 16_384, "archive.zip": 8192, "report.pdf": 4096,
        "model.GGUF": 12_288, "weights.safetensors": 12_288, "opaque.bin": 8192,
    }
    for name, size in contents.items():
        path = workspace / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(bytes(range(256)) * (size // 256))
    with (workspace / "sparse.mov").open("wb") as stream:
        stream.truncate(16 * 1024 * 1024)
    os.link(workspace / "a/video.MP4", workspace / "z/video-alias.mp4")
    os.symlink("opaque.bin", workspace / "opaque-link.mp4")
    env = dict(os.environ, SHOU_DATA_DIR=str(base / "records"))

    def run(*arguments, code=0):
        global checks
        process = subprocess.run([str(binary), *arguments, "--json"], env=env,
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                 start_new_session=True, timeout=30)
        result = json.loads(process.stdout)
        assert process.returncode == code, (arguments, process.returncode, result, process.stderr)
        assert result["ok"] == (code == 0), (arguments, result)
        checks += 1
        label = "-".join(arguments[:2]).replace("/", "-")
        (evidence / f"{checks:02d}-{label}.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        return result

    capabilities = run("capabilities", "--command", "analysis large-files")["data"]
    command, = capabilities["commands"]
    assert command["command"] == "analysis large-files" and command["side_effect"] == "read"
    schema = command["input_schema"]
    assert schema["required"] == ["scan-id"] and schema["additionalProperties"] is False
    assert schema["properties"]["minimum-bytes"]["default"] == 50 * 1024 * 1024
    assert schema["properties"]["limit"]["maximum"] == 500
    assert "ai-model" in schema["properties"]["type"]["enum"]
    help_text = run("analysis", "large-files", "--help")["data"]
    assert all(word in help_text for word in ["--minimum-bytes", "--type", "--limit", "--cursor", "50 MiB", "analysis plan", "analysis remove"])

    scan = run("analysis", "scan", "--path", str(workspace))["data"]
    scan_id = scan["scan_id"]
    assert scan["status"] == "complete"
    stored = json.loads((base / "records/storage-scans" / (scan_id + ".json")).read_text())
    assert stored["catalog_id"] == scan_id
    catalogs = list((base / "records/storage-catalogs").glob("*"))
    assert len(catalogs) == 1
    catalog_digest = hashlib.sha256(catalogs[0].read_bytes()).hexdigest()

    default = run("analysis", "large-files", "--scan-id", scan_id)["data"]
    assert default["total"] == 0 and default["minimum_bytes"] == 50 * 1024 * 1024
    all_files = run("analysis", "large-files", "--scan-id", scan_id, "--minimum-bytes", "0")["data"]
    assert all_files["metric"] == "allocated_bytes_estimate" and all_files["type_detection"] == "filename_extension"
    assert all_files["sort"] == "allocated_bytes_desc_path_asc"
    rows = all_files["entries"]
    assert len(rows) == all_files["total"] == 11
    assert all("removal_block_reason" in row and row["entry"]["kind"] == "file" for row in rows)
    expected_order = sorted(rows, key=lambda row: (-row["node"]["allocated_bytes"], row["entry"]["path"].encode()))
    assert rows == expected_order
    expected_paths = [row["entry"]["path"] for row in rows]
    expected_allocated = sum(row["node"]["allocated_bytes"] for row in rows)
    assert all_files["total_allocated_bytes"] == expected_allocated
    assert next(row for row in rows if row["entry"]["path"] == "z/video-alias.mp4")["node"]["allocated_bytes"] == 0
    sparse = next(row for row in rows if row["entry"]["path"] == "sparse.mov")
    assert sparse["node"]["logical_bytes"] > sparse["node"]["allocated_bytes"]

    paged, cursor = [], None
    while True:
        options = ["--cursor", cursor] if cursor else []
        page = run("analysis", "large-files", "--scan-id", scan_id, "--minimum-bytes", "0", "--limit", "2", *options)["data"]
        assert page["total"] == len(rows) and page["total_allocated_bytes"] == expected_allocated
        paged.extend(row["entry"]["path"] for row in page["entries"])
        cursor = page["next_cursor"]
        if not cursor:
            break
    assert paged == expected_paths
    first = run("analysis", "large-files", "--scan-id", scan_id, "--minimum-bytes", "0", "--limit", "1")["data"]
    for changed in [["--minimum-bytes", "1"], ["--minimum-bytes", "0", "--type", "video"]]:
        refused = run("analysis", "large-files", "--scan-id", scan_id, "--cursor", first["next_cursor"], *changed, code=2)
        assert refused["error"]["code"] == "invalid_argument"
    for kind, expected in {"ai-model": {"model.GGUF", "weights.safetensors"}, "video": {"a/video.MP4", "z/video.mp4"}, "image": {"photo.NEF"}, "audio": {"song.FLAC"}, "archive": {"archive.zip"}, "document": {"report.pdf"}}.items():
        filtered = run("analysis", "large-files", "--scan-id", scan_id, "--minimum-bytes", "1", "--type", kind)["data"]
        assert {row["entry"]["path"] for row in filtered["entries"]} == expected
    for options in [["--limit", "0"], ["--limit", "501"], ["--minimum-bytes", "-1"], ["--type", "unknown"], ["--cursor", "invalid!"]]:
        refused = run("analysis", "large-files", "--scan-id", scan_id, *options, code=2)
        assert refused["error"]["code"] == "invalid_argument"

    # The saved scan root is temporarily absent. A fresh traversal cannot succeed.
    offline = base / "files-offline"
    workspace.rename(offline)
    try:
        reused = run("analysis", "large-files", "--scan-id", scan_id, "--minimum-bytes", "0")["data"]
        assert reused["entries"] == rows
    finally:
        offline.rename(workspace)
    assert hashlib.sha256(catalogs[0].read_bytes()).hexdigest() == catalog_digest
    assert len(list((base / "records/storage-scans").glob("*.json"))) == 1

    selected = "model.GGUF"
    original = (workspace / selected).read_bytes()
    for mode in ["trash", "permanent"]:
        plan = run("analysis", "plan", "--scan-id", scan_id, "--path", selected, "--mode", mode)["data"]
        assert plan["action"] == mode and len(plan["items"]) == 1
        shown = run("analysis", "plan", "show", "--plan-id", plan["id"])["data"]
        assert shown["digest"] == plan["digest"]
        refused = run("analysis", "remove", "--plan-id", plan["id"], code=7)
        assert refused["error"]["code"] == "confirmation_required"
        assert (workspace / selected).read_bytes() == original
    (workspace / selected).write_bytes(b"changed generated fixture after scan")
    stale = run("analysis", "plan", "--scan-id", scan_id, "--path", selected, code=4)
    assert stale["error"]["code"] == "plan_stale"
    assert run("history", "list")["data"] == []
    for name in contents:
        assert (workspace / name).is_file()

summary = f"{checks} large-file CLI checks passed; saved catalog reused, both non-TTY removal modes refused, no removal executed."
(evidence / "summary.txt").write_text(summary + "\n")
print(summary)
print(f"Evidence: {evidence}")
