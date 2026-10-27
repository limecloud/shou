#!/usr/bin/env python3
"""Generate Windows resources and shared native design constants from canonical sources."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import struct
import xml.etree.ElementTree as ET
import design_tokens
import workspace_artwork

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'apps/windows/Generated'
FORMAT = re.compile(r'%(?:(\d+)\$)?(@|lld)')


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()


def template(text):
    position = 0
    arguments = {}

    def replace(match):
        nonlocal position
        index = int(match[1]) - 1 if match[1] else position
        if index < 0:
            raise ValueError('Format argument positions must start at one')
        position += 1
        if index in arguments and arguments[index] != match[2]:
            raise ValueError('Inconsistent format argument types')
        arguments[index] = match[2]
        return '{' + str(index) + '}'

    return FORMAT.sub(replace, text.replace('{', '{{').replace('}', '}}')), arguments


def resources():
    inputs = [
        'packages/shou-core/Localizable.xcstrings',
        'packages/shou-core/Sources/Resources/builtin-rules.json',
        'packages/shou-core/Sources/Resources/known-locations.json',
        'packages/shou-contracts/rule.schema.json',
        'assets/design/tokens.json',
        'scripts/generate-windows-resources.py',
        'packages/shou-core/Sources/Resources/project-locations.json',
        'scripts/design_tokens.py',
        'assets/brand/Shou.iconset/icon_16x16.png',
        'assets/brand/Shou.iconset/icon_32x32.png',
        'assets/brand/Shou.iconset/icon_128x128.png',
        'assets/brand/Shou.iconset/icon_256x256.png',
        'assets/brand/shou-mascot.png',
        'assets/brand/shou-icon-1024.png',
        'assets/design/radix-colors.json',
    ]
    strings = json.loads((ROOT / inputs[0]).read_text(encoding='utf-8'))['strings']
    for source in (ROOT / 'apps/windows/src').rglob('*.cs'):
        for key in re.findall(r'\btext\.Get\("([^"\\]+)"\)', source.read_text(encoding='utf-8')):
            if key not in strings:
                raise ValueError(f'{source.relative_to(ROOT)}: missing catalog key {key!r}')
    illustrations = workspace_artwork.verified()
    inputs += ['assets/design/illustrations/manifest.json'] + ['assets/design/illustrations/' + name for name in illustrations]
    outputs = {'Illustrations/' + name: data for name, data in illustrations.items()}
    outputs['Illustrations/brand-mascot.png'] = (ROOT / 'assets/brand/shou-mascot.png').read_bytes()
    outputs['Illustrations/brand-icon.png'] = (ROOT / 'assets/brand/shou-icon-1024.png').read_bytes()
    for source_locale, windows_locale in [('en', 'en-US'), ('zh-Hans', 'zh-CN')]:
        entries = {}
        tree = ET.Element('root')
        for key, record in sorted(strings.items()):
            source = record['localizations']['en']['stringUnit']['value']
            text = record['localizations'][source_locale]['stringUnit']['value']
            value, arguments = template(text)
            if arguments != template(source)[1]:
                raise ValueError(f'{source_locale}: format arguments differ for {key!r}')
            identifier = 's' + hashlib.sha256(key.encode()).hexdigest()[:24]
            entries[key] = {'resource_id': identifier, 'text': text, 'format': value}
            data = ET.SubElement(tree, 'data', {'name': identifier, 'xml:space': 'preserve'})
            ET.SubElement(data, 'value').text = value
        ET.indent(tree, space='  ')
        outputs[f'Strings/{windows_locale}/Resources.resw'] = ET.tostring(tree, encoding='utf-8', xml_declaration=True) + b'\n'
        outputs[f'Text.{windows_locale}.json'] = json_bytes(entries)

    locations = json.loads((ROOT / inputs[2]).read_text(encoding='utf-8'))
    locations = [entry for entry in locations if entry.get('platform') == 'windows']
    location_ids = {entry['id'] for entry in locations} | {'projects'}
    rules = json.loads((ROOT / inputs[1]).read_text(encoding='utf-8'))
    rules = [rule for rule in rules if rule['location'] in location_ids and 'windows' in rule.get('platforms', ['macos', 'windows'] if rule['location'] == 'projects' else ['macos'])]
    outputs['known-locations.json'] = json_bytes(locations)
    outputs['builtin-rules.json'] = json_bytes(rules)
    projects = json.loads((ROOT / inputs[6]).read_text(encoding='utf-8'))
    if not 1 <= len(projects) <= 64 or len(set(projects)) != len(projects):
        raise ValueError('Invalid project location hints')
    for path in projects:
        if not isinstance(path, str) or any(part in ('', '.', '..') for part in path.split('/')) or any(char in path for char in '\\:*?$~{}[]`') or any(ord(char) < 32 for char in path):
            raise ValueError('Project hints must be exact relative paths')
    outputs['project-locations.json'] = json_bytes(projects)
    outputs['rule.schema.json'] = (ROOT / inputs[3]).read_bytes()

    developer_catalog = 'packages/shou-core/Sources/Resources/developer-tools.json'
    inputs.append(developer_catalog)
    outputs['developer-tools.json'] = (ROOT / developer_catalog).read_bytes()

    outputs['Design.xaml'] = design_tokens.xaml(design_tokens.load())
    # ICO embeds the canonical PNG bytes, preserving the macOS brand artwork.
    icons = [(size, (ROOT / f'assets/brand/Shou.iconset/icon_{size}x{size}.png').read_bytes()) for size in (16, 32, 128, 256)]
    offset = 6 + 16 * len(icons)
    directory = bytearray(struct.pack('<HHH', 0, 1, len(icons)))
    for size, data in icons:
        directory.extend(struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(data), offset))
        offset += len(data)
    outputs['Shou.ico'] = bytes(directory) + b''.join(data for _, data in icons)
    outputs['MANIFEST.json'] = json_bytes({
        'generator_version': 1,
        'sources': {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in inputs},
        'outputs': {name: hashlib.sha256(data).hexdigest() for name, data in outputs.items()},
        'locales': ['en-US', 'zh-CN'],
        'rule_count': len(rules),
        'location_count': len(locations),
    })
    return outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    options = parser.parse_args()
    outputs = resources()
    changed = []
    existing = {path.relative_to(OUTPUT).as_posix() for path in OUTPUT.rglob('*') if path.is_file()} if OUTPUT.exists() else set()
    unexpected = existing - outputs.keys()
    if unexpected:
        raise SystemExit('Unexpected generated files: ' + ', '.join(sorted(unexpected)))
    files = {OUTPUT / name: data for name, data in outputs.items()}
    files[design_tokens.SWIFT_OUTPUT] = design_tokens.swift(design_tokens.load())
    for path, data in files.items():
        if path.exists() and path.read_bytes() == data:
            continue
        changed.append(str(path.relative_to(ROOT)))
        if not options.check:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    if options.check and changed:
        raise SystemExit('Native resources need regeneration: ' + ', '.join(changed))
    action = 'verified' if options.check else 'generated'
    print(f'Windows resources {action}: {len(outputs)} files, 2 locales; Swift design constants {action}.')


if __name__ == '__main__':
    main()
