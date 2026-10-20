#!/usr/bin/env python3
"""Verify installed-ID cache cleanup through a native CLI, using unique fixtures only."""
from pathlib import Path
import argparse
import errno
import hashlib
import json
import os
import plistlib
import pty
import select
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid


root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary", nargs="?", type=Path, default=root / ".build/release/shou")
parser.add_argument("--evidence-dir", type=Path,
                    help="Create a new directory for native inventory, scope, receipt and hash evidence.")
parser.add_argument("--permanent", action="store_true",
                    help="After Trash restoration, also permanently remove only the generated cache.")
options = parser.parse_args()
if sys.platform != "darwin":
    parser.error("Native installed-application and Trash acceptance requires macOS.")
binary = options.binary.resolve(strict=True)
assert binary.is_file() and os.access(binary, os.X_OK), binary
token = uuid.uuid4().hex
identifier = "dev.shou.generated.cachecli." + token
home = Path.home()
applications, caches, preferences = home / "Applications", home / "Library/Caches", home / "Library/Preferences"
app = applications / ("Shou Cache CLI " + token + ".app")
cache, preference = caches / identifier, preferences / (identifier + ".plist")
allowed_roots = {app, cache, preference}
allowed_files = {
    app / "Contents/Info.plist", app / "Contents/MacOS/Generated", cache / "generated-cache.bin", preference,
}
allowed_directories = {app, app / "Contents", app / "Contents/MacOS", cache}
evidence = options.evidence_dir or root / ".build" / ("installed-cache-cli-" + token)
evidence = evidence.absolute()
assert not evidence.exists() and not evidence.is_symlink(), evidence
evidence.mkdir(parents=True)
created = {}
checks = 0
pending_trash = None


def record(label, value):
    destination = evidence / label
    assert destination.parent == evidence and not destination.is_symlink(), destination
    destination.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def identity(path):
    metadata = path.lstat()
    return metadata.st_dev, metadata.st_ino, stat.S_IFMT(metadata.st_mode), metadata.st_uid


def verify_fixture_parent(path):
    assert path in allowed_roots, path
    assert path.parent in {applications, caches, preferences}, path
    assert path.parent.is_dir() and path.parent.resolve(strict=True) == path.parent, path.parent
    assert not path.parent.is_symlink() and not path.exists() and not path.is_symlink(), path


def remember(path):
    assert path in allowed_roots and not path.is_symlink(), path
    created[path] = identity(path)


