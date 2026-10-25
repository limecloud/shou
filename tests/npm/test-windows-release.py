import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('windows_release', ROOT / 'scripts/package-windows.py')
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class WindowsReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='shou-generated-windows-release-')
        self.root = Path(self.temporary.name)
        for kind in ['app', 'cli']:
            payload = self.root / 'publish' / kind
            payload.mkdir(parents=True)
            stem = 'Shou.Windows.App' if kind == 'app' else 'shou'
            names = ['coreclr.dll', 'hostfxr.dll', 'hostpolicy.dll', 'System.Private.CoreLib.dll',
                     'Shou.Windows.Core.dll', 'Shou.Windows.Platform.dll', stem + '.exe', stem + '.dll',
                     'notices/DOTNET-LICENSE.txt', 'notices/DOTNET-THIRD-PARTY-NOTICES.txt', 'notices/WINDOWS-SDK-NOTICE.txt']
            if kind == 'app':
                names += ['Microsoft.UI.Xaml.dll', stem + '.pri', 'Shou.Windows.Presentation.dll', 'notices/WINDOWS-APP-SDK-NOTICE.txt']
            image = b'MZ' + b'\0' * 58 + struct.pack('<I', 64) + b'PE\0\0' + struct.pack('<H', 0x8664)
            for name in names:
                path = payload / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(image if path.suffix in ['.exe', '.dll'] else b'generated fixture')
            (payload / (stem + '.deps.json')).write_text(json.dumps({'runtimeTarget': {'name': '.NETCoreApp,Version=v10.0/win-x64'}, 'libraries': {stem + '/0.14.0': {}}}))
            (payload / (stem + '.runtimeconfig.json')).write_text(json.dumps({'runtimeOptions': {'includedFrameworks': [{'name': 'Microsoft.NETCore.App', 'version': '10.0.13'}]}}))

    def tearDown(self):
        self.temporary.cleanup()

    def package(self):
        PACKAGE.package(self.root / 'publish', self.root / 'archives', '0.14.0', 'win-x64', 'a' * 40, True)

    def test_archives_bind_payload_bytes_version_source_and_capability_limits(self):
        self.package()
        archives = sorted((self.root / 'archives').glob('*.zip'))
        self.assertEqual(2, len(archives))
        for archive in archives:
            with zipfile.ZipFile(archive) as bundle:
                receipt = json.loads(bundle.read('BUILD.json'))
                self.assertEqual('0.14.0', receipt['version'])
                self.assertEqual('a' * 40, receipt['source_commit'])
                self.assertFalse(receipt['public_mutation_available'])
                self.assertEqual('portable-preview', receipt['distribution'])
                self.assertEqual('unsigned', receipt['signing'])
                self.assertEqual(len(bundle.namelist()), len(set(bundle.namelist())))
                self.assertEqual((ROOT / 'LICENSE').read_bytes(), bundle.read('SHOU-LICENSE.txt'))

    def test_wrong_architecture_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Architecture mismatch'):
            PACKAGE.validate(self.root / 'publish/app', 'app', '0.14.0', 'win-arm64')

    def test_missing_native_runtime_is_rejected(self):
        (self.root / 'publish/app/hostfxr.dll').unlink()
        with self.assertRaisesRegex(ValueError, 'dependency'):
            self.package()

    def test_wrong_version_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'RID/version'):
            PACKAGE.validate(self.root / 'publish/cli', 'cli', '0.15.0', 'win-x64')

    def test_framework_dependent_payload_is_rejected(self):
        (self.root / 'publish/cli/shou.runtimeconfig.json').write_text('{"runtimeOptions": {}}')
        with self.assertRaisesRegex(ValueError, 'self-contained'):
            self.package()

    def test_untrusted_link_is_rejected(self):
        try:
            (self.root / 'publish/app/foreign').symlink_to(ROOT / 'LICENSE')
        except OSError as error:
            self.skipTest(f'The host does not grant generated symlink creation: {error}')
        with self.assertRaisesRegex(ValueError, 'symbolic links'):
            self.package()

    def test_reserved_receipt_is_rejected(self):
        (self.root / 'publish/app/BUILD.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'reserved'):
            self.package()

    def test_existing_archive_is_not_replaced(self):
        self.package()
        with self.assertRaisesRegex(ValueError, 'overwrite'):
            self.package()


if __name__ == '__main__':
    unittest.main()
