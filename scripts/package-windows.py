#!/usr/bin/env python3
"""Validate and archive self-contained Windows preview payloads for GitHub."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import zipfile


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def machine(path):
    with path.open('rb') as stream:
        header = stream.read(64)
        if len(header) != 64 or header[:2] != b'MZ':
            raise ValueError(f'Invalid PE image: {path}')
        stream.seek(struct.unpack_from('<I', header, 60)[0])
        signature = stream.read(6)
    if len(signature) != 6 or signature[:4] != b'PE\0\0':
        raise ValueError(f'Invalid PE signature: {path}')
    return struct.unpack_from('<H', signature, 4)[0]


def validate(payload, kind, version, runtime):
    stem = 'Shou.Windows.App' if kind == 'app' else 'shou'
    files = [stem + suffix for suffix in ['.exe', '.dll', '.deps.json', '.runtimeconfig.json']]
    files += ['coreclr.dll', 'hostfxr.dll', 'hostpolicy.dll', 'System.Private.CoreLib.dll',
              'Shou.Windows.Core.dll', 'Shou.Windows.Platform.dll',
              'notices/DOTNET-LICENSE.txt', 'notices/DOTNET-THIRD-PARTY-NOTICES.txt', 'notices/WINDOWS-SDK-NOTICE.txt']
    if kind == 'app':
        files += ['resources.pri', 'Microsoft.UI.Xaml.dll', 'Shou.Windows.Presentation.dll', 'notices/WINDOWS-APP-SDK-NOTICE.txt']
    for name in files:
        if not (payload / name).is_file() or not (payload / name).stat().st_size:
            raise ValueError(f'Missing self-contained {kind} dependency: {name}')
    expected = 0xAA64 if runtime == 'win-arm64' else 0x8664
    for name in [stem + '.exe', 'coreclr.dll', 'hostfxr.dll'] + (['Microsoft.UI.Xaml.dll'] if kind == 'app' else []):
        if machine(payload / name) != expected:
            raise ValueError(f'Architecture mismatch: {name}')
    deps = json.loads((payload / (stem + '.deps.json')).read_text(encoding='utf-8-sig'))
    if deps['runtimeTarget']['name'].rsplit('/', 1)[-1] != runtime or stem + '/' + version not in deps['libraries']:
        raise ValueError('Native dependency RID/version differs from the requested release.')
    configuration = json.loads((payload / (stem + '.runtimeconfig.json')).read_text(encoding='utf-8-sig'))
    frameworks = configuration['runtimeOptions'].get('includedFrameworks', [])
    if not any(value['name'] == 'Microsoft.NETCore.App' and value['version'].startswith('10.') for value in frameworks):
        raise ValueError('A self-contained .NET 10 runtime is required.')
    return stem


def package(payload_root, output, version, runtime, source, native_checked):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'[0-9a-f]{40}', source):
        raise ValueError('Use a release version and an exact source commit.')
    arch = runtime.removeprefix('win-')
    output.mkdir(parents=True, exist_ok=True)
    receipts = []
    root = Path(__file__).resolve().parents[1]
    for kind in ['app', 'cli']:
        payload = payload_root / kind
        validate(payload, kind, version, runtime)
        name = ('Shou' if kind == 'app' else 'shou-cli') + f'-{version}-windows-{arch}.zip'
        archive = output / name
        if archive.exists():
            raise ValueError(f'Refusing to overwrite an archive: {archive}')
        paths = sorted(path for path in payload.rglob('*') if path.is_file())
        if any(path.is_symlink() for path in payload.rglob('*')):
            raise ValueError('Archive payloads cannot contain symbolic links.')
        if (payload / 'BUILD.json').exists():
            raise ValueError('BUILD.json is reserved for verified release metadata.')
        hashes = {path.relative_to(payload).as_posix(): digest(path) for path in paths}
        receipt = {'format_version': 1, 'version': version, 'source_commit': source, 'configuration': 'Release',
                   'runtime': runtime, 'kind': kind, 'minimum_windows_build': 22000, 'signing': 'unsigned',
                   'distribution': 'portable-preview', 'native_smoke_checked': native_checked,
                   'public_mutation_available': False, 'files': hashes}
        with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED) as bundle:
            for path in paths:
                bundle.write(path, path.relative_to(payload).as_posix())
            bundle.write(root / 'LICENSE', 'SHOU-LICENSE.txt')
            bundle.writestr('BUILD.json', json.dumps(receipt, indent=2) + '\n')
        with zipfile.ZipFile(archive) as bundle:
            if bundle.testzip() is not None:
                raise ValueError('Archive integrity validation failed.')
            for name, expected in hashes.items():
                if hashlib.sha256(bundle.read(name)).hexdigest() != expected:
                    raise ValueError('Archived bytes differ from the validated payload.')
        receipts.append({'file': archive.name, 'sha256': digest(archive), 'bytes': archive.stat().st_size})
    (output / ('SHA256SUMS-windows-' + arch)).write_text(''.join(value['sha256'] + '  ' + value['file'] + '\n' for value in receipts), encoding='utf-8')
    print(json.dumps({'version': version, 'runtime': runtime, 'assets': receipts}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--payload-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--runtime', choices=['win-x64', 'win-arm64'], required=True)
    parser.add_argument('--source', required=True)
    parser.add_argument('--native-checked', action='store_true')
    args = parser.parse_args()
    package(args.payload_root.resolve(), args.output.resolve(), args.version, args.runtime, args.source, args.native_checked)
