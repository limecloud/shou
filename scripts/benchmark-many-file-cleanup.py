#!/usr/bin/env python3
"""Compare release engines using equal-sized, newly generated disposable trees."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import statistics
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--files", type=int, default=12000)
    parser.add_argument("--rounds", type=int, default=2)
    args = parser.parse_args()
    assert 1024 <= args.files <= 100000 and 1 <= args.rounds <= 5
    engines = {name: path.resolve(strict=True) for name, path in
               (("baseline", args.baseline), ("candidate", args.candidate))}
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location("bridge", Path(__file__).with_name("verify-desktop-bridge.py"))
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    runs = []
    for round_index in range(args.rounds):
        # Alternate execution order; generated data is warm in both cases.
        for name in (["baseline", "candidate"] if round_index % 2 == 0 else ["candidate", "baseline"]):
            directory = evidence / f"{round_index}-{name}"
            workspace = directory / "workspace"
            target = workspace / "generated"
            target.mkdir(parents=True)
            retained = workspace / "retained.txt"
            retained.write_bytes(b"retained benchmark sentinel")
            before = hashlib.sha256(retained.read_bytes()).hexdigest()
            for index in range(args.files):
                parent = target / f"group-{index // 100:04}" / "build" / "incremental"
                parent.mkdir(parents=True, exist_ok=True)
                (parent / f"file-{index:06}.bin").write_bytes(b"generated benchmark payload")
            environment = dict(os.environ, SHOU_DATA_DIR=str(directory / "records"))
            timings = {}

            def request(operation, values=None, confirmation="cancel", timer=None):
                started = time.perf_counter()
                response, _ = bridge.request(engines[name], environment, operation, values, confirmation)
                if timer:
                    timings[timer] = time.perf_counter() - started
                assert response["ok"], response
                return response["data"]

            root = request("workspace.add", dict(path=str(workspace), root_ref="benchmark"))
            rule = dict(schema_version="1.0", id="test.many-files", version="1.0.0",
                        name="Generated benchmark", description="Disposable fixture only.", platforms=["macos"],
                        scope=dict(root_ref="benchmark", max_depth=8, follow_symlinks=False, cross_filesystems=False),
                        match=dict(kind="directory", relative_patterns=["generated"]),
                        conditions=dict(min_allocated_bytes=0), exclude=dict(relative_patterns=[]),
                        risk=dict(declared_level="review", rebuild_note="Generated data.", limitations=["Test only."]),
                        action=dict(type="trash"))
            request("rules.import", dict(json=json.dumps(rule)))
            request("rules.set", dict(workspace_id=root["id"], rule_id=rule["id"], enabled=True))
            scan = request("scan", dict(workspace_id=root["id"]), timer="scan_seconds")
            candidates = [item for item in scan["candidates"] if item["eligible"]]
            assert len(candidates) == 1
            plan = request("plan", dict(scan_id=scan["scan_id"], candidate_ids=[candidates[0]["id"]], action="permanent"), timer="plan_seconds")
            receipt = request("plan.execute", dict(plan_id=plan["id"]), "accept", "execute_seconds")
            assert receipt["state"] == "completed" and not target.exists()
            assert before == hashlib.sha256(retained.read_bytes()).hexdigest()
            history = request("history.page", timer="history_seconds")
            assert history["receipts"][0]["id"] == receipt["id"], history
            records = directory / "records"
            run = dict(engine=name, round=round_index, files=args.files, **timings,
                       history_bytes=sum(p.stat().st_size for p in (records / "history").glob("*.json")),
                       manifest_bytes=sum(p.stat().st_size for p in (records / "history-manifests").glob("*.json")),
                       target_absent=True, retained_sha256=before)
            runs.append(run)
            print(json.dumps(run), flush=True)
    medians = {name: {key: statistics.median(run[key] for run in runs if run["engine"] == name)
                      for key in ("scan_seconds", "plan_seconds", "execute_seconds", "history_seconds", "history_bytes", "manifest_bytes")}
               for name in engines}
    report = dict(platform=platform.platform(), machine=platform.machine(), files=args.files,
                  engines={name: dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest()) for name, path in engines.items()},
                  conditions="Warm newly generated trees; alternating order; local APFS; client round trips include process startup; no product-wide speed claim.",
                  runs=runs, medians=medians)
    (evidence / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(dict(medians=medians)), flush=True)


if __name__ == "__main__":
    main()
