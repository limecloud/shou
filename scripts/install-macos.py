#!/usr/bin/env python3
"""Verify and replace a local Shou installation without retaining the old app."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import uuid


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)


def hashes(directory):
    result = {}
    for path in directory.rglob('*'):
        if not path.is_file() or path.is_symlink():
            continue
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        result[str(path.relative_to(directory))] = digest.hexdigest()
    return result


def verify(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'dev.limecloud.shou':
        raise ValueError('Expected the Shou application bundle.')
    run('codesign', '--verify', '--deep', '--strict', str(app))
    cli = app / 'Contents/Helpers/shou'
    version = run(str(cli), '--version').stdout.strip()
    if not version.startswith('shou ' + info['CFBundleShortVersionString'] + ' '):
        raise ValueError('Desktop and CLI versions differ.')
    skill = json.loads(run(str(cli), 'agent', 'skill', '--json').stdout)['data']
    if not Path(skill['entrypoint']).resolve().is_relative_to(app.resolve()):
        raise ValueError('CLI resources must resolve inside the packaged application.')
    return info


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=root / 'dist/Shou.app')
    parser.add_argument('--destination', type=Path, default=Path('/Applications/Shou.app'))
    parser.add_argument('--check', action='store_true', help='Verify the candidate without installing it.')
    args = parser.parse_args()
    source = args.source.expanduser().resolve(strict=True)
    destination = args.destination.expanduser().absolute()
    if (source == destination or destination.name != 'Shou.app' or destination.is_symlink()
            or source.is_relative_to(destination) or destination.is_relative_to(source)):
        raise ValueError('Choose a separate, real Shou.app installation path.')
    info = verify(source)
    if args.check:
        print(json.dumps({'verified': True, 'source': str(source), 'version': info['CFBundleShortVersionString'],
                          'signing_mode': info.get('ShouSigningMode', 'unknown')}))
        return
    executable = destination / 'Contents/MacOS/Shou'
    running = subprocess.run(['pgrep', '-f', '^' + re.escape(str(executable)) + r'( |$)'], capture_output=True)
    if running.returncode not in (0, 1):
        raise RuntimeError('Could not check whether Shou is running.')
    if running.returncode == 0:
        raise RuntimeError('Quit Shou normally before installing. No files were replaced.')
    records = Path.home() / 'Library/Application Support/Shou'
    before = hashes(records)
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6]
    evidence = root / '.build/local-install' / stamp
    evidence.mkdir(parents=True)
    staged = destination.with_name('.Shou-install-' + stamp + '.app')
    run('ditto', str(source), str(staged))
    verify(staged)
    expected = hashes(staged)
    if destination.exists():
        previous_info = plistlib.loads((destination / 'Contents/Info.plist').read_bytes())
        if previous_info.get('CFBundleIdentifier') != 'dev.limecloud.shou':
            raise ValueError('Refusing to replace an application with a different bundle identifier.')
        # The replacement is fully staged and verified first. Remove only the selected
        # application bundle; user records and settings live outside it.
        shutil.rmtree(destination)
    os.rename(staged, destination)
    verify(destination)
    if hashes(destination) != expected:
        raise RuntimeError('Installed app bytes differ from the verified candidate.')
    after = hashes(records)
    if any(after.get(name) != digest for name, digest in before.items()):
        raise RuntimeError('An existing Shou record changed during installation.')
    result = {'installed': str(destination), 'version': info['CFBundleShortVersionString'],
              'signing_mode': info.get('ShouSigningMode', 'unknown'), 'backup': None, 'installation_mode': 'replace',
              'verified_file_count': len(expected), 'preserved_record_count': len(before)}
    (evidence / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
