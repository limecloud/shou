#!/usr/bin/env python3
"""Copy dependency notices from the exact restored runtime and SDK packages."""

import argparse
import json
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET


def prepare(payload, assets):
    configuration = json.loads((payload / "shou.runtimeconfig.json").read_text(encoding="utf-8"))
    runtime = next(value["version"] for value in configuration["runtimeOptions"]["includedFrameworks"] if value["name"] == "Microsoft.NETCore.App")
    dependencies = json.loads((payload / "shou.deps.json").read_text(encoding="utf-8"))
    rid = dependencies["runtimeTarget"]["name"].rsplit("/", 1)[1]
    sdk = next(name.split("/", 1)[1] for name in dependencies["libraries"] if name.startswith("runtimepack.Microsoft.Windows.SDK.NET.Ref/"))
    folders = json.loads(assets.read_text(encoding="utf-8"))["packageFolders"]

    def package(name, version):
        for folder in folders:
            candidate = Path(folder) / name.lower() / version
            if candidate.is_dir():
                return candidate
        raise ValueError(f"Restored package unavailable: {name}/{version}")

    runtime_package = package("Microsoft.NETCore.App.Runtime." + rid, runtime)
    sdk_package = package("Microsoft.Windows.SDK.NET.Ref", sdk)
    metadata = ET.parse(sdk_package / "microsoft.windows.sdk.net.ref.nuspec").getroot()
    namespace = {"n": metadata.tag.split("}")[0][1:]}
    license_url = metadata.findtext("n:metadata/n:licenseUrl", namespaces=namespace)
    copyright_notice = metadata.findtext("n:metadata/n:copyright", namespaces=namespace)
    if not license_url or not copyright_notice:
        raise ValueError("The Windows SDK package has no license/copyright metadata.")
    output = payload / "notices"
    output.mkdir(exist_ok=True)
    shutil.copy2(runtime_package / "LICENSE.TXT", output / "DOTNET-LICENSE.txt")
    shutil.copy2(runtime_package / "THIRD-PARTY-NOTICES.TXT", output / "DOTNET-THIRD-PARTY-NOTICES.txt")
    (output / "WINDOWS-SDK-NOTICE.txt").write_text(
        f"Microsoft.Windows.SDK.NET.Ref {sdk}\n{copyright_notice}\nLicense terms: {license_url}\n"
        "Redistributed runtime projections: Microsoft.Windows.SDK.NET.dll and WinRT.Runtime.dll.\n", encoding="utf-8")
    print(f"Windows CLI dependency notices prepared: .NET {runtime}, Windows SDK projections {sdk}.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--payload", type=Path, required=True)
    parser.add_argument("--assets", type=Path, required=True)
    options = parser.parse_args()
    prepare(options.payload.resolve(), options.assets.resolve())
