#!/usr/bin/env python3
"""Export Shou's approved artwork for its future website; never call a model service."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / 'assets/brand/web'
NAMES = ['cleanup', 'applications', 'projects', 'space', 'large-files', 'privacy', 'startup', 'rules', 'history', 'settings']
INPUTS = ['scripts/export-web-brand.py', 'assets/brand/shou-mascot.png', 'assets/brand/shou-icon-1024.png',
          'assets/brand/shou-mascot-source.png', 'assets/design/tokens.json']
INPUTS += ['assets/design/illustrations/' + name + '.png' for name in NAMES]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sources():
    return {name: digest(ROOT / name) for name in INPUTS}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--font', type=Path, default=Path('/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf'))
    args = parser.parse_args()
    manifest = DESTINATION / 'manifest.json'
    if args.check:
        record = json.loads(manifest.read_text())
        if record['sources'] != sources():
            raise ValueError('Website artwork source changed; regenerate the web brand kit.')
        for name, expected in record['outputs'].items():
            if digest(DESTINATION / name) != expected:
                raise ValueError('Website artwork bytes differ: ' + name)
        print('Website brand kit verified:', len(record['outputs']), 'files; no network access required.')
        return

    from PIL import Image, ImageDraw, ImageFont
    if not args.font.is_file():
        parser.error('Provide a local rounded bold TTF using --font; no font is downloaded or shipped.')
    DESTINATION.mkdir(parents=True, exist_ok=True)
    illustrations = DESTINATION / 'illustrations'
    illustrations.mkdir(exist_ok=True)
    generated = []

    def save(image, name, **options):
        image.save(DESTINATION / name, **options)
        generated.append(name)

    mascot = Image.open(ROOT / 'assets/brand/shou-mascot.png').convert('RGBA')
    icon = Image.open(ROOT / 'assets/brand/shou-icon-1024.png').convert('RGBA')
    tile = Image.open(ROOT / 'assets/brand/shou-mascot-source.png').convert('RGBA')
    save(mascot, 'logo-symbol.png', optimize=True)
    save(mascot, 'logo-symbol.webp', lossless=True, method=4)
    for size in (16, 32):
        save(icon.resize((size, size), Image.Resampling.LANCZOS), f'favicon-{size}.png', optimize=True)
    save(icon, 'favicon.ico', format='ICO', sizes=[(16, 16), (32, 32), (48, 48)])
    for name, size in [('apple-touch-icon.png', 180), ('icon-192.png', 192), ('icon-512.png', 512)]:
        save(tile.resize((size, size), Image.Resampling.LANCZOS), name, optimize=True)

    font = ImageFont.truetype(str(args.font), 292)
    colors = json.loads((ROOT / 'assets/design/tokens.json').read_text())['colors']
    for name, token in [('light', 'ShouArtworkInk'), ('dark', 'ShouArtworkPaper')]:
        color = '#' + colors[token][3:]
        logo = Image.new('RGBA', (1440, 480))
        symbol = mascot.resize((440, 440), Image.Resampling.LANCZOS)
        logo.alpha_composite(symbol, (0, 20))
        draw = ImageDraw.Draw(logo)
        bounds = draw.textbbox((0, 0), 'Shou', font=font)
        draw.text((470, (480 - bounds[3] + bounds[1]) / 2 - bounds[1]), 'Shou', font=font, fill=color)
        save(logo, f'logo-horizontal-{name}.png', optimize=True)
        save(logo, f'logo-horizontal-{name}.webp', lossless=True, method=4)
    for name in NAMES:
        image = Image.open(ROOT / f'assets/design/illustrations/{name}.png').convert('RGBA')
        save(image, f'illustrations/{name}.webp', quality=92, method=4, exact=True)

    record = {'format_version': 1, 'sources': sources(),
              'wordmark_font': {'name': font.getname(), 'sha256': digest(args.font), 'embedded': False},
              'outputs': {name: digest(DESTINATION / name) for name in sorted(generated)}}
    manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    print('Website brand kit exported:', len(generated), 'files; canonical originals unchanged.')


if __name__ == '__main__':
    main()
