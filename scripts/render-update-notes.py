#!/usr/bin/env python3
"""Render repository release notes as safe, offline HTML for the signed Sparkle feed."""
import argparse
import html
from pathlib import Path


def render(markdown):
    if not markdown.strip() or len(markdown.encode('utf-8')) > 128 * 1024:
        raise ValueError('Release notes must contain between 1 and 131072 UTF-8 bytes.')
    blocks, paragraph, bullets = [], [], []

    def flush():
        if paragraph:
            blocks.append('<p>' + ' '.join(paragraph) + '</p>')
            paragraph.clear()
        if bullets:
            blocks.append('<ul>' + ''.join('<li>' + item + '</li>' for item in bullets) + '</ul>')
            bullets.clear()

    for line in markdown.splitlines():
        line = line.strip()
        if not line:
            flush()
        elif line.startswith('- '):
            if paragraph:
                flush()
            bullets.append(html.escape(line[2:]))
        elif line.startswith('#') and ' ' in line:
            flush()
            blocks.append('<h3>' + html.escape(line.split(' ', 1)[1]) + '</h3>')
        else:
            if bullets:
                flush()
            paragraph.append(html.escape(line))
    flush()
    # A fragment is embedded inside the signed feed; no remote images, JS or CSS.
    return '<div style="font: -apple-system-body; color-scheme: light dark">\n' + '\n'.join(blocks) + '\n</div>\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    args.destination.write_text(render(args.source.read_text(encoding='utf-8')), encoding='utf-8')


if __name__ == '__main__':
    main()
