#!/usr/bin/env python3
"""Exercise summary and batch contracts using uniquely generated applications only."""
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
import subprocess
import tempfile
import time
import uuid


root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary", nargs="?", type=Path, default=root / ".build/release/shou")
parser.add_argument("--evidence-dir", type=Path, default=root / ".build/application-batch-cli")
arguments = parser.parse_args()
binary, evidence = arguments.binary.resolve(), arguments.evidence_dir.resolve()
evidence.mkdir(parents=True, exist_ok=True)
base = Path(tempfile.mkdtemp(prefix="shou-application-batch-cli-")).resolve()
environment = dict(os.environ, SHOU_DATA_DIR=str(base / "records"))
identifier = "dev.shou.generated.batch." + uuid.uuid4().hex
home = Path.home()
generated, applications = [], []
checks = 0


def record(label, value):
    (evidence / label).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def run(*args, expected=0):
    global checks
    process = subprocess.run([str(binary), *args, "--json"], env=environment,
                             stdin=subprocess.DEVNULL, capture_output=True, text=True,
                             start_new_session=True, timeout=180)
    result = json.loads(process.stdout)
    accepted = [expected] if isinstance(expected, int) else expected
    assert process.returncode in accepted, (args, process.returncode, result, process.stderr)
    checks += 1
    record(f"{checks:02d}-{'-'.join(args[:3]).replace('/', '-')}.json", result)
    return result


def confirm(args, phrase, paths, irreversible, cancel=False):
    global checks
    output_read, output_write = os.pipe()
    pid, terminal = pty.fork()
    if pid == 0:
        os.close(output_read)
        os.dup2(output_write, 1)
        os.close(output_write)
        os.execve(str(binary), [str(binary), *args, "--json"], environment)
    os.close(output_write)
    readers, transcript, output = {terminal, output_read}, bytearray(), bytearray()
    sent = finished = False
    deadline = time.monotonic() + 180
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
                assert {item["original_path"] for item in scope["items"]} == paths
                assert scope["selected_item_count"] == len(paths) and scope["irreversible"] is irreversible
                record(f"tty-scope-{checks + 1:02d}.json", scope)
                os.write(terminal, b"CANCEL\n" if cancel else phrase.encode() + b"\n")
                sent = True
        assert not readers and sent, transcript.decode(errors="replace")
        _, status = os.waitpid(pid, 0)
        finished = True
        result = json.loads(output)
        assert result["error"]["code"] == "cancelled" if cancel else os.waitstatus_to_exitcode(status) == 0 and result["ok"], result
        checks += 1
        record(f"{checks:02d}-tty-result.json", result)
        return result
    finally:
        if not finished:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(terminal)
        os.close(output_read)


def hashes():
    return {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
            for target in generated if target.exists()
            for path in ([target] if target.is_file() else target.rglob("*"))
            if path.is_file() and not path.is_symlink()}


