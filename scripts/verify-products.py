#!/usr/bin/env python3
"""Detect CLI/desktop artifact collisions on case-insensitive filesystems."""
from pathlib import Path
import argparse
import hashlib
import plistlib
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--bin', default='.build/debug')
parser.add_argument('--app')
args = parser.parse_args()
if sys.platform != 'darwin':
    raise SystemExit(0)
binary = Path(args.bin)
desktop, cli = binary / 'ShouDesktop', binary / 'shou'
assert desktop.exists() and cli.exists()
assert not desktop.samefile(cli), 'Desktop and CLI resolve to the same artifact'
assert hashlib.sha256(desktop.read_bytes()).digest() != hashlib.sha256(cli.read_bytes()).digest()
version = subprocess.run([str(cli.resolve()), '--version'], capture_output=True, text=True, timeout=10, check=True)
assert version.stdout.startswith('shou ')
links = subprocess.run(['otool', '-L', str(desktop)], capture_output=True, text=True, check=True)
assert 'SwiftUI.framework' in links.stdout, 'Desktop product does not link SwiftUI'
if args.app:
    app = Path(args.app)
    # Signing modifies Mach-O bytes; compare the native dependencies and run the
    # packaged CLI instead of comparing signed files against unsigned hashes.
    packaged = subprocess.run([str((app / 'Contents/Helpers/shou').resolve()), '--version'], capture_output=True, text=True, timeout=10, check=True)
    assert packaged.stdout == version.stdout
    linked = subprocess.run(['otool', '-L', str(app / 'Contents/MacOS/Shou')], capture_output=True, text=True, check=True)
    assert 'SwiftUI.framework' in linked.stdout
    assert (app / 'Contents/Resources/Shou_ShouCore.bundle/builtin-rules.json').exists()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIconFile'] == 'Shou'
    icon = app / 'Contents/Resources/Shou.icns'
    assert icon.read_bytes()[:4] == b'icns'
    assert icon.read_bytes() == Path('assets/brand/Shou.icns').read_bytes(), 'Stale packaged application icon'
    assert (app / 'Contents/Resources/LICENSE.txt').read_bytes() == Path('LICENSE').read_bytes()
    assert (app / 'Contents/Resources/Sparkle-LICENSE.txt').read_bytes() == Path('.build/artifacts/sparkle/Sparkle/LICENSE').read_bytes()
    assert set(info['CFBundleLocalizations']) == {'en', 'zh-Hans'}
    resources = app / 'Contents/Resources/Shou_ShouCore.bundle'
    for language in ('en', 'zh-Hans'):
        localized = next(item for item in resources.glob('*.lproj') if item.stem.lower() == language.lower())
        source = Path(f'packages/shou-core/Sources/Resources/{language}.lproj/Localizable.strings')
        assert (localized / 'Localizable.strings').read_bytes() == source.read_bytes(), f'Stale packaged translations: {language}'
print('Desktop and CLI products verified as distinct native executables.')
