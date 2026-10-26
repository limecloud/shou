#!/usr/bin/env python3
"""Prepare approved brand response offline; native builds use the saved masters."""
import argparse
import hashlib
import json
from pathlib import Path

from artwork_alpha import smooth_alpha

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True, help='Approved RGBA model response, never a URL')
    args = parser.parse_args()
    from PIL import Image, ImageDraw, ImageFilter

    raw = Image.open(args.source)
    if raw.mode != 'RGBA' or raw.getchannel('A').getextrema()[0] != 0:
        parser.error('Expected the approved RGBA cutout with transparent edges.')
    brand = ROOT / 'assets/brand'
    record = json.loads((brand / 'generation.json').read_text())
    if digest(args.source) != record['response']['sha256']:
        parser.error('Source bytes differ from the approved response recorded in generation.json.')
    alpha = smooth_alpha(raw, contour_radius=14)
    image = raw.copy()
    image.putalpha(alpha)

    # Preserve the original app-tile composition and background palette.
    tile = Image.new('RGBA', (1024, 1024))
    pixels = tile.load()
    start, end = (250, 250, 241), (211, 239, 229)
    for y in range(1024):
        for x in range(1024):
            t = (x + y) / 2046
            pixels[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(start, end)) + (255,)
    shadow = Image.new('RGBA', tile.size)
    ImageDraw.Draw(shadow).ellipse((190, 822, 840, 878), fill=(20, 74, 64, 40))
    tile.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)))
    tile.alpha_composite(image.resize(tile.size, Image.Resampling.LANCZOS))
    tile.save(brand / 'shou-mascot-source.png', optimize=True)

    subject = image.crop(alpha.getbbox())
    side = max(subject.size) + 96
    mascot = Image.new('RGBA', (side, side))
    mascot.alpha_composite(subject, ((side - subject.width) // 2, (side - subject.height) // 2))
    mascot = mascot.resize((1024, 1024), Image.Resampling.LANCZOS)
    mascot.save(brand / 'shou-mascot.png', optimize=True)
    record['preparation']['alpha_filters'] = 'median 15, minimum 3, Gaussian contour radius 14, threshold 128, Gaussian antialias radius 0.85 at original resolution; RGB unchanged'
    record['canonical_master']['sha256'] = digest(brand / 'shou-mascot-source.png')
    record['page_mascot']['sha256'] = digest(brand / 'shou-mascot.png')
    record['preparation']['script'] = 'scripts/prepare-brand-artwork.py; scripts/artwork_alpha.py'
    (brand / 'generation.json').write_text(json.dumps(record, indent=2) + '\n')
    print('Prepared brand master and transparent symbol with a smooth antialiased silhouette; RGB detail preserved.')


if __name__ == '__main__':
    main()
