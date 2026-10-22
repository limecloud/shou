#!/usr/bin/env python3
"""Verify a relocated Windows ZIP using only its bundled runtimes and fixtures."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import zipfile

tag, archive_name = sys.argv[1:]
assert os.name == "nt", "Run the distribution probe on Windows."
assert re.fullmatch(r"v\d+\.\d+\.\d+", tag)
version = tag[1:]
archive = Path(archive_name).resolve(strict=True)
root = Path(__file__).resolve().parents[1]
# AppData remains protected. All generated mutation fixtures stay in this repo.
with tempfile.TemporaryDirectory(prefix="windows-release-", dir=root / ".build") as directory:
    base = Path(directory)
    with zipfile.ZipFile(archive) as package:
        names = package.namelist()
        assert len(names) == len({name.lower() for name in names}), "Duplicate archive paths"
        for name in names:
            parts = name.replace("\\", "/").split("/")
            assert not name.startswith(("/", "\\")) and ".." not in parts and all(":" not in p for p in parts)
        package.extractall(base / "relocated 中文 package")
    app = base / "relocated 中文 package" / f"Shou-{version}-windows-x64"
    engine = app / "Engine/shou.exe"
    assert engine.is_file() and (app / "Shou.exe").is_file()
    inventory = json.loads((app / "files.sha256.json").read_text(encoding="utf-8-sig"))
    expected = {row["path"] for row in inventory}
    actual = {p.relative_to(app).as_posix() for p in app.rglob("*") if p.is_file()} - {"files.sha256.json"}
    assert expected == actual and len(inventory) == len(expected), "Incomplete file inventory"
    for row in inventory:
        assert hashlib.sha256((app / row["path"]).read_bytes()).hexdigest() == row["sha256"], row["path"]
    for name in ("Swift-LICENSE.txt", "Foundation-LICENSE.txt", "Dispatch-LICENSE.txt", "ICU-LICENSE.txt", "DotNet-LICENSE.txt", "DotNet-ThirdPartyNotices.txt", "THIRD-PARTY-NOTICES.txt"):
        assert (app / "Licenses" / name).stat().st_size > 100, name
    environment = dict(os.environ, PATH=str(engine.parent) + os.pathsep + str(Path(os.environ["SystemRoot"]) / "System32"),
                       SHOU_DATA_DIR=str(base / "records"), TEMP=str(base), TMP=str(base), TMPDIR=str(base),
                       SHOU_PACKAGE_VERIFICATION_REPORT=str(base / "wpf-report.json"))

    def run(*arguments):
        result = json.loads(subprocess.check_output([str(engine), *arguments, "--json"], env=environment, cwd=base, timeout=60))
        assert result["ok"], result
        return result["data"]

    capabilities = run("capabilities")
    assert capabilities["application_version"] == version and capabilities["platform"] == "windows"
    assert capabilities["features"]["application_package_data"] is True, "Packaged engine is missing MSIX data review support"
    assert subprocess.check_output([str(engine), "--version"], env=environment, cwd=base, text=True, timeout=30).startswith(f"shou {version} ")
    assert run("rules", "schema")
    assert run("locations", "list")
    skill = run("agent", "skill")
    assert Path(skill["entrypoint"]).resolve().is_relative_to(app.resolve()), "Packaged Skill escaped the archive"
    for language in ("zh-CN", "en"):
        report_path = base / f"wpf-report-{language}.json"
        probe_environment = dict(environment, SHOU_PACKAGE_VERIFICATION_LANGUAGE=language, SHOU_PACKAGE_VERIFICATION_REPORT=str(report_path))
        gui = subprocess.run([str(app / "Shou.exe"), "--verify-package"], capture_output=True, env=probe_environment, cwd=base, timeout=60)
        assert gui.returncode == 0, {"language": language, "exit_code": gui.returncode, "stdout": gui.stdout.decode(errors="replace"), "stderr": gui.stderr.decode(errors="replace"),
                                  "report": report_path.read_text(encoding="utf-8-sig") if report_path.exists() else "No report"}
        wpf = json.loads(report_path.read_text(encoding="utf-8-sig"))
        assert wpf == {"assembly_version": version + ".0", "application_version": version, "language": language, "wpf_layout_loaded": True, "rule_authoring_layout_loaded": True, "rule_settings_layout_loaded": True, "application_inventory_layout_loaded": True, "application_uninstall_layout_loaded": True, "application_data_layout_loaded": True, "package_data_layout_loaded": True, "history_selection_layout_loaded": True, "history_inspection_layout_loaded": True, "record_maintenance_layout_loaded": True, "scan_locations_layout_loaded": True, "storage_browsing_layout_loaded": True, "file_preview_layout_loaded": True, "system_preview_surface_loaded": True, "disk_capacity_layout_loaded": True, "privacy_layout_loaded": True, "cleanup_closing_state_verified": True, "tools_layout_loaded": True, "settings_layout_loaded": True, "agent_setup_layout_loaded": True, "cli_installation_verified": True, "presentation_preferences_verified": True}, wpf
    for language in ("zh-CN", "en"):
        command = base / f"cli-fixture-{language}" / "shou.exe"
        result = subprocess.run([str(command), "--version"], capture_output=True, env=environment, cwd=base, timeout=30)
        assert result.returncode == 0 and result.stdout.decode().startswith(f"shou {version} "), result
    subprocess.run([sys.executable, "-B", str(root / "scripts/verify-desktop-bridge.py"), "--engine", str(engine), "--native-permanent"],
                   check=True, env=environment, cwd=base, timeout=300)
    subprocess.run([sys.executable, "-B", str(root / "scripts/verify-agent-setup.py"), "--engine", str(engine)],
                   check=True, env=environment, cwd=base, timeout=300)
    subprocess.run([sys.executable, "-B", str(root / "scripts/verify-windows-preview.py"), "--engine", str(engine)],
                   check=True, env=environment, cwd=base, timeout=60)
    print(f"Windows {version}: ZIP inventory, bundled runtime closure, resources, WPF layouts in zh-CN/en, external agent setup, settings and presentation probes, engine version and native desktop bridge passed with restricted PATH.")
