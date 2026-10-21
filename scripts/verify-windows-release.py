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
    assert subprocess.check_output([str(engine), "--version"], env=environment, cwd=base, text=True, timeout=30).startswith(f"shou {version} ")
    assert run("rules", "schema")
    assert run("locations", "list")
    skill = run("agent", "skill")
    assert Path(skill["entrypoint"]).resolve().is_relative_to(app.resolve()), "Packaged Skill escaped the archive"
    gui = subprocess.run([str(app / "Shou.exe"), "--verify-package"], capture_output=True, env=environment, cwd=base, timeout=60)
    assert gui.returncode == 0, {"exit_code": gui.returncode, "stdout": gui.stdout.decode(errors="replace"), "stderr": gui.stderr.decode(errors="replace"),
                              "report": (base / "wpf-report.json").read_text(encoding="utf-8-sig") if (base / "wpf-report.json").exists() else "No report"}
    wpf = json.loads((base / "wpf-report.json").read_text(encoding="utf-8-sig"))
    assert wpf == {"assembly_version": version + ".0", "application_version": version, "wpf_layout_loaded": True}, wpf
    subprocess.run([sys.executable, "-B", str(root / "scripts/verify-desktop-bridge.py"), "--engine", str(engine), "--native-permanent"],
                   check=True, env=environment, cwd=base, timeout=300)
    print(f"Windows {version}: ZIP inventory, bundled runtime closure, resources, WPF layout, engine version and native desktop bridge passed with restricted PATH.")
