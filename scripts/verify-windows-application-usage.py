#!/usr/bin/env python3
"""Verify registered installation usage boundaries without scanning installed payloads."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--native-harness", type=Path)
    parser.add_argument("--native-fixtures", action="store_true")
    args = parser.parse_args()
    engine = args.engine.resolve(strict=True)
    spec = importlib.util.spec_from_file_location("usage_bridge", Path(__file__).with_name("verify-desktop-bridge.py"))
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    checks = 0
    with tempfile.TemporaryDirectory(prefix="shou-usage-protocol-") as directory:
        records = Path(directory).resolve() / "records"
        environment = dict(os.environ, SHOU_DATA_DIR=str(records))

        def request(operation, values=None):
            nonlocal checks
            result, confirmed = bridge.request(engine, environment, operation, values, confirmation="cancel")
            checks += 1
            assert not confirmed, "Read-only installation usage must never request consent."
            return result

        capability = request("capabilities")
        assert capability["ok"]
        windows = capability["data"]["platform"] == "windows"
        assert capability["data"]["features"]["application_usage"] is windows
        selected = dict(scan_id="missing-scan", application_id="missing-application")
        invalid = [{}, dict(selected, path=directory), dict(selected, source_id="windows.user_uninstall64"),
                   dict(selected, executable="cmd.exe"), dict(selected, yes=True), dict(scan_id="missing"),
                   dict(selected, scan_id=""), dict(selected, application_id=True)]
        invalid += [dict(selected, **{field: value}) for field in ["max_entries", "max_seconds"] for value in [0, -1, True, "10", None]]
        invalid += [dict(selected, max_entries=1_000_001), dict(selected, max_seconds=121)]
        for values in invalid:
            result = request("applications.usage", values)
            assert not result["ok"] and result["error"]["code"] == "invalid_argument", result
        result = request("applications.usage", selected)
        assert not result["ok"] and result["error"]["code"] == ("invalid_argument" if windows else "unsupported_platform"), result
        output = subprocess.run([str(engine), "capabilities", "--command", "applications usage", "--json"], env=environment, capture_output=True, text=True, timeout=30)
        discovery = json.loads(output.stdout)
        checks += 1
        if windows:
            assert discovery["ok"] and {item["command"] for item in discovery["data"]["commands"]} == {"applications usage scan", "applications usage measure"}, discovery
        else:
            assert not discovery["ok"] and discovery["error"]["code"] == "invalid_argument", discovery
        assert not any(records.rglob("*.json")), "Rejected usage requests wrote private records."
    print(f"PASS {checks} application-usage discovery, field, budget, read-only and missing-evidence checks; no installed payload measured.")
    if args.native_harness:
        assert os.name == "nt", "Native fixture requires Windows."
        command = [str(args.native_harness.resolve(strict=True))]
        if args.native_fixtures:
            command.append("--generated-fixture")
        subprocess.run(command, check=True, timeout=60)
    else:
        assert not args.native_fixtures, "Select the native harness for generated fixtures."


if __name__ == "__main__":
    main()
