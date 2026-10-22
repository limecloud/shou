#!/usr/bin/env python3
"""Verify Windows startup discovery and refusal/cancellation; never accept a mutation."""
import argparse
import importlib.util
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", type=Path)
    arguments = parser.parse_args()
    engine = arguments.engine.resolve(strict=True)
    spec = importlib.util.spec_from_file_location("shou_desktop_protocol", Path(__file__).with_name("verify-desktop-bridge.py"))
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    with tempfile.TemporaryDirectory(prefix="shou-startup-protocol-") as temporary:
        environment = dict(os.environ, SHOU_DATA_DIR=str(Path(temporary) / "records"))

        def request(operation, values=None):
            # Deliberately fixed to cancellation. This verifier must never
            # confirm an existing user's task, registry entry or service.
            return bridge.request(engine, environment, operation, values, confirmation="cancel")

        capabilities, _ = request("capabilities")
        assert capabilities["ok"]
        platform = capabilities["data"]["platform"]
        result, confirmed = request("startup.scan", {"include_system": "false"})
        assert not result["ok"] and result["error"]["code"] == "invalid_argument" and not confirmed
        if platform != "windows":
            print("PASS startup input refusal; Windows native source and cancellation checks require Windows.")
            return
        assert capabilities["data"]["features"]["startup"] is True
        discovery = json.loads(subprocess.check_output([str(engine), "capabilities", "--command", "startup", "--json"], env=environment, timeout=30))
        assert discovery["ok"] and {row["command"] for row in discovery["data"]["commands"]} == {"startup list", "startup control"}, discovery
        help_text = subprocess.check_output([str(engine), "startup", "--help"], env=environment, timeout=30, text=True)
        assert "startup list" in help_text and "startup control" in help_text and "Windows" in help_text
        print("PASS Windows startup help and capability discovery expose implemented commands")
        user_sources = {"windows.user_run", "windows.user_run_once", "windows.user_startup", "windows.scheduled_tasks"}
        machine_sources = {"windows.machine_run64", "windows.machine_run_once64", "windows.machine_run32", "windows.machine_run_once32", "windows.machine_startup", "windows.services"}
        for include_system in (False, True):
            result, confirmed = request("startup.scan", {"include_system": include_system})
            assert result["ok"] and not confirmed, result
            data = result["data"]
            inventory = data["inventory"]
            assert "items" not in inventory, "Do not duplicate the bounded inventory inside one event"
            assert inventory["scope"] == "windows_startup_items"
            expected = user_sources | (machine_sources if include_system else set())
            sources = {row["location"]["id"] for row in inventory["sources"]}
            assert sources == expected
            assert {row["definition"]["source_id"] for row in data["items"]} <= expected
            for row in data["items"]:
                definition = row["definition"]
                assert re.fullmatch(r"sha256:[0-9a-f]{64}", row["digest"]), row["digest"]
                if definition["source_id"] != "windows.scheduled_tasks":
                    assert definition["control_capability"] == "system_settings"
            print(f"PASS Windows startup source coverage: system={include_system}, status={inventory['status']}, items={len(data['items'])}")
        forged, confirmed = request("startup.control", dict(action="disable", definition_id="not-a-definition-id", definition_digest="not-a-valid-digest"))
        assert not forged["ok"] and not confirmed and forged["error"]["code"] == "capability_unavailable", forged
        current, _ = request("startup.scan")
        assert current["ok"]
        task = next((row for row in current["data"]["items"] if row["definition"]["control_capability"] == "windows_user_task"), None)
        if task:
            selection = dict(action="disable", definition_id=task["definition"]["id"], definition_digest=task["digest"])
            stale, confirmed = request("startup.control", dict(selection, definition_digest="not-a-valid-digest"))
            assert not stale["ok"] and not confirmed and stale["error"]["code"] in {"plan_stale", "capability_unavailable"}, stale
            cancelled, confirmed = request("startup.control", selection)
            assert not cancelled["ok"] and cancelled["error"]["code"] in {"cancelled", "plan_stale", "capability_unavailable"}, cancelled
            if confirmed:
                assert cancelled["error"]["code"] == "cancelled"
            print("PASS Windows startup stale-selection refusal and cancellation; no confirmation accepted")
        else:
            print("SKIP task confirmation cancellation: no directly controllable current-user login/boot task exists")
        print("PASS Windows startup read-only protocol checks; no real startup configuration changed")


if __name__ == "__main__":
    main()