try:
    for index in range(2):
        app_identifier = identifier + ".app" + str(index)
        app = home / "Applications" / ("Shou Batch Fixture " + app_identifier.rsplit(".", 2)[1] + "-" + str(index) + ".app")
        cache = home / "Library/Caches" / app_identifier
        preference = home / "Library/Preferences" / (app_identifier + ".plist")
        for path in [app, cache, preference]:
            assert not path.exists() and not path.is_symlink(), path
            assert path.parent.resolve() == path.parent, path.parent
            generated.append(path)
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": app_identifier,
            "CFBundleName": "Shou Generated Batch Fixture " + str(index), "CFBundleShortVersionString": "1.2.3",
            "CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture"}, fmt=plistlib.FMT_BINARY))
        (app / "Contents/MacOS/Fixture").write_bytes(b"inert generated application payload")
        cache.mkdir(parents=True)
        (cache / "fixture.bin").write_bytes(b"generated cache" * 256)
        preference.write_bytes(plistlib.dumps({"generated": True, "retain": "personal data"}, fmt=plistlib.FMT_BINARY))
        applications.append(app)
    original = hashes()
    record("fixture.json", {"applications": list(map(str, applications)), "generated_paths": list(map(str, generated)), "hashes": original})
    discovery = run("capabilities", "--command", "applications")["data"]["commands"]
    commands = {item["command"]: item for item in discovery}
    assert commands["applications summary"]["side_effect"] == "read"
    assert commands["applications summary"]["input_schema"]["properties"]["max-entries"]["default"] == 100000
    assert commands["applications batch plan"]["input_schema"]["properties"]["mode"]["default"] == "permanent"
    assert commands["applications batch uninstall"]["side_effect"] == "destructive"
    assert "include_user_data" in run("applications", "batch", "plan", "--help")["data"]
    summary = run("applications", "summary", expected=[0, 6])["data"]
    rows = {item["application"]["path"]: item for item in summary["items"]}
    for app in applications:
        row = rows[str(app)]
        assert row["application"]["version"] == "1.2.3" and row["allocated_bytes_estimate"] > 0
        assert row["status"] == "ready", row
        assert "manifest" not in row
    assert not (base / "records/application-reviews").exists() or not list((base / "records/application-reviews").glob("*.json"))

    reviews = [run("applications", "inspect", "--path", str(app))["data"] for app in applications]
    selections = [{"review_id": review["id"], "component_ids": [component["id"] for component in review["components"] if component["eligible"]]}
                  for review in reviews]
    selection_file = base / "selections.json"
    selection_file.write_text(json.dumps(selections))
    assert run("applications", "batch", "plan", "--file", str(selection_file), expected=7)["error"]["code"] == "confirmation_required"
    for selection in selections:
        selection["include_user_data"] = True
    selection_file.write_text(json.dumps(selections))
    trash_plan = run("applications", "batch", "plan", "--file", str(selection_file), "--mode", "trash")["data"]
    assert len(trash_plan["plans"]) == 2 and trash_plan["action"] == "trash"
    assert run("applications", "batch", "plan", "show", "--plan-id", trash_plan["id"])["data"] == trash_plan
    assert run("applications", "batch", "uninstall", "--plan-id", trash_plan["id"], expected=7)["error"]["code"] == "confirmation_required"
    paths = {component["path"] for plan in trash_plan["plans"] for component in plan["components"]}
    invocation = ["applications", "batch", "uninstall", "--plan-id", trash_plan["id"]]
    confirm(invocation, "UNINSTALL " + trash_plan["id"], paths, False, cancel=True)
    assert hashes() == original
    receipt = confirm(invocation, "UNINSTALL " + trash_plan["id"], paths, False)["data"]
    assert receipt["operation"] == "application_batch_uninstall" and receipt["state"] == "completed"
    assert all(item["state"] == "trashed" and item["uninstall_origin"] for item in receipt["items"])
    restore = ["history", "restore", "--execution-id", receipt["id"]]
    restore += [value for item in receipt["items"] for value in ["--item", item["id"]]]
    restored = confirm(restore, "RESTORE " + receipt["id"], paths, False)["data"]
    assert all(item["state"] == "completed" for item in restored) and hashes() == original

    # Fresh reviews bind the restored metadata; omit personal data for permanent mode.
    fresh = [run("applications", "inspect", "--path", str(app))["data"] for app in applications]
    selections = [{"review_id": review["id"], "component_ids": [component["id"] for component in review["components"]
                   if component["eligible"] and not component["requires_user_data_consent"]]} for review in fresh]
    selection_file.write_text(json.dumps(selections))
    permanent = run("applications", "batch", "plan", "--file", str(selection_file))["data"]
    assert permanent["action"] == "permanent"
    assert run("applications", "batch", "uninstall", "--plan-id", permanent["id"], expected=7)["error"]["code"] == "confirmation_required"
    paths = {component["path"] for plan in permanent["plans"] for component in plan["components"]}
    receipt = confirm(["applications", "batch", "uninstall", "--plan-id", permanent["id"]], "PURGE " + permanent["id"], paths, True)["data"]
    assert receipt["operation"] == "application_batch_permanent_uninstall" and receipt["state"] == "completed"
    assert all(item["state"] == "purged" and item.get("trash_path") is None and not Path(item["original_path"]).exists() for item in receipt["items"])
    inspection = run("history", "inspect", "--execution-id", receipt["id"])["data"]
    assert inspection["status"] == "complete" and all(item["state"] == "purged" for item in inspection["items"])
    refusal = run("history", "restore", "--execution-id", receipt["id"], "--item", receipt["items"][0]["id"], expected=8)
    assert refusal["error"]["code"] == "capability_unavailable"
    for path in generated:
        if path.suffix == ".plist":
            assert path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == original[str(path)]
    text = f"{checks} application summary/batch CLI checks passed; generated apps restored after Trash, then generated app/cache components permanently removed; personal preferences retained."
    (evidence / "summary.txt").write_text(text + "\n")
    print(text)
    print(f"Evidence: {evidence}")
finally:
    # Only paths that this invocation created are eligible for fixture cleanup.
    for path in reversed(generated):
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)
