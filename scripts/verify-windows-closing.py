#!/usr/bin/env python3
"""Verify close-request boundaries without accepting a real application's quit request."""
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
    parser.add_argument("--native-harness", type=Path, help="Optional independently built generated-window test executable; Windows standard-user session required")
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("closing_desktop_protocol", Path(__file__).with_name("verify-desktop-bridge.py"))
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    engine = args.engine.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="shou-closing-protocol-") as temporary:
        records = Path(temporary).resolve() / "records"
        environment = dict(os.environ, SHOU_DATA_DIR=str(records))
        capabilities, confirmed = bridge.request(engine, environment, "capabilities")
        windows = capabilities["data"]["platform"] == "windows"
        assert capabilities["data"]["features"]["close_cleanup_owners"] is windows and not confirmed
        for values in [dict(scan_ids=[]), dict(scan_ids="missing"), dict(scan_ids=[False]), dict(scan_ids=["missing"], yes=True), dict(scan_ids=["missing"], pid=123), dict(path=temporary)]:
            result, confirmed = bridge.request(engine, environment, "cleanup.close-owners", values)
            assert not confirmed and not result["ok"] and result["error"]["code"] == "invalid_argument", result
        result, confirmed = bridge.request(engine, environment, "cleanup.close-owners", dict(scan_ids=["missing"]))
        assert not confirmed and not result["ok"] and result["error"]["code"] == ("invalid_argument" if windows else "capability_unavailable"), result
        discovered = subprocess.run([str(engine), "capabilities", "--command", "system close-owners", "--json"], env=environment, capture_output=True, text=True, timeout=30)
        assert discovered.returncode == (0 if windows else 2), discovered
        discovery = json.loads(discovered.stdout)
        assert discovery["ok"] is windows, discovery
        if windows:
            assert [item["command"] for item in discovery["data"]["commands"]] == ["system close-owners"]
        assert not list(records.rglob("*.json"))
        print("PASS strict scan-only close scope, no arbitrary PID/path/yes input, platform capability and CLI discovery; no confirmation accepted")
    if args.native_harness:
        assert os.name == "nt", "Native close harness requires Windows."
        result = subprocess.run([str(args.native_harness.resolve(strict=True))], timeout=90)
        if result.returncode == 77:
            raise SystemExit("Native normal-close positive acceptance NOT RUN: use a standard, non-elevated Windows user session.")
        assert result.returncode == 0, result.returncode


if __name__ == "__main__":
    main()
