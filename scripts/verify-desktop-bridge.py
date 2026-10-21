#!/usr/bin/env python3
"""Exercise the real desktop protocol using generated, isolated files only."""
import argparse
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
        scan_counts = []
        scan_fractions = []
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
                assert review["operation"] == review["review"]["action"]
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
                if operation == "scan" and result["ok"]:
                    assert scan_counts and scan_counts == sorted(scan_counts), scan_counts
                    assert scan_fractions == [1 / 3, 2 / 3, 2 / 3, 1], scan_fractions
                if not process.stdin.closed:
                    process.stdin.close()
                assert process.wait(timeout=10) == 0
                return result, saw_confirmation
            else:
                assert event["kind"] == "progress", event
                if operation == "scan":
                    update = event["value"]
                    scan_counts.append(update["entry_count"])
                    if "total_unit_count" in update:
                        assert update["total_unit_count"] == 3, update
                        scan_fractions.append(update["completed_unit_count"] / update["total_unit_count"])
    finally:
        if not process.stdin.closed:
            process.stdin.close()
        if process.poll() is None:
            # The test owns only newly generated fixtures and waits for the
            # child to flush any durable mutation result before forced cleanup.
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for reader in readers:
            reader.join(timeout=2)


def set_fixture_owner(directory):
    if os.name == "nt":
        # Elevated CI accounts can create fixtures owned by Administrators.
        # Set only these newly generated files to the current user.
        identity = next(token for token in subprocess.check_output(["whoami", "/user"], text=True).split()
                        if token.startswith("S-1-"))
        subprocess.run(["icacls", str(directory), "/setowner", "*" + identity, "/T", "/Q"],
                       check=True, stdout=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--native-trash", action="store_true", help="Recycle and restore one newly generated fixture")
    parser.add_argument("--native-permanent", action="store_true", help="Permanently remove newly generated fixtures; also verifies purge after Trash when --native-trash is set")
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
        if args.native_trash:
            environment["SHOU_WINDOWS_EXPERIMENTAL_RECYCLE"] = "1"
        set_fixture_owner(workspace)

        def success(operation, values=None):
            result, _ = request(engine, environment, operation, values)
            assert result["ok"], result
            return result["data"]

        capabilities = success("capabilities")
        assert success("history.cleanup-preview")["execution_ids"] == []
        assert capabilities["features"]["permanent"] is True
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
        for action in ["trash", "permanent"]:
            if not capabilities["features"][action]:
                continue
            for control in ["cancel", "wrong", "wrong-digest", "eof"]:
                plan = success("plan", dict(scan_id=scan["scan_id"], candidate_ids=[candidate["id"]], action=action))
                assert plan["action"] == action
                result, reviewed = request(engine, environment, "plan.execute", dict(plan_id=plan["id"]), control)
                assert reviewed and not result["ok"] and result["error"]["code"] in ["cancelled", "confirmation_required"], result
                assert (workspace / candidate["relative_path"] / "fixture.bin").is_file()
            print(f"PASS {action}: rejected, foreign and disconnected consent preserve targets", flush=True)
        assert success("history") == []
        if args.native_trash:
            assert capabilities["features"]["trash"], "Native Recycle Bin capability must be explicitly available"
            plan = success("plan", dict(scan_id=scan["scan_id"], candidate_ids=[candidate["id"]]))
            result, reviewed = request(engine, environment, "plan.execute", dict(plan_id=plan["id"]), "accept")
            assert reviewed and result["ok"], result
            receipt = result["data"]
            assert receipt["state"] == "completed" and all(item["state"] == "trashed" for item in receipt["items"]), receipt
            assert not (workspace / candidate["relative_path"]).exists()
            history = success("history")
            assert len(history) == 1 and history[0]["items"][0]["can_restore"] and history[0]["items"][0]["can_purge"]
            result, reviewed = request(engine, environment, "history.restore",
                                       dict(execution_id=receipt["id"], item_ids=[item["id"] for item in receipt["items"]]), "accept")
            assert reviewed and result["ok"] and all(item["state"] == "completed" for item in result["data"]), result
            restored = success("history")[0]["items"][0]
            assert restored["state"] == "restored" and not restored["can_restore"] and not restored["can_purge"], restored
            assert (workspace / candidate["relative_path"] / "fixture.bin").read_bytes() == b"isolated desktop fixture" * 32
            print("PASS confirmed native Trash, history, restoration and replay eligibility", flush=True)
        storage = success("storage.scan", dict(path=str(workspace)))
        assert storage["status"] == "complete" and storage["entry_count"] == 211 and storage["issues"] == [], storage
        mapped = success("storage.map", dict(scan_id=storage["scan_id"], path="."))
        assert mapped["presentation"]["scan_id"] == storage["scan_id"] and len(mapped["presentation"]["items"]) <= 8192
        assert mapped["colors"]["bin"] == "#D23A9D" and all("depth" in tile for tile in mapped["tiles"])
        assert mapped["tiles"] and all(tile["width"] >= 0 and tile["height"] >= 0 for tile in mapped["tiles"])
        context = success("storage.context", dict(scan_id=storage["scan_id"], path="generated-000", locale="zh-CN"))
        assert context["context"]["presentation"]["scope"]["node"]["path"] == "generated-000"
        assert "analysis children" in context["text"] and storage["scan_id"] in context["text"]
        paged = success("storage.page", dict(scan_id=storage["scan_id"], path=".", offset=0))
        assert len(paged["children"]) == 105 and paged.get("next_offset") is None
        final_page = success("storage.page", dict(scan_id=storage["scan_id"], path=".", offset=100))
        assert len(final_page["children"]) == 5 and final_page.get("next_offset") is None
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
        removal_root = workspace.parent / "space-removal-fixture"
        (removal_root / "cache").mkdir(parents=True)
        (removal_root / "cache/generated.bin").write_bytes(b"disposable space fixture")
        (removal_root / "keep.txt").write_text("retain")
        set_fixture_owner(removal_root)
        removal_scan = success("storage.scan", dict(path=str(removal_root)))
        removal_input = dict(scan_id=removal_scan["scan_id"], paths=["cache"], action="permanent")
        cancelled, reviewed = request(engine, environment, "storage.remove", removal_input, "cancel")
        assert reviewed and not cancelled["ok"] and (removal_root / "cache/generated.bin").exists(), (reviewed, cancelled)
        removed, reviewed = request(engine, environment, "storage.remove", removal_input, "accept")
        assert reviewed and removed["ok"] and removed["data"]["state"] == "completed", (reviewed, removed)
        assert not (removal_root / "cache").exists() and (removal_root / "keep.txt").read_text() == "retain"
        print("PASS space removal cancellation, confirmed permanent deletion and retained sibling", flush=True)
        if args.native_permanent:
            # Refresh identity evidence after the optional Trash/restore round trip.
            scan = success("scan", dict(workspace_id=registered["id"]))
            candidate = next(item for item in scan["candidates"] if item["eligible"])
            target = workspace / candidate["relative_path"]
            plan = success("plan", dict(scan_id=scan["scan_id"], candidate_ids=[candidate["id"]], action="permanent"))
            result, reviewed = request(engine, environment, "plan.execute", dict(plan_id=plan["id"]), "accept")
            assert reviewed and result["ok"], result
            receipt = result["data"]
            assert receipt["state"] == "completed" and not target.exists(), receipt
            assert all(item["state"] == "purged" and not item["can_restore"] and not item["can_purge"] for item in receipt["items"])
            for operation in ["history.restore", "history.purge"]:
                result, reviewed = request(engine, environment, operation,
                                           dict(execution_id=receipt["id"], item_ids=[item["id"] for item in receipt["items"]]), "accept")
                assert not result["ok"] and not reviewed, result
            result, reviewed = request(engine, environment, "plan.execute", dict(plan_id=plan["id"]), "accept")
            assert not result["ok"] and not target.exists(), result
            print("PASS native permanent plan, irreversible receipt and replay refusal", flush=True)
            if args.native_trash:
                scan = success("scan", dict(workspace_id=registered["id"]))
                candidate = next(item for item in scan["candidates"] if item["eligible"])
                target = workspace / candidate["relative_path"]
                plan = success("plan", dict(scan_id=scan["scan_id"], candidate_ids=[candidate["id"]], action="trash"))
                result, _ = request(engine, environment, "plan.execute", dict(plan_id=plan["id"]), "accept")
                assert result["ok"] and result["data"]["state"] == "completed", result
                receipt = result["data"]
                values = dict(execution_id=receipt["id"], item_ids=[item["id"] for item in receipt["items"]])
                for control in ["cancel", "wrong-digest", "eof"]:
                    result, reviewed = request(engine, environment, "history.purge", values, control)
                    assert reviewed and not result["ok"], result
                    item = next(row for row in success("history") if row["id"] == receipt["id"])["items"][0]
                    assert item["can_restore"] and item["can_purge"] and Path(item["resulting_path"]).exists(), item
                result, reviewed = request(engine, environment, "history.purge", values, "accept")
                assert reviewed and result["ok"] and all(item["state"] == "completed" for item in result["data"]), result
                item = next(row for row in success("history") if row["id"] == receipt["id"])["items"][0]
                assert item["state"] == "purged" and not item["can_restore"] and not item["can_purge"] and item["resulting_path"] is None, item
                for operation in ["history.restore", "history.purge"]:
                    result, reviewed = request(engine, environment, operation, values, "accept")
                    assert not result["ok"] and not reviewed, result
                assert not target.exists()
                print("PASS native Trash followed by separately confirmed permanent purge", flush=True)
            preview = success("history.cleanup-preview")
            assert preview["execution_ids"] and preview["retained_count"] == 0 and preview["record_bytes"] > 0, preview
            for control in ["cancel", "wrong-digest", "eof"]:
                result, reviewed = request(engine, environment, "history.clear", confirmation=control)
                assert reviewed and not result["ok"], result
                assert success("history.cleanup-preview")["execution_ids"] == preview["execution_ids"]
            remaining = {str(path): path.read_bytes() for path in workspace.rglob("fixture.bin")}
            result, reviewed = request(engine, environment, "history.clear", confirmation="accept")
            assert reviewed and result["ok"] and result["data"]["execution_ids"] == preview["execution_ids"], result
            assert success("history") == [] and success("history.cleanup-preview")["record_bytes"] == 0
            assert {str(path): path.read_bytes() for path in workspace.rglob("fixture.bin")} == remaining
            result, _ = request(engine, environment, "plan.execute", dict(plan_id=plan["id"]), "accept")
            assert not result["ok"], result
        print("PASS history preview, confirmation rejection, metadata-only cleanup and consumed-plan refusal", flush=True)
        # Two independent workspace scans share one desktop confirmation and
        # journalled execution without exposing unattended public CLI mutation.
        roots = []
        for index in range(2):
            folder = root / f"batch-root-{index}"
            (folder / "generated-batch").mkdir(parents=True)
            (folder / "generated-batch/fixture.bin").write_bytes(b"generated batch only")
            set_fixture_owner(folder)
            root_ref = f"desktop-batch-{index}"
            registered = success("workspace.add", dict(path=str(folder), root_ref=root_ref))
            batch_rule = dict(rule, id=f"test.desktop-batch-{index}", scope=dict(rule["scope"], root_ref=root_ref))
            success("rules.import", dict(json=json.dumps(batch_rule)))
            success("rules.set", dict(workspace_id=registered["id"], rule_id=batch_rule["id"], version=batch_rule["version"], enabled=True))
            roots.append((folder, registered))
        selections = []
        for folder, registered in roots:
            scanned = success("scan", dict(workspace_id=registered["id"]))
            selections.append(dict(scan_id=scanned["scan_id"], candidate_ids=[row["id"] for row in scanned["candidates"] if row["eligible"]]))
        result, reviewed = request(engine, environment, "system.clean", dict(selections=selections, action="permanent"), "cancel")
        assert reviewed and not result["ok"] and all((folder / "generated-batch/fixture.bin").is_file() for folder, _ in roots), result
        result, reviewed = request(engine, environment, "system.clean", dict(selections=selections, action="permanent"), "accept")
        assert reviewed and result["ok"] and result["data"]["state"] == "completed", result
        assert len(result["data"]["execution_ids"]) == 2 and len(result["data"]["items"]) == 2
        assert all(not (folder / "generated-batch").exists() for folder, _ in roots)
        result, reviewed = request(engine, environment, "system.clean", dict(selections=selections, action="permanent"), "accept")
        assert reviewed and result["ok"] and result["data"]["state"] == "partial" and result["data"]["execution_ids"] == [], result
        assert all(not (folder / "generated-batch").exists() for folder, _ in roots)
        print("PASS cross-root single confirmation, cancellation, permanent cleanup, journals and stale-target refusal", flush=True)
    print("Desktop protocol integration passed; no user files changed.")


if __name__ == "__main__":
    main()
