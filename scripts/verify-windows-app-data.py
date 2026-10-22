#!/usr/bin/env python3
"""Check application-data input boundaries without scanning or cleaning real user data."""
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
    args = parser.parse_args()
    engine = args.engine.resolve(strict=True)
    spec = importlib.util.spec_from_file_location("application_data_bridge", Path(__file__).with_name("verify-desktop-bridge.py"))
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    checks = 0
    with tempfile.TemporaryDirectory(prefix="shou-application-data-protocol-") as directory:
        records = Path(directory).resolve() / "records"
        environment = dict(os.environ, SHOU_DATA_DIR=str(records))

        def request(operation, values=None):
            nonlocal checks
            result, confirmed = bridge.request(engine, environment, operation, values, confirmation="cancel")
            assert not confirmed, "Invalid or missing application-data evidence must never request consent."
            checks += 1
            return result

        def refuse(operation, values, code):
            result = request(operation, values)
            assert not result["ok"] and result["error"]["code"] == code, result

        capability = request("capabilities")
        assert capability["ok"], capability
        windows = capability["data"]["platform"] == "windows"
        assert capability["data"]["features"]["application_data"] is windows
        assert capability["data"]["features"]["applications"] is False
        # Every Windows scan request below is malformed and rejected before
        # constructing the evidence reader. Never issue a valid native scan.
        for values in [dict(path=directory), dict(leftovers_only="true"), dict(leftovers_only=None),
                       dict(leftovers_only=1), dict(leftovers_only=[]), dict(budget={}), dict(yes=True)]:
            refuse("applications.data-scan", values, "invalid_argument")
        selected = dict(review_id="missing-review", component_ids=["missing-component"], include_user_data=True)
        for values in [{}, {key: value for key, value in selected.items() if key != "include_user_data"},
                       dict(selected, path=directory), dict(selected, executable="cmd.exe"),
                       dict(selected, arguments=["/c", "unsafe"]), dict(selected, yes=True), dict(selected, mode="trash")]:
            refuse("applications.data-clean", values, "invalid_argument")
        for consent in [False, None, "true", 1, [], {}]:
            refuse("applications.data-clean", dict(selected, include_user_data=consent), "confirmation_required")
        absent_code = "invalid_argument" if windows else "unsupported_platform"
        for values in [selected, dict(selected, review_id=""), dict(selected, review_id=42),
                       dict(selected, component_ids=[]), dict(selected, component_ids=[42]),
                       dict(selected, component_ids=["missing"] * 33)]:
            refuse("applications.data-clean", values, absent_code)
        if not windows:
            for values in [{}, dict(leftovers_only=True), dict(leftovers_only=False)]:
                refuse("applications.data-scan", values, "unsupported_platform")

        def cli(arguments):
            nonlocal checks
            result = subprocess.run([str(engine), *arguments, "--json"], env=environment,
                                    capture_output=True, text=True, timeout=30)
            checks += 1
            return json.loads(result.stdout)

        discovery = cli(["capabilities", "--command", "applications data"])
        if windows:
            assert discovery["ok"] and {row["command"] for row in discovery["data"]["commands"]} == {
                "applications data " + suffix for suffix in ["scan", "plan", "show", "execute"]}, discovery
            for suffix, arguments in [
                ("plan", ["--review-id", "missing-review", "--component", "missing-component", "--include-user-data", "true"]),
                ("show", ["--plan-id", "missing-plan"]), ("execute", ["--plan-id", "missing-plan"])]:
                result = cli(["applications", "data", suffix, *arguments])
                assert not result["ok"] and result["error"]["code"] == "invalid_argument", result
            result = cli(["applications", "data", "plan", "--review-id", "missing-review", "--component", "missing-component", "--include-user-data", "false"])
            assert not result["ok"] and result["error"]["code"] == "confirmation_required", result
        else:
            assert not discovery["ok"] and discovery["error"]["code"] == "invalid_argument", discovery
        for collection in ["windows-app-data-reviews", "windows-app-data-plans", "history", "history-manifests", "follow-ups"]:
            assert not list((records / collection).glob("*")), f"Rejected requests wrote {collection}."
    print(f"PASS {checks} application-data capability, strict input, separate consent, missing evidence and CLI discovery checks; no native data scan or cleanup performed.")
    if not windows:
        print("Windows SDK, AppData ACL/junction/handle behavior and WPF journeys: NOT RUN on this host.")


if __name__ == "__main__":
    main()
