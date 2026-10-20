#!/usr/bin/env python3
"""Exercise the real desktop protocol using generated, isolated files only."""
import argparse
import getpass
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import uuid


def request(engine, environment, operation, values=None, confirmation="cancel"):
    identifier = uuid.uuid4().hex
    process = subprocess.Popen([str(engine), "--desktop-bridge"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
    events = queue.Queue()
    diagnostics = bytearray()

    def output():
        try:
            for line in process.stdout:
                events.put(json.loads(line))
        except Exception as error:
            events.put(error)
        finally:
            events.put(None)

    def drain():
        while block := process.stderr.read(65536):
            if len(diagnostics) < 4096:
                diagnostics.extend(block[:4096 - len(diagnostics)])

    readers = [threading.Thread(target=output, daemon=True), threading.Thread(target=drain, daemon=True)]
    for reader in readers:
        reader.start()

    def send(value):
        process.stdin.write(json.dumps(value, ensure_ascii=False).encode() + b"\n")
        process.stdin.flush()

    try:
        send(dict(bridge_version=1, request_id=identifier, operation=operation, input=values or {}))
        saw_confirmation = False
        while True:
            event = events.get(timeout=30)
            assert event is not None, f"{operation}: disconnected: {diagnostics.decode(errors='replace')}"
            if isinstance(event, Exception):
                raise event
            assert event["bridge_version"] == 1 and event["request_id"] == identifier, event
            if event["kind"] == "confirmation":
                assert not saw_confirmation
                saw_confirmation = True
                review = event["value"]
                assert review["review"]["items"] and review["digest"] and review["challenge"]
                if confirmation == "eof":
                    process.stdin.close()
                elif confirmation == "wrong":
                    send(dict(bridge_version=1, request_id=identifier, kind="confirm",
                              challenge="foreign-challenge", digest=review["digest"]))
                elif confirmation == "wrong-digest":
                    send(dict(bridge_version=1, request_id=identifier, kind="confirm",
                              challenge=review["challenge"], digest="changed-selection-digest"))
                elif confirmation == "accept":
                    send(dict(bridge_version=1, request_id=identifier, kind="confirm",
                              challenge=review["challenge"], digest=review["digest"]))
                else:
                    send(dict(bridge_version=1, request_id=identifier, kind="cancel"))
            elif event["kind"] == "result":
                result = event["value"]
                assert result["api_version"] == "1.0"
                if not process.stdin.closed:
                    process.stdin.close()
                assert process.wait(timeout=10) == 0
                return result, saw_confirmation
            else:
                assert event["kind"] == "progress", event
    finally:
        if not process.stdin.closed:
            process.stdin.close()
        if process.poll() is None:
            # All fixtures reject consent. No real mutation is authorized here.
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for reader in readers:
            reader.join(timeout=2)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine", type=Path, required=True)
    args = parser.parse_args()
    engine = args.engine.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="shou-desktop-") as temporary:
        root = Path(temporary).resolve()
        workspace = root / "中文 project & literal"
        workspace.mkdir()
        for index in range(105):
            directory = workspace / f"generated-{index:03}"
            directory.mkdir()
            (directory / "fixture.bin").write_bytes(b"isolated desktop fixture" * 32)
        environment = dict(os.environ, SHOU_DATA_DIR=str(root / "records"))
        if os.name == "nt":
            # Elevated CI accounts can create fixtures owned by Administrators.
            # Set only these newly generated files to the current user.
            subprocess.run(["icacls", str(workspace), "/setowner", getpass.getuser(), "/T", "/Q"],
                           check=True, stdout=subprocess.DEVNULL)

        def success(operation, values=None):
            result, _ = request(engine, environment, operation, values)
            assert result["ok"], result
            return result["data"]

        capabilities = success("capabilities")
        assert capabilities["features"]["permanent"] is False
        assert capabilities["features"]["applications"] is False
        print("PASS real capability and version discovery", flush=True)
        registered = success("workspace.add", dict(path=str(workspace), root_ref="desktop-fixture"))
        rule = dict(schema_version="1.0", id="test.desktop-fixture", version="0.1.0",
                    name="Generated fixtures only", description="Only isolated fixture directories.",
                    platforms=[capabilities["platform"]],
                    scope=dict(root_ref="desktop-fixture", max_depth=4, follow_symlinks=False, cross_filesystems=False),
                    match=dict(kind="directory", relative_patterns=["generated-*"]),
                    conditions=dict(min_allocated_bytes=0, newest_descendant_modified_days_at_least=0),
                    exclude=dict(relative_patterns=[]),
                    risk=dict(declared_level="review", rebuild_note="Generated test fixtures.", limitations=["Test data only."]),
                    action=dict(type="trash"))
        success("rules.import", dict(json=json.dumps(rule)))
        draft = success("scan", dict(workspace_id=registered["id"]))
        assert draft["total_count"] == 0, draft
        success("rules.set", dict(workspace_id=registered["id"], rule_id=rule["id"], version=rule["version"], enabled=True))
        scan = success("scan", dict(workspace_id=registered["id"]))
        assert scan["status"] == "complete" and scan["total_count"] == 105 and len(scan["candidates"]) == 100, scan
        page = success("scan.results", dict(scan_id=scan["scan_id"], offset=scan["next_offset"]))
        assert len(page["candidates"]) == 5 and page["next_offset"] is None
        print("PASS registration, disabled import, enablement, scan and pagination", flush=True)
        candidate = next(item for item in scan["candidates"] if item["eligible"])
        if capabilities["features"]["trash"]:
            for control in ["cancel", "wrong", "wrong-digest", "eof"]:
                plan = success("plan", dict(scan_id=scan["scan_id"], candidate_ids=[candidate["id"]]))
                result, reviewed = request(engine, environment, "plan.execute", dict(plan_id=plan["id"]), control)
                assert reviewed and not result["ok"] and result["error"]["code"] in ["cancelled", "confirmation_required"], result
                assert (workspace / candidate["relative_path"] / "fixture.bin").is_file()
            print("PASS rejected, foreign and disconnected consent preserve targets", flush=True)
        else:
            print("SKIP native mutation consent: capability disabled", flush=True)
        assert success("history") == []
        storage = success("storage.scan", dict(path=str(workspace)))
        directory = success("storage.directory", dict(scan_id=storage["scan_id"], path="generated-000"))
        assert directory["path"] == "generated-000" and len(directory["children"]) == 1
        print("PASS isolated history and space navigation", flush=True)
        success("exclusions.set", dict(pattern="generated-000", remove=False))
        excluded = success("scan", dict(workspace_id=registered["id"]))
        excluded_items = excluded["candidates"]
        if excluded["next_offset"] is not None:
            excluded_items += success("scan.results", dict(scan_id=excluded["scan_id"], offset=excluded["next_offset"]))["candidates"]
        assert not next(item for item in excluded_items if item["relative_path"] == "generated-000")["eligible"]
        success("exclusions.set", dict(pattern="generated-000", remove=True))
        assert all((workspace / f"generated-{index:03}" / "fixture.bin").is_file() for index in range(105))
        print("PASS global exclusion changes preserve generated files", flush=True)
    print("Desktop protocol integration passed; no user files changed.")


if __name__ == "__main__":
    main()
