#!/usr/bin/env python3
"""Pack and install local npm tarballs offline under isolated temporary prefixes."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--launcher", type=Path, required=True)
    parser.add_argument("--platform-package", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    main_package = options.launcher.resolve()
    native_package = options.platform_package.resolve()
    manifest = json.loads((main_package / "package.json").read_text(encoding="utf-8"))
    native = json.loads((native_package / "package.json").read_text(encoding="utf-8"))
    descriptor = json.loads((native_package / "payload.json").read_text(encoding="utf-8"))
    host_system = {"Darwin": "darwin", "Windows": "win32"}.get(platform.system())
    host_arch = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "x64", "amd64": "x64"}.get(platform.machine().lower())
    if (descriptor["platform"], descriptor["arch"]) != (host_system, host_arch):
        parser.error("Run native tarball verification on its matching OS/architecture.")
    if manifest.get("optionalDependencies", {}).get(native["name"]) != native["version"] or manifest["version"] != native["version"]:
        parser.error("The selected native package must match the launcher's exact dependency version.")
    output = options.output.resolve()
    if output.exists():
        parser.error("Choose a new evidence directory.")
    output.mkdir(parents=True)
    node = shutil.which("node")
    npm = Path(shutil.which("npm") or "missing").resolve()
    npm_cli = npm if npm.name == "npm-cli.js" else npm.parent / "node_modules/npm/bin/npm-cli.js"
    if not node or not npm_cli.is_file():
        parser.error("Node.js and the standard npm CLI installation are required.")
    environment = os.environ.copy()
    environment.update(npm_config_cache=str(output / "cache"), npm_config_userconfig=str(output / "npmrc"),
                       npm_config_globalconfig=str(output / "global-npmrc"), npm_config_offline="true",
                       npm_config_audit="false", npm_config_fund="false", npm_config_update_notifier="false",
                       SHOU_DATA_DIR=str(output / "native records"))
    (output / "npmrc").write_text("", encoding="utf-8")
    (output / "global-npmrc").write_text("", encoding="utf-8")
    records = []

    def run(arguments, cwd=output, expected=0):
        result = subprocess.run([str(value) for value in arguments], cwd=cwd, env=environment, text=True, encoding="utf-8",
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        if result.returncode != expected:
            raise RuntimeError(f"Command returned {result.returncode}, expected {expected}: {arguments}\n{result.stderr}")
        return result

    def npm_run(*arguments):
        return run([node, npm_cli, *arguments])

    tarballs = []
    for package in (main_package, native_package):
        packed = json.loads(npm_run("pack", str(package), "--pack-destination", str(output), "--json", "--ignore-scripts", "--offline").stdout)
        tarballs.append(output / packed[0]["filename"])
        records.append({"package": packed[0]["name"], "integrity": packed[0]["integrity"], "files": len(packed[0]["files"]),
                        "sha256": hashlib.sha256(tarballs[-1].read_bytes()).hexdigest()})

    def verify(command, label):
        capabilities = json.loads(run([*command, "capabilities", "--json"]).stdout)
        assert capabilities["ok"] and capabilities["data"]["application_version"].split("+")[0] == manifest["version"], label
        schema = json.loads(run([*command, "rules", "schema", "--json"]).stdout)
        catalog = json.loads(run([*command, "rules", "catalog", "--json"]).stdout)
        assert schema["ok"] and catalog["ok"], label
        records.append({"check": label, "version": capabilities["data"]["application_version"], "result": "passed"})

    local = output / "local install 路径"
    local.mkdir()
    (local / "package.json").write_text('{"name":"shou-install-fixture","private":true}', encoding="utf-8")
    npm_run("install", "--prefix", str(local), "--offline", "--ignore-scripts", *map(str, tarballs))
    local_command = [node, local / "node_modules/@limecloud/shou/bin/shou.cjs"]
    verify(local_command, "local install and resources")
    fixture = output / "scan fixture 夹具"
    fixture.mkdir()
    (fixture / "hello.txt").write_text("Generated read-only npm verification fixture.\n", encoding="utf-8")
    before = hashlib.sha256((fixture / "hello.txt").read_bytes()).hexdigest()
    scan = json.loads(run([*local_command, "analysis", "scan", "--path", fixture, "--max-entries", "100", "--max-seconds", "10", "--json"]).stdout)
    assert scan["ok"] and scan["data"].get("state", scan["data"].get("status")) == "complete"
    assert hashlib.sha256((fixture / "hello.txt").read_bytes()).hexdigest() == before
    records.append({"check": "offline read-only generated fixture scan", "result": "passed", "fixture_sha256": before})

    prefix = output / "global install 路径"
    npm_run("install", "--global", "--prefix", str(prefix), "--offline", "--ignore-scripts", *map(str, tarballs))
    if host_system == "win32":
        verify(["powershell.exe", "-NoProfile", "-File", prefix / "shou.ps1"], "isolated global shim and resources")
    else:
        verify([prefix / "bin/shou"], "isolated global shim and resources")

    verify([node, npm_cli, "exec", "--offline", "--yes", "--package", str(tarballs[0]), "--package", str(tarballs[1]), "--", "shou"], "npx-equivalent npm exec and resources")

    missing = output / "missing optional dependency"
    missing.mkdir()
    (missing / "package.json").write_text('{"name":"shou-missing-fixture","private":true}', encoding="utf-8")
    npm_run("install", "--prefix", str(missing), "--offline", "--ignore-scripts", "--omit=optional", str(tarballs[0]))
    failure = run([node, missing / "node_modules/@limecloud/shou/bin/shou.cjs", "capabilities", "--json"], expected=1)
    assert not failure.stdout and "--include=optional" in failure.stderr
    records.append({"check": "missing optional dependency preserves empty JSON stdout", "result": "passed"})
    evidence = {"host": {"platform": host_system, "architecture": host_arch, "system": platform.platform()},
                "version": manifest["version"], "registry_access": False, "records": records}
    (output / "verification.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Offline npm tarballs, isolated local/global installs, npm exec, resources and missing dependency passed: {output}")


if __name__ == "__main__":
    main()
