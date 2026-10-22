#!/usr/bin/env python3
"""Check tool protocol boundaries without executing any installed cleanup tool."""
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
    spec = importlib.util.spec_from_file_location("tools_desktop_protocol", Path(__file__).with_name("verify-desktop-bridge.py"))
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    engine = args.engine.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="shou-tools-protocol-") as directory:
        records = Path(directory).resolve() / "records"
        environment = dict(os.environ, SHOU_DATA_DIR=str(records))
        capability, confirmed = bridge.request(engine, environment, "capabilities")
        assert capability["data"]["features"]["tool_cleanup"] is True and not confirmed
        for operation, values in [
            ("tools.scan", dict(path=directory)), ("tools.history", dict(yes=True)),
            ("tools.clean", {}), ("tools.clean", dict(scan_id="missing", target_id="missing", yes=True)),
            ("tools.clean", dict(scan_id="missing", target_id="missing", executable="cmd.exe")),
            ("tools.clean", dict(scan_id="missing", target_id="missing", arguments=["/c", "arbitrary"])),
            ("tools.clean", dict(scan_id="missing", target_id="missing")),
        ]:
            result, confirmed = bridge.request(engine, environment, operation, values)
            assert not confirmed and not result["ok"] and result["error"]["code"] == "invalid_argument", result
        history, confirmed = bridge.request(engine, environment, "tools.history")
        assert history["ok"] and history["data"] == [] and not confirmed, history
        commands = json.loads(subprocess.check_output([str(engine), "capabilities", "--command", "tools", "--json"], env=environment, text=True, timeout=30))
        assert {item["command"] for item in commands["data"]["commands"]} == {"tools scan", "tools plan", "tools execute", "tools history"}, commands
        assert not list(records.rglob("*.json"))
        print("PASS tool scan/target-only scope, executable/arguments/yes refusal, empty history and CLI discovery; no installed tool or cleanup confirmation executed")
    if args.native_harness:
        assert os.name == "nt", "Native generated-tool harness requires Windows."
        result = subprocess.run([str(args.native_harness.resolve(strict=True))], timeout=90)
        if result.returncode == 77:
            raise SystemExit("Native tool positive acceptance NOT RUN: use a standard-user Windows session.")
        assert result.returncode == 0, result.returncode


if __name__ == "__main__":
    main()
