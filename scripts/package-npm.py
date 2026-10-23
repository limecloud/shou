#!/usr/bin/env python3
"""Stage exact-version native npm packages or their shared launcher; never publish."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "packages/shou-npm"
PLATFORMS = ("darwin-arm64", "darwin-x64", "win32-arm64", "win32-x64")
BUNDLES = ("Shou_ShouCore.bundle", "Shou_ShouContracts.bundle", "Shou_ShouAgentSupport.bundle")
WINDOWS_FILES = ("shou.exe", "shou.dll", "shou.deps.json", "shou.runtimeconfig.json", "coreclr.dll", "hostfxr.dll",
                 "hostpolicy.dll", "System.Private.CoreLib.dll", "Shou.Windows.Core.dll", "Shou.Windows.Platform.dll")
WINDOWS_NOTICES = ("DOTNET-LICENSE.txt", "DOTNET-THIRD-PARTY-NOTICES.txt", "WINDOWS-SDK-NOTICE.txt")
SEMVER = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?")


def run(*args, cwd=ROOT, env=None):
    return subprocess.check_output(args, cwd=cwd, env=env, text=True, timeout=60).strip()


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def write(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_state(reference, development):
    commit = run("git", "rev-parse", f"{reference}^{{commit}}")
    if commit != run("git", "rev-parse", "HEAD"):
        raise ValueError("Run staging from the recorded source checkout; the source reference must resolve to HEAD.")
    dirty = bool(run("git", "status", "--porcelain", "--untracked-files=all"))
    if dirty and not development:
        raise ValueError("Release staging requires a clean source checkout. Use --development for private local artifacts.")
    tree = run("git", "rev-parse", "HEAD^{tree}")
    if not dirty:
        # Git's clean tree is canonical across checkouts with different line-ending filters.
        return {"source_commit": commit, "source_tree": tree, "source_dirty": False,
                "worktree_sha256": hashlib.sha256(("git-tree:" + tree).encode()).hexdigest()}
    names = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT)
    inventory = {}
    for name in sorted(set(names.split(b"\0")) - {b""}):
        path = ROOT / os.fsdecode(name)
        if path.is_symlink():
            inventory[os.fsdecode(name)] = {"symlink": os.readlink(path)}
        elif path.is_file():
            inventory[os.fsdecode(name)] = digest(path)
        else:
            inventory[os.fsdecode(name)] = None
    return {"source_commit": commit, "source_tree": tree, "source_dirty": dirty,
            "worktree_sha256": hashlib.sha256(json.dumps(inventory, sort_keys=True).encode()).hexdigest()}


def copy(source, destination):
    if source.is_symlink() or not source.exists():
        raise ValueError(f"Missing file or unsupported symbolic link: {source}")
    if source.is_dir():
        for child in source.rglob("*"):
            if child.is_symlink() or not (child.is_dir() or child.is_file()):
                raise ValueError(f"Unsupported payload entry: {child}")
        shutil.copytree(source, destination)
    elif source.is_file():
        shutil.copy2(source, destination)
    else:
        raise ValueError(f"Unsupported payload entry: {source}")


def machine(path):
    data = path.read_bytes()
    if data[:2] != b"MZ" or len(data) < 64:
        raise ValueError(f"Not a Windows PE image: {path}")
    offset = struct.unpack_from("<I", data, 60)[0]
    if data[offset:offset + 4] != b"PE\0\0":
        raise ValueError(f"Invalid Windows PE image: {path}")
    return struct.unpack_from("<H", data, offset + 4)[0]


def validate_payload(directory, target):
    operating_system, arch = target.split("-")
    if operating_system == "darwin":
        expected = 0x0100000C if arch == "arm64" else 0x01000007
        header = (directory / "shou").read_bytes()[:8]
        if len(header) != 8 or struct.unpack("<II", header) != (0xFEEDFACF, expected):
            raise ValueError("A macOS platform package requires a thin executable for its exact architecture.")
        for bundle in BUNDLES:
            if not (directory / bundle).is_dir():
                raise ValueError(f"Missing Swift resource bundle: {bundle}")
        return
    for name in WINDOWS_FILES:
        if not (directory / name).is_file():
            raise ValueError(f"Missing self-contained Windows dependency: {name}")
    expected = 0xAA64 if arch == "arm64" else 0x8664
    if any(machine(directory / name) != expected for name in ("shou.exe", "coreclr.dll", "hostfxr.dll", "hostpolicy.dll")):
        raise ValueError("Windows apphost/runtime architecture differs from the platform package.")
    config = read(directory / "shou.runtimeconfig.json")["runtimeOptions"]
    if config["tfm"] != "net10.0" or config.get("framework") or config.get("frameworks") or not config.get("includedFrameworks"):
        raise ValueError("Windows CLI must include its .NET 10 runtime.")
    dependencies = read(directory / "shou.deps.json")
    if not dependencies["runtimeTarget"]["name"].endswith("/win-" + arch):
        raise ValueError("Windows dependency RID differs from the package architecture.")
    if any(any(name in library for name in ("WindowsAppSDK", "WinUI", "Presentation")) for library in dependencies["libraries"]):
        raise ValueError("The standalone CLI must not depend on the desktop UI runtime.")


def host_target():
    system = {"Darwin": "darwin", "Windows": "win32"}.get(platform.system())
    arch = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "x64", "amd64": "x64"}.get(platform.machine().lower())
    return f"{system}-{arch}"


def native_check(directory, target, version, development):
    if target != host_target():
        if not development:
            raise ValueError("Release platform staging must run on its matching native OS/architecture.")
        return {"native_checked": False, "signature_checked": False}
    executable = directory / ("shou.exe" if target.startswith("win32-") else "shou")
    with tempfile.TemporaryDirectory(prefix="shou-npm-records-") as records:
        environment = {**os.environ, "SHOU_DATA_DIR": str(Path(records).resolve())}
        capabilities = json.loads(run(str(executable), "capabilities", "--json", env=environment))
        if not capabilities.get("ok") or capabilities["data"]["application_version"].split("+")[0] != version:
            raise ValueError("Native CLI and npm versions differ.")
        for command in (("rules", "schema"), ("rules", "catalog")):
            if not json.loads(run(str(executable), *command, "--json", env=environment)).get("ok"):
                raise ValueError("The packaged native rule resources are unavailable.")
    if not development:
        if target.startswith("darwin-"):
            run("codesign", "--verify", "--strict", str(executable))
        else:
            if not capabilities["data"].get("host_supported"):
                raise ValueError("This Windows host is below the minimum supported version.")
            # A temporary script receives the path as an argument, without interpolating it into code.
            with tempfile.TemporaryDirectory(prefix="shou-signature-") as temporary:
                script = Path(temporary) / "verify.ps1"
                script.write_text("param([string]$Path)\nif ((Get-AuthenticodeSignature -LiteralPath $Path).Status -ne 'Valid') { exit 1 }\n")
                run("powershell.exe", "-NoProfile", "-NonInteractive", "-File", str(script), str(executable))
    return {"native_checked": True, "signature_checked": not development}


def metadata(name, version, development):
    result = read(TEMPLATE / "package.json")
    result.update(name=name, version=version, private=development)
    return result


def receipt(directory, source, **fields):
    write(directory / "BUILD.json", {**source, **fields,
          "sha256": {path.relative_to(directory).as_posix(): digest(path) for path in sorted(directory.rglob("*")) if path.is_file()}})


def stage_platform(options, output, source):
    operating_system, arch = options.platform.split("-")
    payload = options.payload.resolve()
    validate_payload(payload, options.platform)
    if operating_system == "win32" and "shou/" + options.version not in read(payload / "shou.deps.json")["libraries"]:
        raise ValueError("The Windows payload dependency version differs from the requested npm version.")
    vendor = output / "vendor"
    vendor.mkdir()
    if operating_system == "darwin":
        for name in ("shou", *BUNDLES):
            copy(payload / name, vendor / name)
        (vendor / "shou").chmod(0o755)
    else:
        for path in sorted(payload.iterdir()):
            if path.name == "notices":
                continue
            copy(path, vendor / path.name)
    copy(ROOT / "LICENSE", output / "LICENSE")
    notices = output / "notices"
    notices.mkdir()
    for path in sorted(options.licenses.iterdir()):
        copy(path, notices / path.name)
    required_notices = ("SwiftAISDK-LICENSE.txt",) if operating_system == "darwin" else WINDOWS_NOTICES
    if any(not (notices / name).is_file() or (notices / name).stat().st_size == 0 for name in required_notices):
        raise ValueError("Provide --licenses with required dependency notices: " + ", ".join(required_notices))
    checked = native_check(vendor, options.platform, options.version, options.development)
    package = metadata("@limecloud/shou-" + options.platform, options.version, options.development)
    for name in ("bin", "engines", "optionalDependencies"):
        package.pop(name, None)
    package.update(os=[operating_system], cpu=[arch], files=["vendor/", "notices/", "payload.json", "BUILD.json", "LICENSE", "README.md"],
                   exports={"./payload.json": "./payload.json", "./package.json": "./package.json"})
    write(output / "package.json", package)
    write(output / "payload.json", {"schema_version": 1, "version": options.version, "platform": operating_system, "arch": arch,
                                    "executable": "vendor/" + ("shou.exe" if operating_system == "win32" else "shou")})
    (output / "README.md").write_text(f"# {package['name']}\n\nNative payload for @limecloud/shou@{options.version} on {options.platform}.\nInstall the public @limecloud/shou package to select the matching payload automatically.\n", encoding="utf-8")
    receipt(output, source, version=options.version, platform=options.platform, development=options.development, **checked)


def stage_launcher(options, output, source):
    packages = {}
    systems, architectures = set(), set()
    for directory in options.platform_package:
        manifest = read(directory / "package.json")
        payload = read(directory / "payload.json")
        build = read(directory / "BUILD.json")
        target = payload["platform"] + "-" + payload["arch"]
        if target not in PLATFORMS or manifest["name"] != "@limecloud/shou-" + target or target in packages:
            raise ValueError("Expected one supported native package per platform/architecture.")
        if manifest["version"] != options.version or payload["version"] != options.version or build["version"] != options.version:
            raise ValueError("All platform packages must match the launcher's exact version.")
        if manifest.get("os") != [payload["platform"]] or manifest.get("cpu") != [payload["arch"]] or payload["schema_version"] != 1:
            raise ValueError("Platform package metadata does not match its payload.")
        if build["source_commit"] != source["source_commit"] or build["worktree_sha256"] != source["worktree_sha256"]:
            raise ValueError("The launcher and native packages must record the same source checkout state.")
        if not options.development and (manifest.get("private") or build["development"] or not build["native_checked"] or not build["signature_checked"]):
            raise ValueError("Release launchers require verified release platform packages.")
        recorded = build["sha256"]
        actual = {path.relative_to(directory).as_posix(): digest(path) for path in sorted(directory.rglob("*")) if path.is_file() and path != directory / "BUILD.json"}
        if recorded != actual:
            raise ValueError("A platform package changed after verification.")
        validate_payload(directory / "vendor", target)
        packages[target] = {"name": manifest["name"], "build_sha256": digest(directory / "BUILD.json")}
        systems.add(payload["platform"])
        architectures.add(payload["arch"])
    manifest = metadata("@limecloud/shou", options.version, options.development)
    manifest.update(os=sorted(systems), cpu=sorted(architectures),
                    optionalDependencies={value["name"]: options.version for key, value in sorted(packages.items())})
    write(output / "package.json", manifest)
    for name in ("bin", "lib"):
        copy(TEMPLATE / name, output / name)
    (output / "bin/shou.cjs").chmod(0o755)
    copy(TEMPLATE / "README.md", output / "README.md")
    copy(ROOT / "LICENSE", output / "LICENSE")
    receipt(output, source, version=options.version, development=options.development, platform_packages=packages)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("platform", "launcher"):
        child = commands.add_parser(command)
        child.add_argument("--version", required=True)
        child.add_argument("--source-ref", default="HEAD")
        child.add_argument("--output", type=Path, required=True)
        child.add_argument("--development", action="store_true", help="Create a private local package; native checks may be unavailable.")
        if command == "platform":
            child.add_argument("--platform", choices=PLATFORMS, required=True)
            child.add_argument("--payload", type=Path, required=True)
            child.add_argument("--licenses", type=Path, required=True)
        else:
            child.add_argument("--platform-package", type=Path, action="append", required=True)
    options = parser.parse_args()
    try:
        if not SEMVER.fullmatch(options.version) or any(part.isdigit() and len(part) > 1 and part.startswith("0") for part in options.version.partition("-")[2].split(".")):
            raise ValueError("Choose an exact semantic version without build metadata.")
        if not options.development and (TEMPLATE / "releases" / f"{options.version}.json").exists():
            raise ValueError("This npm version already has a publication receipt; choose a new version.")
        output = options.output.resolve()
        if output.exists():
            raise ValueError("Output already exists; choose a new directory.")
        source = source_state(options.source_ref, options.development)
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".shou-npm-", dir=output.parent) as temporary:
            staging = Path(temporary) / "package"
            staging.mkdir()
            if options.command == "platform":
                stage_platform(options, staging, source)
            else:
                stage_launcher(options, staging, source)
            staging.rename(output)
        print(f"{'Private development' if options.development else 'Release'} npm {options.command} staged at {output}; nothing published.")
    except (ValueError, KeyError, OSError, json.JSONDecodeError, struct.error, subprocess.SubprocessError) as error:
        parser.exit(1, f"npm staging failed: {error}\n")


if __name__ == "__main__":
    main()
