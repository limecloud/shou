#!/usr/bin/env python3
"""Check tool protocol boundaries without executing any installed cleanup tool."""
import argparse
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
    with tempfile.TemporaryDirectory(prefix="shou-tools-protocol-") as directory:
        records = Path(directory).resolve() / "records"
        environment = dict(os.environ, SHOU_DATA_DIR=str(records))
        def request(*arguments):
            result=subprocess.run([str(engine), *arguments, "--json"], env=environment, capture_output=True, text=True, timeout=30)
            return json.loads(result.stdout)
        for arguments in [
            ("tools", "scan", "--path", directory),
            ("tools", "history", "--yes", "true"),
            ("tools", "execute"),
            ("tools", "execute", "--plan-id", "missing", "--executable", "cmd.exe"),
            ("tools", "execute", "--plan-id", "missing", "--arguments", "arbitrary"),
        ]:
            result=request(*arguments)
            assert not result["ok"] and result["error"]["code"] == "invalid_argument", result
        assert request("tools", "history")["data"] == []
        commands = json.loads(subprocess.check_output([str(engine), "capabilities", "--command", "tools", "--json"], env=environment, text=True, timeout=30))
        assert {item["command"] for item in commands["data"]["commands"]} == {"tools scan", "tools plan", "tools execute", "tools history"}, commands
        assert not list(records.rglob("*.json"))
        print("PASS tool scan/target-only scope, executable/arguments/yes refusal, empty history and CLI discovery; no installed tool or cleanup confirmation executed")


if __name__ == "__main__":
    main()
