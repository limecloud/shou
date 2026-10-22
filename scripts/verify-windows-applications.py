#!/usr/bin/env python3
"""Read Windows application registrations; never launch an uninstaller or mutate registrations."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    engine = Path(sys.argv[1]).resolve(strict=True)
    spec = importlib.util.spec_from_file_location("application_inventory_protocol", Path(__file__).with_name("verify-desktop-bridge.py"))
    protocol = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(protocol)
    with tempfile.TemporaryDirectory(prefix="shou-application-inventory-") as directory:
        environment = dict(os.environ, SHOU_DATA_DIR=str(Path(directory) / "records"))

        def request(values):
            result, confirmed = protocol.request(engine, environment, "applications.scan", values, confirmation="cancel")
            assert not confirmed, "A read-only inventory must never request confirmation."
            return result

        capabilities, confirmed = protocol.request(engine, environment, "capabilities", confirmation="cancel")
        assert capabilities["ok"] and not confirmed
        platform = capabilities["data"]["platform"]
        for invalid in [dict(include_system="false"), dict(include_system=None), dict(max_entries=True), dict(max_entries=0),
                        dict(max_entries=20001), dict(max_seconds=31), dict(max_seconds="10"), dict(uninstall=True)]:
            result = request(invalid)
            assert not result["ok"] and result["error"]["code"] == "invalid_argument", result
        print("PASS application inventory strict field, type and budget refusal", flush=True)
        if platform != "windows":
            assert capabilities["data"]["features"]["application_inventory"] is False
            result = request({})
            assert not result["ok"] and result["error"]["code"] == "unsupported_platform", result
            print("Windows native registry/MSIX inventory checks require Windows; not executed on this host.")
            return
        assert capabilities["data"]["features"]["application_inventory"] is True
        assert capabilities["data"]["features"]["applications"] is False, "Inventory must not imply application deletion capability."
        sources = {"windows.user_uninstall64", "windows.user_uninstall32", "windows.machine_uninstall64", "windows.machine_uninstall32", "windows.user_packages"}
        for include_system in [False, True]:
            response = request(dict(include_system=include_system))
            assert response["ok"], response
            inventory = response["data"]
            assert inventory["scope"] == "windows_registered_applications"
            assert {row["source"]["id"] for row in inventory["sources"]} == sources
            assert len({row["id"] for row in inventory["items"]}) == len(inventory["items"])
            for source in inventory["sources"]:
                assert source["application_count"] == sum(row["source_id"] == source["source"]["id"] for row in inventory["items"])
            for row in inventory["items"]:
                assert row["kind"] in {"desktop", "msi", "msix"} and len(row["evidence_digest"]) == 64
                assert "uninstall_string" not in row and "command" not in row and "eligible" not in row
                assert include_system or not row["system_component"]
                if row["kind"] == "msix":
                    assert row.get("estimated_bytes") is None and row.get("uninstall_available") is None
            print(f"PASS Windows registered applications: system={include_system}, status={inventory['status']}, items={len(inventory['items'])}", flush=True)
        limited = request(dict(max_entries=1))
        assert limited["ok"] and sum(row["entry_count"] for row in limited["data"]["sources"]) <= 1
        cli = subprocess.run([str(engine), "applications", "list", "--json"], env=environment, capture_output=True, text=True, timeout=60)
        envelope = json.loads(cli.stdout)
        assert envelope["ok"] and envelope["data"]["scope"] == "windows_registered_applications", envelope
        assert not (Path(directory) / "records").exists(), "Application inventory must work without opening or modifying the cleanup store."
        print("PASS Windows bounded native inventory and public CLI; no registrations, packages or application files changed.")


if __name__ == "__main__":
    main()
