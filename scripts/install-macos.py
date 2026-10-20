#!/usr/bin/env python3
"""Verify and install a local Shou build, retaining the previous app and all records."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
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
    if source == destination or destination.name != 'Shou.app' or destination.is_symlink():
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
    backup = evidence / 'previous/Shou.app'
    if destination.exists():
        backup.parent.mkdir()
        # Keep the entire previous installation; no destructive replacement.
        os.rename(destination, backup)
        retained = backup
    else:
        retained = None
    try:
        os.rename(staged, destination)
        verify(destination)
        if hashes(destination) != expected:
            raise RuntimeError('Installed app bytes differ from the verified candidate.')
        after = hashes(records)
        if any(after.get(name) != digest for name, digest in before.items()):
            raise RuntimeError('An existing Shou record changed during installation.')
    except Exception:
        if destination.exists():
            os.rename(destination, evidence / 'failed-Shou.app')
        if retained is not None:
            os.rename(retained, destination)
        raise
    result = {'installed': str(destination), 'version': info['CFBundleShortVersionString'],
              'signing_mode': info.get('ShouSigningMode', 'unknown'), 'backup': str(backup) if backup.exists() else None,
              'verified_file_count': len(expected), 'preserved_record_count': len(before)}
    (evidence / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
