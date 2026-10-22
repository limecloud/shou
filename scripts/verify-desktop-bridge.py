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


def request(engine, environment, operation, values=None, confirmation="cancel", before_confirmation=None):
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
                if before_confirmation is not None:
                    before_confirmation(review)
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
    # AppData remains protected even for test roots. A new private fixture below
    # the user profile exercises normal project policy without a cache exception.
    with tempfile.TemporaryDirectory(prefix="shou-desktop-", dir=Path.home() if os.name == "nt" else None) as temporary:
        root = Path(temporary).resolve()
        workspace = root / "中文 project & literal"
        workspace.mkdir()
        for index in range(105):
            directory = workspace / f"generated-{index:03}"
            directory.mkdir()
            (directory / "fixture.bin").write_bytes(b"isolated desktop fixture" * 32)
            (directory / "nested").mkdir()
            (directory / "nested/child.bin").write_bytes(b"isolated nested fixture")
        environment = dict(os.environ, SHOU_DATA_DIR=str(root / "records"))
        if args.native_trash:
            environment["SHOU_WINDOWS_EXPERIMENTAL_RECYCLE"] = "1"
        set_fixture_owner(workspace)

        def success(operation, values=None):
            result, _ = request(engine, environment, operation, values)
            assert result["ok"], result
            return result["data"]

        def history_record_snapshot():
            records = root / "records"
            snapshot = {path.relative_to(records).as_posix(): (path.read_bytes(), path.stat().st_mtime_ns)
                        for collection in ("history", "history-manifests", "followups")
                        for path in (records / collection).glob("*.json")}
            assert snapshot, "Fixture must contain durable history before checking read-only behavior"
            return snapshot

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
        preview = success("rules.preview", dict(workspace_id=registered["id"], rule_id=rule["id"], version=rule["version"]))
        assert preview["status"] == "complete" and len(preview["rows"]) == 105
        assert preview["benefits"]["eligible_match_count"] == 105 and preview["benefits"]["additional_allocated_bytes_estimate"] > 0
        assert all(row["status"] == "matched" for row in preview["rows"])
        assert success("configuration")["configuration"]["bindings"] == []
        rejected, _ = request(engine, environment, "plan", dict(scan_id=preview["scan_id"], candidate_ids=[preview["rows"][0]["path"]]))
        assert not rejected["ok"], rejected
        print("PASS independent personal-rule preview remains disabled and non-executable", flush=True)
        draft = success("scan", dict(workspace_id=registered["id"]))
        assert draft["total_count"] == 0, draft
        success("rules.set", dict(workspace_id=registered["id"], rule_id=rule["id"], version=rule["version"], enabled=True))
        scan = success("scan", dict(workspace_id=registered["id"]))
        assert scan["status"] == "complete" and scan["total_count"] == 105 and len(scan["candidates"]) == 100, scan
        page = success("scan.results", dict(scan_id=scan["scan_id"], offset=scan["next_offset"]))
        assert len(page["candidates"]) == 5 and page["next_offset"] is None
        rule_scan = success("scan", dict(workspace_id=registered["id"], rule_ids=[rule["id"]]))
        assert rule_scan["total_count"] == 105 and all(item["rule_ids"] == [rule["id"]] for item in rule_scan["candidates"])
        print("PASS registration, disabled import, enablement, scan and pagination", flush=True)
        partial = success("scan", dict(workspace_id=registered["id"], budget=dict(max_entries=64)))
        incomplete = next(item for item in partial["candidates"] if "incomplete_scan" in item["reasons"])
        refined = success("scan.target", dict(scan_id=partial["scan_id"], candidate_id=incomplete["id"]))
        assert refined["scan_id"] != partial["scan_id"] and refined["workspace_id"] == partial["workspace_id"]
        assert refined["total_count"] == 1 and refined["candidates"][0]["relative_path"] == incomplete["relative_path"]
        assert refined["candidates"][0]["eligible"] and refined["status"] == "complete", refined
        rejected, reviewed = request(engine, environment, "scan.target", dict(scan_id=partial["scan_id"], candidate_id="foreign-candidate"))
        assert not reviewed and not rejected["ok"]
        rejected, _ = request(engine, environment, "scan", dict(workspace_id=registered["id"], budget=dict(max_entries=0)))
        assert not rejected["ok"] and rejected["error"]["code"] == "invalid_argument"
        print("PASS bounded partial discovery, single-directory continuation and invalid-scope refusal", flush=True)
        review = success("cleanup.review", dict(scan_ids=[scan["scan_id"], rule_scan["scan_id"]]))
        assert review["total_count"] == 105 and len(review["sources"]) == 105 and review["next_offset"] is None, review
        assert [category["id"] for category in review["categories"]] == ["personal"]
        assert review["bytes"] == sum(source["candidate"]["allocated_bytes_estimate"] for source in review["sources"])
        assert all(source["selectable"] and source["file_count"] == 2 for source in review["sources"])
        refined_review = success("cleanup.review", dict(scan_ids=[partial["scan_id"], refined["scan_id"]],
            refinements=[dict(original_scan_id=partial["scan_id"], candidate_id=incomplete["id"], scan_id=refined["scan_id"])],
            query=incomplete["relative_path"]))
        assert refined_review["total_count"] == 1 and refined_review["sources"][0]["scan_id"] == refined["scan_id"]
        assert refined_review["sources"][0]["selectable"]
        repeated_partial = success("scan.target", dict(scan_id=partial["scan_id"], candidate_id=incomplete["id"], budget=dict(max_depth=1)))
        repeated_target = next(item for item in repeated_partial["candidates"] if item["relative_path"] == incomplete["relative_path"])
        assert "incomplete_scan" in repeated_target["reasons"]
        repeated_complete = success("scan.target", dict(scan_id=repeated_partial["scan_id"], candidate_id=repeated_target["id"]))
        compacted = success("cleanup.review", dict(scan_ids=[partial["scan_id"], repeated_complete["scan_id"]],
            refinements=[dict(original_scan_id=partial["scan_id"], candidate_id=incomplete["id"], scan_id=repeated_complete["scan_id"])],
            query=incomplete["relative_path"]))
        assert compacted["total_count"] == 1 and compacted["sources"][0]["selectable"]
        assert compacted["sources"][0]["scan_id"] == repeated_complete["scan_id"]
        for invalid in [dict(scan_ids=[scan["scan_id"], scan["scan_id"]]),
                        dict(scan_ids=[scan["scan_id"]], offset=-1), dict(scan_ids=[scan["scan_id"]], offset=0.5),
                        dict(scan_ids=[scan["scan_id"]], category_id="foreign"), dict(scan_ids=[scan["scan_id"]], group_id="foreign"),
                        dict(scan_ids=[scan["scan_id"]], recommended_only="true"), dict(scan_ids=[scan["scan_id"]], query=3)]:
            rejected, confirmed = request(engine, environment, "cleanup.review", invalid)
            assert not confirmed and not rejected["ok"] and rejected["error"]["code"] == "invalid_argument", rejected
        print("PASS shared cleanup grouping, cross-scan deduplication, capacities and refined evidence", flush=True)
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
            chosen = [item for item in scan["candidates"] if item["eligible"]][:2]
            plan = success("plan", dict(scan_id=scan["scan_id"], candidate_ids=[item["id"] for item in chosen]))
            result, reviewed = request(engine, environment, "plan.execute", dict(plan_id=plan["id"]), "accept")
            assert reviewed and result["ok"], result
            receipt = result["data"]
            assert receipt["state"] == "completed" and all(item["state"] == "trashed" for item in receipt["items"]), receipt
            assert not (workspace / candidate["relative_path"]).exists()
            history = success("history")
            assert len(history) == 1 and len(history[0]["items"]) == 2 and all(item["can_restore"] and item["can_purge"] for item in history[0]["items"])
            saved_records = history_record_snapshot()
            inspection = success("history.inspect", dict(execution_id=receipt["id"]))
            assert inspection["execution_id"] == receipt["id"] and inspection["status"] == "complete" and not inspection["unfinished"], inspection
            assert all(item["state"] == "verified_trash" and item["original"]["state"] == "missing" and item["trash"]["state"] == "matches" for item in inspection["items"])
            limited = success("history.inspect", dict(execution_id=receipt["id"], budget=dict(max_entries=1)))
            assert limited["status"] == "partial" and any(item["trash"]["state"] == "unavailable" for item in limited["items"]), limited
            conflict = Path(receipt["items"][0]["path"])
            conflict.mkdir()
            inspection = success("history.inspect", dict(execution_id=receipt["id"]))
            assert next(item for item in inspection["items"] if item["id"] == receipt["items"][0]["id"])["state"] == "restore_conflict", inspection
            conflict.rename(root / "isolated-restore-conflict")
            assert success("history") == history, "Position checks must not rewrite receipts or follow-up eligibility"
            assert history_record_snapshot() == saved_records, "Position checks rewrote durable receipt or manifest data"
            # Restore one explicit item while its unselected sibling stays in Trash.
            result, reviewed = request(engine, environment, "history.restore",
                                       dict(execution_id=receipt["id"], item_ids=[receipt["items"][0]["id"]]), "accept")
            assert reviewed and result["ok"] and all(item["state"] == "completed" for item in result["data"]), result
            assert len(result["data"]) == 1 and result["data"][0]["item_id"] == receipt["items"][0]["id"], result
            after = success("history")
            restored, retained = after[0]["items"]
            assert restored["state"] == "restored" and not restored["can_restore"] and not restored["can_purge"], restored
            assert retained["state"] == "trashed" and retained["can_restore"] and retained["can_purge"] and not Path(retained["path"]).exists(), retained
            inspection = success("history.inspect", dict(execution_id=receipt["id"]))
            assert [item["state"] for item in inspection["items"]] == ["restored", "verified_trash"], inspection
            assert success("history") == after
            result, reviewed = request(engine, environment, "history.restore",
                                       dict(execution_id=receipt["id"], item_ids=[retained["id"]]), "accept")
            assert reviewed and result["ok"] and len(result["data"]) == 1 and result["data"][0]["state"] == "completed", result
            assert (workspace / candidate["relative_path"] / "fixture.bin").read_bytes() == b"isolated desktop fixture" * 32
            print("PASS native Trash, exact-subset restoration, read-only location checks, conflicts, budgets and replay eligibility", flush=True)
        storage = success("storage.scan", dict(path=str(workspace)))
        assert storage["status"] == "complete" and storage["entry_count"] == 421 and storage["issues"] == [], storage
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
        assert directory["path"] == "generated-000" and {child["path"] for child in directory["children"]} == {"generated-000/fixture.bin", "generated-000/nested"}
        print("PASS isolated history and space navigation", flush=True)
        large_root = root / "large-files-fixture"
        large_root.mkdir()
        for index in range(501):
            (large_root / f"small-{index:03}.bin").write_bytes(b"generated large-file paging fixture")
        video = large_root / "isolated-video.mp4"
        video.write_bytes(b"generated extension-based video fixture" * 256)
        (large_root / "isolated-document.pdf").write_bytes(b"generated document fixture" * 1024)
        large_scan = success("storage.scan", dict(path=str(large_root)))
        large = success("storage.large-files", dict(scan_id=large_scan["scan_id"], minimum_bytes=0))
        assert large["total_count"] == 503 and len(large["entries"]) == 500 and large["next_cursor"], large
        last = success("storage.large-files", dict(scan_id=large_scan["scan_id"], minimum_bytes=0, cursor=large["next_cursor"]))
        assert len(last["entries"]) == 3 and last["next_cursor"] is None
        assert len({item["entry"]["path"] for item in large["entries"] + last["entries"]}) == 503
        videos = success("storage.large-files", dict(scan_id=large_scan["scan_id"], minimum_bytes=0, type="video"))
        assert videos["total_count"] == 1 and videos["entries"][0]["entry"]["path"] == video.name
        assert videos["entries"][0]["removal_block_reason"] is None
        for values in [dict(minimum_bytes=-1), dict(type=True), dict(type="unsupported"), dict(cursor=True), dict(minimum_bytes=0, type="video", cursor=large["next_cursor"])]:
            rejected, reviewed = request(engine, environment, "storage.large-files", dict(scan_id=large_scan["scan_id"], **values))
            assert not rejected["ok"] and not reviewed, rejected
        result, reviewed = request(engine, environment, "storage.remove", dict(scan_id=large_scan["scan_id"], paths=[video.name], action="permanent"))
        assert reviewed and not result["ok"] and video.is_file()
        result, reviewed = request(engine, environment, "storage.remove", dict(scan_id=large_scan["scan_id"], paths=[video.name], action="permanent"), "accept")
        assert reviewed and result["ok"] and result["data"]["state"] == "completed", result
        assert not video.exists() and (large_root / "small-000.bin").is_file()
        removed_id = result["data"]["id"]
        before_inspection = success("history")
        saved_records = history_record_snapshot()
        inspection = success("history.inspect", dict(execution_id=removed_id))
        assert inspection["execution_id"] == removed_id and inspection["status"] == "complete" and not inspection["unfinished"]
        assert len(inspection["items"]) == 1 and inspection["items"][0]["state"] == "purged", inspection
        assert inspection["items"][0]["original"]["state"] == "missing" and inspection["items"][0]["trash"]["state"] == "not_recorded"
        assert success("history") == before_inspection, "Read-only inspection changed history"
        assert history_record_snapshot() == saved_records, "Read-only inspection rewrote durable history"
        for invalid in [{}, dict(execution_id=3), dict(execution_id=""), dict(execution_id=removed_id, path=str(video)),
                        dict(execution_id=removed_id, budget=True), dict(execution_id=removed_id, budget=dict(max_entries=0)),
                        dict(execution_id=removed_id, budget=dict(max_seconds=0.5)), dict(execution_id=removed_id, budget=dict(max_depth=True)),
                        dict(execution_id=removed_id, budget=dict(unknown=1))]:
            rejected, reviewed = request(engine, environment, "history.inspect", invalid)
            assert not rejected["ok"] and not reviewed and rejected["error"]["code"] == "invalid_argument", rejected
        print("PASS desktop history inspection is read-only, receipt-scoped and strictly budgeted", flush=True)
        print("PASS large-file pagination, filename filters, query-bound cursors and confirmed file removal", flush=True)
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
        # Exercise review paging and overlapping roots independently from the
        # mutation fixtures above. Only newly created test directories are used.
        review_root = root / "review-paging"
        for index in range(503):
            directory = review_root / f"generated-{index:03}"
            directory.mkdir(parents=True)
            (directory / "fixture.bin").write_bytes(b"review fixture")
        for name in ["high-risk", "nested/generated-child"]:
            directory = review_root / name
            directory.mkdir(parents=True)
            (directory / "fixture.bin").write_bytes(b"review fixture")
        set_fixture_owner(review_root)
        review_workspace = success("workspace.add", dict(path=str(review_root), root_ref="review-paging"))
        nested_workspace = success("workspace.add", dict(path=str(review_root / "nested"), root_ref="review-nested"))
        for identifier, root_ref, patterns, risk, workspace_id in [
            ("test.review-main", "review-paging", ["generated-*", "nested/generated-*"], "review", review_workspace["id"]),
            ("test.review-high", "review-paging", ["high-risk"], "high", review_workspace["id"]),
            ("test.review-nested", "review-nested", ["generated-*"], "review", nested_workspace["id"])]:
            review_rule = dict(rule, id=identifier, scope=dict(rule["scope"], root_ref=root_ref),
                               match=dict(kind="directory", relative_patterns=patterns), risk=dict(rule["risk"], declared_level=risk))
            success("rules.import", dict(json=json.dumps(review_rule)))
            success("rules.set", dict(workspace_id=workspace_id, rule_id=identifier, version=rule["version"], enabled=True))
        review_ids = [success("scan", dict(workspace_id=workspace_id))["scan_id"]
                      for workspace_id in [review_workspace["id"], nested_workspace["id"]]]
        first = success("cleanup.review", dict(scan_ids=review_ids))
        assert first["total_count"] == 505 and len(first["sources"]) == 500 and first["next_offset"] == 500, first
        last = success("cleanup.review", dict(scan_ids=review_ids, offset=500, query_digest=first["query_digest"]))
        assert len(last["sources"]) == 5 and last["next_offset"] is None
        combined = first["sources"] + last["sources"]
        paths = [source["root_path"] + "/" + source["candidate"]["relative_path"] for source in combined]
        assert len(set(paths)) == 505 and sum(source["file_count"] for source in combined) == 505
        assert first["bytes"] == sum(source["candidate"]["allocated_bytes_estimate"] for source in combined)
        filtered = success("cleanup.review", dict(scan_ids=review_ids, query="GENERATED-502"))
        assert filtered["total_count"] == 1 and filtered["sources"][0]["candidate"]["relative_path"] == "generated-502"
        recommended = success("cleanup.review", dict(scan_ids=review_ids, query="high-risk", recommended_only=True))
        assert recommended["total_count"] == 0
        high_group = next(group for category in first["categories"] for group in category["groups"] if group["id"] == "test.review-high")
        assert high_group["count"] == 1 and high_group["selectable_count"] == 1 and high_group["recommended_count"] == 0
        scoped = success("cleanup.review", dict(scan_ids=review_ids, category_id="personal", group_id=high_group["id"]))
        assert scoped["total_count"] == 1 and scoped["sources"][0]["candidate"]["relative_path"] == "high-risk"
        for changed in [dict(scan_ids=review_ids, offset=500),
                        dict(scan_ids=review_ids, offset=500, query_digest=first["query_digest"], query="changed")]:
            rejected, confirmed = request(engine, environment, "cleanup.review", changed)
            assert not confirmed and not rejected["ok"] and rejected["error"]["code"] == "plan_stale", rejected
        print("PASS cleanup review paging, nested-root deduplication, search, group scope and high-risk recommendations", flush=True)
    print("Desktop protocol integration passed; no user files changed.")


if __name__ == "__main__":
    main()
