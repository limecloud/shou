#!/usr/bin/env python3
"""Export native artwork on macOS; verify source/output identities on every platform."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import design_tokens

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = ROOT / 'assets/design/illustrations'
SOURCES = [
    'assets/design/tokens.json',
    'apps/macos/Sources/WorkspaceIllustration.swift',
    'apps/macos/Sources/WorkspacePageArtwork.swift',
    'scripts/export-workspace-artwork.swift',
    'scripts/workspace_artwork.py',
    'scripts/design_tokens.py',
]
NAMES = ['cleanup', 'applications', 'projects', 'space', 'large-files', 'privacy', 'startup', 'rules', 'history', 'settings']


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verified():
    manifest = json.loads((DIRECTORY / 'manifest.json').read_text())
    if manifest['sources'] != {name: digest(ROOT / name) for name in SOURCES}:
        raise ValueError('Artwork source changed; run python3 scripts/workspace_artwork.py on macOS.')
    expected = {name + '.png' for name in NAMES}
    if set(manifest['outputs']) != expected:
        raise ValueError('Artwork manifest does not contain all ten task illustrations.')
    result = {}
    for name in sorted(expected):
        data = (DIRECTORY / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != manifest['outputs'][name] or data[:8] != b'\x89PNG\r\n\x1a\n':
            raise ValueError('Artwork bytes do not match the recorded PNG: ' + name)
        result[name] = data
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if not args.check:
        DIRECTORY.mkdir(parents=True, exist_ok=True)
        executable = ROOT / '.build/artwork-export/export'
        executable.parent.mkdir(parents=True, exist_ok=True)
        design = executable.parent / 'Design.swift'
        design.write_bytes(design_tokens.swift(design_tokens.load()))
        subprocess.run(['swiftc', '-parse-as-library', str(design),
                        str(ROOT / SOURCES[1]), str(ROOT / SOURCES[2]), str(ROOT / SOURCES[3]), '-o', str(executable)], check=True)
        subprocess.run([str(executable), str(DIRECTORY)], check=True)
        manifest = {'format_version': 1, 'scale': 3, 'sources': {name: digest(ROOT / name) for name in SOURCES},
                    'outputs': {name + '.png': digest(DIRECTORY / (name + '.png')) for name in NAMES}}
        (DIRECTORY / 'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    print(f'Workspace artwork verified: {len(verified())} transparent illustrations, source and output SHA-256.')


if __name__ == '__main__':
    main()
