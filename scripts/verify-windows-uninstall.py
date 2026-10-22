#!/usr/bin/env python3
"""Verify installer discovery and input boundaries without launching an installed uninstaller."""
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
    spec = importlib.util.spec_from_file_location("installer_bridge", Path(__file__).with_name("verify-desktop-bridge.py"))
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    engine = args.engine.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="shou-installer-protocol-") as directory:
        records = Path(directory).resolve() / "records"
        environment = dict(os.environ, SHOU_DATA_DIR=str(records))
        capability, confirmed = bridge.request(engine, environment, "capabilities")
        assert capability["ok"] and not confirmed
        windows = capability["data"]["platform"] == "windows"
        assert capability["data"]["features"]["application_uninstall"] is windows
        for operation, values in [
            ("applications.prepare-scan", dict(path=directory)),
            ("applications.prepare-scan", dict(include_system="false")),
            ("applications.uninstall-history", dict(yes=True)),
            ("applications.uninstall", {}),
            ("applications.uninstall", dict(scan_id="missing", application_ids=["missing"], yes=True)),
            ("applications.uninstall", dict(scan_id="missing", application_ids=["missing"], executable="cmd.exe")),
            ("applications.uninstall", dict(scan_id="missing", application_ids=["missing"], arguments=["/c", "unsafe"])),
        ]:
            result, confirmed = bridge.request(engine, environment, operation, values)
            assert not result["ok"] and not confirmed and result["error"]["code"] == "invalid_argument", result
        result, confirmed = bridge.request(engine, environment, "applications.uninstall", dict(scan_id="missing", application_ids=["missing"]))
        assert not result["ok"] and not confirmed and result["error"]["code"] == ("invalid_argument" if windows else "unsupported_platform"), result
        history, confirmed = bridge.request(engine, environment, "applications.uninstall-history")
        if windows:
            assert history["ok"] and history["data"] == dict(entries=[], total_count=0) and not confirmed, history
        else:
            assert not history["ok"] and history["error"]["code"] == "unsupported_platform" and not confirmed, history
        discovery = subprocess.run([str(engine), "capabilities", "--command", "applications installer", "--json"], env=environment, capture_output=True, text=True, timeout=30)
        envelope = json.loads(discovery.stdout)
        if windows:
            assert envelope["ok"] and {item["command"] for item in envelope["data"]["commands"]} == {
                "applications installer " + suffix for suffix in ["scan", "plan", "show", "execute", "history"]}, envelope
        else:
            assert not envelope["ok"] and envelope["error"]["code"] == "invalid_argument", envelope
        assert not list((records / "registered-uninstall-history").glob("*.json"))
        print("PASS installer scan/selection-only scope, executable/arguments/yes refusal, platform capability, CLI discovery and empty history; no installed uninstaller invoked", flush=True)
    if args.native_harness:
        assert os.name == "nt", "Generated installer harness requires Windows."
        result = subprocess.run([str(args.native_harness.resolve(strict=True))], timeout=90)
        if result.returncode == 77:
            raise SystemExit("Native installer positive acceptance NOT RUN: use a standard-user Windows session.")
        assert result.returncode == 0, result.returncode


if __name__ == "__main__":
    main()
