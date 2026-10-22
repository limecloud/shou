#!/usr/bin/env python3
"""Stage a self-contained macOS npm package from an unchanged release checkout."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "packages/shou-npm"
BUNDLES = ("Shou_ShouCore.bundle", "Shou_ShouContracts.bundle", "Shou_ShouAgentSupport.bundle")


def run(*args, cwd=ROOT):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    source = options.source.resolve()
    output = options.output.resolve()
    metadata = json.loads((TEMPLATE / "package.json").read_text())
    version = metadata["version"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise SystemExit("Expected a stable semantic version")
    tag = f"v{version}"
    receipt = TEMPLATE / "releases" / f"{version}.json"
    reference = json.loads(receipt.read_text())["source_commit"] if receipt.is_file() else tag
    commit = run("git", "rev-parse", f"{reference}^{{commit}}")
    tree = run("git", "rev-parse", f"{reference}^{{tree}}")
    entries = subprocess.check_output(["git", "ls-tree", "-r", "-z", reference], cwd=ROOT)
    tracked = set()
    for entry in entries.split(b"\0"):
        if not entry:
            continue
        info, name = entry.split(b"\t", 1)
        mode, kind, expected = info.split()
        if kind != b"blob" or mode not in (b"100644", b"100755"):
            raise SystemExit(f"Unsupported source entry: {os.fsdecode(name)}")
        relative = os.fsdecode(name)
        tracked.add(relative)
        data = (source / relative).read_bytes()
        actual = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        if actual != expected.decode():
            raise SystemExit(f"Source differs from {reference}: {relative}")
    # SwiftPM also compiles untracked Swift/C/C++ files inside its target roots.
    for directory in ("apps/cli/Sources", "packages", "skills"):
        for path in (source / directory).rglob("*"):
            if path.is_file() and path.relative_to(source).as_posix() not in tracked:
                raise SystemExit(f"Untracked source/resource: {path}")

    arm = source / ".build/arm64-apple-macosx/release"
    intel = source / ".build/x86_64-apple-macosx/release"
    for binary in (arm / "shou", intel / "shou"):
        if not binary.is_file():
            raise SystemExit(f"Build the Release CLI first: {binary}")
    if output.exists():
        raise SystemExit(f"Output already exists; choose a new directory: {output}")
    output.mkdir(parents=True)
    for name in ("package.json", "README.md"):
        shutil.copy2(TEMPLATE / name, output / name)
    shutil.copytree(TEMPLATE / "bin", output / "bin")
    (output / "bin/shou.cjs").chmod(0o755)
    shutil.copy2(source / "LICENSE", output / "LICENSE")
    shutil.copy2(source / ".build/checkouts/swift-ai-sdk/LICENSE", output / "SwiftAISDK-LICENSE.txt")
    vendor = output / "vendor"
    vendor.mkdir()
    binary = vendor / "shou"
    run("lipo", "-create", str(arm / "shou"), str(intel / "shou"), "-output", str(binary))
    run("strip", "-S", str(binary))
    binary.chmod(0o755)
    for name in BUNDLES:
        shutil.copytree(arm / name, vendor / name)
        run("codesign", "--force", "--sign", "-", str(vendor / name))
    run("codesign", "--force", "--sign", "-", "--identifier", "dev.limecloud.shou.cli", str(binary))
    run("codesign", "--verify", "--strict", str(binary))
    architectures = run("lipo", "-archs", str(binary)).split()
    if set(architectures) != {"arm64", "x86_64"}:
        raise SystemExit(f"Unexpected architectures: {architectures}")
    for line in run("otool", "-L", str(binary)).splitlines():
        if line.startswith("\t") and not line.strip().startswith(("/usr/lib/", "/System/Library/")):
            raise SystemExit(f"Non-system dynamic dependency: {line}")
    if not run(str(binary), "--version").startswith(f"shou {version} ("):
        raise SystemExit("Native CLI and npm versions differ")
    capabilities = json.loads(run(str(binary), "capabilities", "--json"))
    if not capabilities["ok"] or capabilities["data"]["application_version"] != version:
        raise SystemExit("Packaged native capabilities verification failed")
    skill = json.loads(run(str(binary), "skills", "read", "--json"))
    if not skill["ok"]:
        raise SystemExit("Packaged Skill resources are unavailable")
    hashes = {
        path.relative_to(output).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(output.rglob("*")) if path.is_file()
    }
    (output / "BUILD.json").write_text(json.dumps({
        "version": version,
        "source_tag": tag,
        "source_commit": commit,
        "source_tree": tree,
        "architectures": architectures,
        "swift": run("swift", "--version"),
        "sha256": hashes,
    }, indent=2) + "\n")
    print(f"Verified npm package staged at {output}")


if __name__ == "__main__":
    main()
