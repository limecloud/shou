#!/usr/bin/env python3
"""Verify MSIX data-clear discovery and refusal without clearing installed package data."""
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
    args = parser.parse_args()
    engine = args.engine.resolve(strict=True)
    spec = importlib.util.spec_from_file_location("package_data_bridge", Path(__file__).with_name("verify-desktop-bridge.py"))
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    checks = 0
    with tempfile.TemporaryDirectory(prefix="shou-msix-data-protocol-") as directory:
        records = Path(directory).resolve() / "records"
        environment = dict(os.environ, SHOU_DATA_DIR=str(records))

        def request(operation, values=None):
            nonlocal checks
            result, confirmed = bridge.request(engine, environment, operation, values, confirmation="cancel")
            checks += 1
            assert not confirmed, "Refused or missing MSIX evidence must never request confirmation."
            return result

        def refuse(operation, values, code):
            response = request(operation, values)
            assert not response["ok"] and response["error"]["code"] == code, response

        capability = request("capabilities")
        assert capability["ok"]
        windows = capability["data"]["platform"] == "windows"
        assert capability["data"]["features"]["application_package_data"] is windows
        selected = dict(scan_id="missing-scan", application_ids=["missing-package"], include_user_data=True)
        for values in [{}, dict(selected, path=directory), dict(selected, package_family="arbitrary_family"),
                       dict(selected, executable="powershell.exe"), dict(selected, arguments=["unsafe"]),
                       dict(selected, yes=True), dict(selected, mode="trash"),
                       {key: value for key, value in selected.items() if key != "include_user_data"}]:
            refuse("applications.package-data-clear", values, "invalid_argument")
        for consent in [False, "true", None, 1, [], {}]:
            refuse("applications.package-data-clear", dict(selected, include_user_data=consent), "confirmation_required")
        for values in [dict(path=directory), dict(yes=True), dict(limit=100)]:
            refuse("applications.package-data-history", values, "invalid_argument")
        code = "invalid_argument" if windows else "unsupported_platform"
        for values in [selected, dict(selected, scan_id=""), dict(selected, application_ids=[]),
                       dict(selected, application_ids=[True]), dict(selected, application_ids=["missing"] * 21)]:
            refuse("applications.package-data-clear", values, code)
        history = request("applications.package-data-history")
        if windows:
            assert history["ok"] and history["data"] == dict(entries=[], total_count=0), history
        else:
            assert not history["ok"] and history["error"]["code"] == "unsupported_platform", history

        def cli(arguments):
            nonlocal checks
            process = subprocess.run([str(engine), *arguments, "--json"], env=environment,
                                     stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
            checks += 1
            return json.loads(process.stdout)

        discovery = cli(["capabilities", "--command", "applications package-data"])
        if windows:
            assert discovery["ok"] and {row["command"] for row in discovery["data"]["commands"]} == {
                "applications package-data " + suffix for suffix in ["scan", "plan", "show", "execute", "history"]}, discovery
            for operation, values in [
                ("plan", ["--scan-id", "missing-scan", "--application-id", "missing-package", "--include-user-data", "true"]),
                ("show", ["--plan-id", "missing-plan"]), ("execute", ["--plan-id", "missing-plan"])]:
                result = cli(["applications", "package-data", operation, *values])
                assert not result["ok"] and result["error"]["code"] == "invalid_argument", result
            result = cli(["applications", "package-data", "plan", "--scan-id", "missing-scan", "--application-id", "missing-package", "--include-user-data", "false"])
            assert not result["ok"] and result["error"]["code"] == "confirmation_required", result
        else:
            assert not discovery["ok"] and discovery["error"]["code"] == "invalid_argument", discovery
        for collection in ["registered-app-scans", "windows-package-data-plans", "windows-package-data-history", "history"]:
            assert not list((records / collection).glob("*")), f"Rejected requests wrote {collection}."
    print(f"PASS {checks} MSIX data-clear capability, field, separate consent, missing evidence, history and CLI discovery checks; no installed package data cleared.")
    if args.native_harness:
        assert os.name == "nt", "Native input harness requires Windows."
        subprocess.run([str(args.native_harness.resolve(strict=True))], check=True, timeout=30)


if __name__ == "__main__":
    main()