def hashes(include_cache=True):
    result = {}
    for path in sorted(allowed_files):
        if not include_cache and path.parent == cache:
            continue
        metadata = path.lstat()
        assert stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1 and metadata.st_uid == os.getuid(), path
        result[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def assert_target_paths(paths):
    # This helper has exactly one possible mutation target, never an application.
    assert paths == {str(cache)} and cache.parent == caches and cache.name == identifier, paths
    assert str(app) not in paths and str(preference) not in paths


def run(*arguments, expected=(0,), label=None):
    global checks
    process = subprocess.run([str(binary), *arguments, "--json"], env=environment,
                             stdin=subprocess.DEVNULL, capture_output=True, text=True,
                             start_new_session=True, timeout=120)
    result = json.loads(process.stdout)
    accepted = (expected,) if isinstance(expected, int) else expected
    if label:
        record(label, {"exit_code": process.returncode, "result": result, "stderr": process.stderr})
    assert process.returncode in accepted, (arguments, process.returncode, result, process.stderr)
    checks += 1
    return result


def confirm(arguments, phrase, action, irreversible=False, cancel=False):
    global checks
    assert arguments[0:2] in [["plan", "execute"], ["history", "restore"]], arguments
    output_read, output_write = os.pipe()
    pid, terminal = pty.fork()
    if pid == 0:
        os.close(output_read)
        os.dup2(output_write, 1)
        os.close(output_write)
        os.execve(str(binary), [str(binary), *arguments, "--json"], environment)
    os.close(output_write)
    readers, transcript, output = {terminal, output_read}, bytearray(), bytearray()
    sent = finished = False
    deadline = time.monotonic() + 120
    try:
        while readers and time.monotonic() < deadline:
            for descriptor in select.select(list(readers), [], [], 0.1)[0]:
                try:
                    data = os.read(descriptor, 65536)
                except OSError as error:
                    if descriptor == terminal and error.errno == errno.EIO:
                        data = b""
                    else:
                        raise
                if not data:
                    readers.remove(descriptor)
                else:
                    (transcript if descriptor == terminal else output).extend(data)
            if not sent and phrase.encode() in transcript:
                scope, _ = json.JSONDecoder().raw_decode(transcript.decode().lstrip())
                assert_target_paths({item["original_path"] for item in scope["items"]})
                assert scope["workspace"]["path"] == str(caches)
                assert scope["selected_item_count"] == 1 and len(scope["items"]) == 1
                assert scope["action"] == action and scope["irreversible"] is irreversible
                if action != "restore":
                    assert scope["items"][0]["rule_versions"] == {dynamic_rule: "1.0.0"}
                record(f"tty-{checks + 1:02d}-scope.json", scope)
                os.write(terminal, b"CANCEL\n" if cancel else phrase.encode() + b"\n")
                sent = True
        assert not readers and sent, transcript.decode(errors="replace")
        _, status = os.waitpid(pid, 0)
        finished = True
        result = json.loads(output)
        code = os.waitstatus_to_exitcode(status)
        record(f"tty-{checks + 1:02d}-result.json", {"exit_code": code, "result": result})
        assert code == 130 and result["error"]["code"] == "cancelled" if cancel else code == 0 and result["ok"], result
        checks += 1
        return result
    finally:
        if not finished:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(terminal)
        os.close(output_read)


def plan_for_generated_cache(mode):
    scan = run("scan", "--workspace", binding["id"], "--rule-id", dynamic_rule,
               "--scope", "cleanup", label=f"{mode}-scan.json")["data"]
    assert scan["status"] == "complete" and scan["scope"] == "cleanup", scan
    assert not any(issue in {"installed_application_cache:application_discovery_incomplete",
                             "installed_application_cache:application_discovery_unavailable"} for issue in scan["issues"]), scan
    snapshot_path = Path(environment["SHOU_DATA_DIR"]) / "scans" / (scan["scan_id"] + ".json")
    snapshot = json.loads(snapshot_path.read_text())
    assert snapshot["workspace"]["path"] == str(caches)
    assert {entry["path"] for entry in snapshot["entries"]} == {".", identifier, identifier + "/generated-cache.bin"}, "An unrelated cache subtree was inspected."
    evidence_items = snapshot["installed_application_caches"]
    assert len(evidence_items) == 1 and evidence_items[0]["rule_id"] == dynamic_rule
    assert evidence_items[0]["application"]["path"] == str(app)
    assert evidence_items[0]["application"]["bundle_identifier"] == identifier
    record(f"{mode}-snapshot.json", snapshot)
    results = run("scan", "results", "--scan-id", scan["scan_id"], "--limit", "500")["data"]
    assert results["next_cursor"] is None and results["total"] == 1, results
    selected = results["candidates"]
    assert len(selected) == 1 and selected[0]["eligible"] and selected[0]["relative_path"] == identifier
    assert selected[0]["rule_ids"] == [dynamic_rule], selected
    plan = run("plan", "create", "--scan-id", scan["scan_id"], "--candidate", selected[0]["id"],
               "--mode", mode, label=f"{mode}-plan.json")["data"]
    assert plan["action"] == mode and len(plan["items"]) == 1
    assert plan["items"][0]["candidate"]["relative_path"] == identifier
    assert plan["items"][0]["candidate"]["rule_ids"] == [dynamic_rule]
    assert {entry["path"] for entry in plan["items"][0]["manifest"]} == {".", "generated-cache.bin"}
    assert plan["installed_application_caches"] == evidence_items
    assert_target_paths({plan["workspace"]["path"] + "/" + item["candidate"]["relative_path"] for item in plan["items"]})
    return plan


def exercise():
    global environment, binding, dynamic_rule, pending_trash
    for generated in allowed_roots:
        verify_fixture_parent(generated)
    app.mkdir()
    remember(app)
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier, "CFBundleName": "Shou Generated Cache CLI",
        "CFBundlePackageType": "APPL", "CFBundleExecutable": "Generated", "CFBundleVersion": "1",
    }, fmt=plistlib.FMT_BINARY))
    (app / "Contents/MacOS/Generated").write_bytes(b"inert generated cache CLI application fixture")
    cache.mkdir()
    remember(cache)
    (cache / "generated-cache.bin").write_bytes(b"unique generated cache CLI fixture\n" * 1024)
    with preference.open("xb") as stream:
        stream.write(plistlib.dumps({"fixture": token, "retain": "generated personal preferences"}, fmt=plistlib.FMT_BINARY))
    remember(preference)
    original = hashes()
    record("fixture.json", {"identifier": identifier, "generated_paths": sorted(map(str, allowed_roots)),
                            "allowed_mutation_paths": [str(cache)], "original_hashes": original})
    with tempfile.TemporaryDirectory(prefix="shou-installed-cache-cli-") as temporary:
        base = Path(temporary).resolve()
        environment = dict(os.environ, SHOU_DATA_DIR=str(base / "records"))
        inventory_result = run("applications", "list", expected=(0, 6))
        inventory = inventory_result["data"]
        owner_rows = [item for item in inventory["items"] if (item.get("bundle_identifier") or "").lower() == identifier.lower()]
        record("native-inventory.json", {"status": inventory["status"], "sources": inventory["sources"],
                                         "issues": inventory["issues"], "unavailable_sources": inventory["unavailable_sources"],
                                         "application_count": len(inventory["items"]), "generated_owners": owner_rows})
        assert len(owner_rows) == 1 and owner_rows[0]["path"] == str(app) and owner_rows[0].get("info_digest"), owner_rows
        binding = run("workspaces", "add", "--path", str(caches), "--root-ref", "generated-cache-cli",
                      label="workspace.json")["data"]
        catalog = run("rules", "catalog", "--workspace", binding["id"])["data"]
        dynamic_rule = "shou.builtin.installed-cache." + hashlib.sha256(identifier.encode()).hexdigest()
        selected_rules = [rule for rule in catalog if rule["id"] == dynamic_rule]
        record("generated-rule.json", {"catalog_count": len(catalog), "selected_rules": selected_rules})
        if inventory["status"] != "complete":
            assert selected_rules == [], "Incomplete inventory must not authorize an installed-ID cache rule."
            refused = run("scan", "--workspace", binding["id"], "--rule-id", dynamic_rule,
                          "--scope", "cleanup", expected=2, label="incomplete-inventory-refusal.json")
            assert refused["error"]["code"] == "invalid_argument"
            assert run("history", "list")["data"] == []
            assert not list((base / "records/scans").glob("*.json"))
            assert hashes() == original
            record("summary.json", {"checks": checks, "native_inventory_complete": False,
                                    "incomplete_inventory_refused": True, "fixture_hashes_unchanged": True,
                                    "positive_native_execution": "unavailable", "permanent_generated_cache": False})
            print(f"{checks} installed-cache CLI guard checks passed; incomplete native inventory refused discovery and scanning; generated files unchanged. Positive native execution unavailable.")
            print(f"Evidence: {evidence}")
            return
        assert len(selected_rules) == 1, "Generated installed application did not receive an exact cache rule."
        rule = selected_rules[0]
        assert rule["match"]["relative_patterns"] == [identifier]
        assert rule["scope"]["root_ref"] == binding["root_ref"]
        assert rule["scope"]["follow_symlinks"] is False and rule["scope"]["cross_filesystems"] is False
        plan = plan_for_generated_cache("trash")
        invocation = ["plan", "execute", "--plan-id", plan["id"]]
        confirm(invocation, "TRASH " + plan["id"], "trash", cancel=True)
        assert hashes() == original
        assert run("history", "list")["data"] == []
        assert run("plan", "show", "--plan-id", plan["id"])["data"]["state"] == "ready"
        receipt = confirm(invocation, "TRASH " + plan["id"], "trash")["data"]
        assert receipt["state"] == "completed" and receipt.get("operation") is None and len(receipt["items"]) == 1
        item = receipt["items"][0]
        assert_target_paths({item["original_path"]})
        assert item["state"] == "trashed" and item.get("uninstall_origin") is None
        pending_trash = item["trash_path"]
        assert not cache.exists() and hashes(include_cache=False) == {p: h for p, h in original.items() if str(cache) + "/" not in p}
        assert len(run("history", "list")["data"]) == 1
        restored = confirm(["history", "restore", "--execution-id", receipt["id"], "--item", item["id"]],
                           "RESTORE " + receipt["id"], "restore")["data"]
        assert len(restored) == 1 and restored[0]["state"] == "completed" and hashes() == original
        assert identity(cache) == created[cache]
        pending_trash = None
        shown = run("history", "show", "--execution-id", receipt["id"], label="restored-history.json")["data"]
        assert len(shown["followups"]) == 1
        record("restored-hashes.json", hashes())
        if options.permanent:
            permanent = plan_for_generated_cache("permanent")
            removed = confirm(["plan", "execute", "--plan-id", permanent["id"]],
                              "PURGE " + permanent["id"], "permanent", irreversible=True)["data"]
            assert removed["state"] == "completed" and removed["operation"] == "permanent_cleanup" and len(removed["items"]) == 1
            assert removed["items"][0]["state"] == "purged" and removed["items"][0].get("trash_path") is None
            assert_target_paths({removed["items"][0]["original_path"]})
            assert not cache.exists() and hashes(include_cache=False) == {p: h for p, h in original.items() if str(cache) + "/" not in p}
            assert len(run("history", "list")["data"]) == 2
            record("retained-after-permanent.json", hashes(include_cache=False))
        record("summary.json", {"checks": checks, "native_inventory_complete": True,
                                "only_generated_cache_scanned_and_selected": True,
                                "tty_cancel_unchanged": True, "trash_and_history_restore": True,
                                "restored_hashes_equal": True, "application_and_preferences_retained": True,
                                "permanent_generated_cache": options.permanent})
    print(f"{checks} installed-cache CLI checks passed; generated cache only, real TTY cancellation and native Trash restoration verified.")
    print(f"Evidence: {evidence}")

try:
    exercise()
except BaseException as error:
    record("failure.json", {"type": type(error).__name__, "message": str(error), "pending_generated_trash": pending_trash})
    raise
finally:
    # Never sweep a parent directory, follow a link, or remove a replaced fixture.
    refused = []
    for generated, saved_identity in reversed(list(created.items())):
        if not generated.exists() and not generated.is_symlink():
            continue
        if generated not in allowed_roots or identity(generated) != saved_identity or generated.is_symlink():
            refused.append(str(generated))
            continue
        descendants = [generated] if generated.is_file() else [generated, *generated.rglob("*")]
        if any(path.is_symlink() or (path.is_dir() and path not in allowed_directories)
               or (path.is_file() and path not in allowed_files)
               or (not path.is_dir() and not path.is_file()) for path in descendants):
            refused.append(str(generated))
            continue
        if generated.is_file():
            generated.unlink()
        else:
            shutil.rmtree(generated)
    record("fixture-cleanup.json", {"refused_changed_paths": refused, "pending_generated_trash": pending_trash,
                                   "removed_only_owned_unique_fixtures": not refused})
