#!/usr/bin/env python3
"""Export approved Shou raster masters offline; verify both platforms use the same bytes."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = ROOT / 'assets/design/illustrations'
NAMES = ['cleanup', 'applications', 'projects', 'space', 'large-files', 'privacy', 'startup', 'rules', 'history', 'settings']
SOURCES = ['scripts/export-workspace-artwork.swift', 'scripts/workspace_artwork.py',
           'scripts/artwork_alpha.py', 'assets/design/illustrations/generation.json',
           'assets/design/illustrations/source/reference.png']
SOURCES += ['assets/design/illustrations/source/' + name + '.png' for name in NAMES]
SOURCES += ['assets/design/illustrations/prompts/' + name + '.txt' for name in NAMES]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def import_generated(directory):
    # Image preparation is explicit and offline. Native rebuilds do not require Pillow.
    from PIL import Image
    from artwork_alpha import smooth_alpha
    source = DIRECTORY / 'source'
    prompts = DIRECTORY / 'prompts'
    source.mkdir(parents=True, exist_ok=True)
    prompts.mkdir(parents=True, exist_ok=True)
    records = {}
    for name in NAMES:
        raw_path = directory / (name + '.png')
        raw = Image.open(raw_path)
        if raw.mode != 'RGBA' or raw.getchannel('A').getextrema()[0] != 0:
            raise ValueError('Expected an RGBA cutout with transparent edges: ' + name)
        image = raw.copy()
        alpha = smooth_alpha(image, contour_radius=6)
        if not alpha.getbbox():
            raise ValueError('Artwork has no opaque subject: ' + name)
        image.putalpha(alpha)
        image = image.crop(alpha.getbbox())
        margin = round(max(image.size) * 0.045)
        master = Image.new('RGBA', (image.width + margin * 2, image.height + margin * 2))
        master.alpha_composite(image, (margin, margin))
        master.save(source / (name + '.png'), optimize=True)
        shutil.copyfile(directory / 'prompts' / (name + '.txt'), prompts / (name + '.txt'))
        records[name] = {'response_sha256': digest(raw_path), 'response_size': list(raw.size),
                         'master_sha256': digest(source / (name + '.png')), 'master_size': list(master.size)}
    record = {'date': '2026-10-26', 'mode': 'bundled imagegen CLI edit with the same mascot reference',
              'requested_model': 'gpt-image-2', 'quality': 'high', 'requested_size': '1024x1024',
              'reference': 'assets/design/illustrations/source/reference.png',
              'reference_sha256': digest(DIRECTORY / 'source/reference.png'),
              'preparation': 'Alpha clamp((a-230)*255/18), median 15, minimum 3, Gaussian contour radius 6, threshold 128, Gaussian antialias radius 0.85; RGB unchanged; crop and 4.5% transparent margin.',
              'images': records, 'credentials_stored': False}
    (DIRECTORY / 'generation.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')


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
    parser.add_argument('--import-generated', type=Path, help='Normalize approved RGBA responses and retain their prompts (requires Pillow)')
    args = parser.parse_args()
    if args.check and args.import_generated:
        parser.error('--check cannot import or modify artwork')
    if args.import_generated:
        import_generated(args.import_generated)
    if not args.check:
        DIRECTORY.mkdir(parents=True, exist_ok=True)
        executable = ROOT / '.build/artwork-export/export'
        executable.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['swiftc', str(ROOT / 'scripts/export-workspace-artwork.swift'), '-o', str(executable)], check=True)
        subprocess.run([str(executable), str(DIRECTORY / 'source'), str(DIRECTORY)], check=True)
        manifest = {'format_version': 2, 'scale': 3, 'sources': {name: digest(ROOT / name) for name in SOURCES},
                    'outputs': {name + '.png': digest(DIRECTORY / (name + '.png')) for name in NAMES}}
        (DIRECTORY / 'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    print(f'Workspace artwork verified: {len(verified())} transparent illustrations, source and output SHA-256.')


if __name__ == '__main__':
    main()
