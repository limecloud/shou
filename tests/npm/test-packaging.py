#!/usr/bin/env python3
"""Generated-payload tests for npm architecture, provenance and staging boundaries."""

import importlib.util
import json
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("npm_staging", ROOT / "scripts/package-npm.py")
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="shou-npm-打包 ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.payload = self.root / "payload"
        self.payload.mkdir()
        for name in staging.WINDOWS_FILES:
            (self.payload / name).write_bytes(b"fixture")
        image = bytearray(72)
        image[:2] = b"MZ"
        struct.pack_into("<I", image, 60, 64)
        image[64:68] = b"PE\0\0"
        struct.pack_into("<H", image, 68, 0x8664)
        for name in ("shou.exe", "coreclr.dll", "hostfxr.dll", "hostpolicy.dll"):
            (self.payload / name).write_bytes(image)
        staging.write(self.payload / "shou.runtimeconfig.json", {"runtimeOptions": {"tfm": "net10.0",
                      "includedFrameworks": [{"name": "Microsoft.NETCore.App", "version": "10.0.13"}]}})
        staging.write(self.payload / "shou.deps.json", {"runtimeTarget": {"name": ".NETCoreApp,Version=v10.0/win-x64"},
                      "libraries": {"shou/0.12.0-dev": {}, "runtimepack.Microsoft.NETCore.App.Runtime.win-x64/10.0.13": {}}})
        self.licenses = self.root / "licenses"
        self.licenses.mkdir()
        for name in staging.WINDOWS_NOTICES:
            (self.licenses / name).write_text("Generated fixture license\n")
        self.source = {"source_commit": "a" * 40, "source_tree": "b" * 40, "source_dirty": True, "worktree_sha256": "c" * 64}
        self.host = patch.object(staging, "host_target", return_value="different-host")
        self.host.start()
        self.addCleanup(self.host.stop)

    def native(self, name="native"):
        output = self.root / name
        output.mkdir()
        options = SimpleNamespace(platform="win32-x64", payload=self.payload, licenses=self.licenses,
                                  version="0.12.0-dev", development=True)
        staging.stage_platform(options, output, self.source)
        return output

    def launcher(self, packages, version="0.12.0-dev", development=True, source=None):
        output = self.root / "launcher"
        output.mkdir(exist_ok=True)
        staging.stage_launcher(SimpleNamespace(platform_package=packages, version=version, development=development),
                               output, source or self.source)
        return output

    def test_private_staging_records_exact_metadata_not_native_acceptance(self):
        native = self.native()
        manifest = staging.read(native / "package.json")
        self.assertTrue(manifest["private"])
        self.assertEqual(manifest["os"], ["win32"])
        self.assertEqual(manifest["cpu"], ["x64"])
        self.assertNotIn("bin", manifest)
        self.assertNotIn("scripts", manifest)
        build = staging.read(native / "BUILD.json")
        self.assertFalse(build["native_checked"])
        self.assertFalse(build["signature_checked"])
        self.assertTrue(build["development"])
        main = self.launcher([native])
        public = staging.read(main / "package.json")
        self.assertEqual(public["optionalDependencies"], {"@limecloud/shou-win32-x64": "0.12.0-dev"})
        self.assertFalse((main / "vendor").exists())

    def test_architecture_mismatch_refuses_native_payload(self):
        with self.assertRaisesRegex(ValueError, "architecture"):
            staging.validate_payload(self.payload, "win32-arm64")

    def test_missing_runtime_and_framework_dependent_payloads_refuse_staging(self):
        (self.payload / "coreclr.dll").unlink()
        with self.assertRaisesRegex(ValueError, "Missing self-contained"):
            staging.validate_payload(self.payload, "win32-x64")
        (self.payload / "coreclr.dll").write_bytes((self.payload / "shou.exe").read_bytes())
        staging.write(self.payload / "shou.runtimeconfig.json", {"runtimeOptions": {"tfm": "net10.0", "framework": {"name": "Microsoft.NETCore.App"}}})
        with self.assertRaisesRegex(ValueError, "include its .NET"):
            staging.validate_payload(self.payload, "win32-x64")

    def test_ui_dependencies_cannot_enter_the_independent_cli(self):
        value = staging.read(self.payload / "shou.deps.json")
        value["libraries"]["Microsoft.WindowsAppSDK/1.8.0"] = {}
        staging.write(self.payload / "shou.deps.json", value)
        with self.assertRaisesRegex(ValueError, "desktop UI"):
            self.native()

    def test_missing_dependency_notices_refuse_staging(self):
        (self.licenses / staging.WINDOWS_NOTICES[0]).unlink()
        with self.assertRaisesRegex(ValueError, "required dependency notices"):
            self.native()

    def test_native_dependency_version_must_match_npm_version(self):
        value = staging.read(self.payload / "shou.deps.json")
        value["libraries"] = {"shou/0.11.0": {}}
        staging.write(self.payload / "shou.deps.json", value)
        with self.assertRaisesRegex(ValueError, "dependency version"):
            self.native()

    def test_launcher_rejects_different_versions_sources_or_duplicate_platforms(self):
        native = self.native()
        with self.assertRaisesRegex(ValueError, "exact version"):
            self.launcher([native], version="0.12.0")
        with self.assertRaisesRegex(ValueError, "same source"):
            self.launcher([native], source={**self.source, "worktree_sha256": "d" * 64})
        with self.assertRaisesRegex(ValueError, "one supported"):
            self.launcher([native, native])

    def test_launcher_rejects_modified_final_bytes(self):
        native = self.native()
        with (native / "vendor/shou.exe").open("ab") as stream:
            stream.write(b"changed after verification")
        with self.assertRaisesRegex(ValueError, "changed after verification"):
            self.launcher([native])

    def test_release_launcher_cannot_promote_private_unverified_platform_packages(self):
        native = self.native()
        with self.assertRaisesRegex(ValueError, "verified release"):
            self.launcher([native], development=False)

    def test_copy_refuses_linked_payloads(self):
        if not hasattr(Path, "symlink_to"):
            self.skipTest("Symlinks are unavailable")
        link = self.payload / "linked.txt"
        try:
            link.symlink_to(self.licenses / staging.WINDOWS_NOTICES[0])
        except OSError:
            self.skipTest("Creating symlinks requires unavailable privileges")
        with self.assertRaisesRegex(ValueError, "symbolic link"):
            self.native()


if __name__ == "__main__":
    unittest.main()
