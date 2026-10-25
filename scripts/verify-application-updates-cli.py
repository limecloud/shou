#!/usr/bin/env python3
"""Check the public catalog workflow using generated app metadata and private stores."""
from pathlib import Path
import argparse
import json
import os
import plistlib
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', nargs='?', type=Path, default=root / '.build/debug/shou')
parser.add_argument('--network', action='store_true')
arguments = parser.parse_args()
binary = arguments.binary.resolve()
allow_network = arguments.network
checks = 0
applications = Path.home() / 'Applications'
created_applications = not applications.exists()
assert not applications.is_symlink(), 'Generated application fixtures require an unlinked user Applications directory'
applications.mkdir(exist_ok=True)
try:
    with tempfile.TemporaryDirectory(prefix='Shou Update Fixtures ', dir=applications) as generated, tempfile.TemporaryDirectory(prefix='shou-update-records-') as records:
        base = Path(generated)
        store = Path(records) / 'not-created' / 'records'
        environment = dict(os.environ, SHOU_DATA_DIR=str(store))

        def run(*arguments, codes=(0,)):
            global checks
            process = subprocess.run([str(binary), *arguments, '--json'], env=environment,
                                     stdin=subprocess.DEVNULL, start_new_session=True,
                                     capture_output=True, text=True, timeout=25)
            assert process.returncode in codes, (arguments, process.returncode, process.stdout, process.stderr)
            result = json.loads(process.stdout)
            assert result['api_version'] == '1.0'
            assert not store.parent.exists(), 'Read-only catalog commands must not create business records'
            checks += 1
            return result

        app = base / 'Visual Studio Code.app'
        contents = app / 'Contents'
        contents.mkdir(parents=True)
        info = contents / 'Info.plist'
        values = {'CFBundleIdentifier': 'com.microsoft.VSCode', 'CFBundleShortVersionString': '0.1.0',
                  'CFBundlePackageType': 'APPL', 'CFBundleExecutable': 'Code'}
        info.write_bytes(plistlib.dumps(values))
        before = info.read_bytes()
        discovered = run('capabilities', '--command', 'applications updates')['data']['commands']
        assert len(discovered) == 2
        check_spec = next(item for item in discovered if item['command'].endswith(' check'))
        assert check_spec['side_effect'] == 'network'
        assert check_spec['input_schema']['properties']['allow-network']['enum'] == ['true']
        result = run('applications', 'updates', 'source', '--path', str(app))['data']
        assert result['status'] == 'available'
        assert result['source']['token'] == 'visual-studio-code'
        assert result['source']['official_url'] == 'https://formulae.brew.sh/cask/visual-studio-code'
        run('applications', 'updates', 'check', '--path', str(app), codes=(2,))
        for flag in ('false', 'yes', '1'):
            run('applications', 'updates', 'check', '--path', str(app), '--allow-network', flag, codes=(2,))
        run('applications', 'updates', 'source', '--path', str(app), '--unknown', 'value', codes=(2,))
        run('applications', 'updates', 'source', '--path', str(base / 'Missing.app'), codes=(5,))
        if allow_network:
            observation = run('applications', 'updates', 'check', '--path', str(app), '--allow-network', 'true')['data']
            assert observation['state'] == 'newer_catalog_version' and observation['catalog_version']
            assert observation['format_version'] == 1 and observation['status'] == 'complete'
        assert info.read_bytes() == before
        values['CFBundleIdentifier'] = 'dev.shou.generated.unsupported'
        info.write_bytes(plistlib.dumps(values))
        before = info.read_bytes()
        result = run('applications', 'updates', 'source', '--path', str(app))['data']
        assert result['status'] == 'unsupported' and result['source'] is None
        unsupported = run('applications', 'updates', 'check', '--path', str(app), '--allow-network', 'true')['data']
        assert unsupported['state'] == 'unsupported' and unsupported.get('source') is None
        assert unsupported['issues'] == ['update_source_unsupported']
        assert info.read_bytes() == before
finally:
    if created_applications:
        applications.rmdir()
print(f'{checks} application-update CLI checks passed; network={allow_network}; generated app metadata preserved and no record store created.')
