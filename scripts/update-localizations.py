#!/usr/bin/env python3
"""Generate SwiftPM-compatible native resources from the shared String Catalog."""
from pathlib import Path
import argparse
import json
import re

parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
catalog = json.loads((root / 'packages/shou-core/Localizable.xcstrings').read_text(encoding='utf-8'))
errors = []
used = set()
for source in (root / 'apps/macos/Sources').rglob('*.swift'):
    used.update(re.findall(r'\bt\("((?:[^"\\]|\\.)*)"\)', source.read_text(encoding='utf-8')))
for template in json.loads((root / 'packages/shou-core/Sources/Resources/builtin-rules.json').read_text(encoding='utf-8')):
    used.update((template['name'], template['rebuildNote'], template['limitation']))
for location in json.loads((root / 'packages/shou-core/Sources/Resources/known-locations.json').read_text(encoding='utf-8')):
    used.add(location['title'])
for key in sorted(used - set(catalog['strings'])):
    errors.append('Missing catalog key: ' + key)
for language in ('en', 'zh-Hans'):
    lines = ['// Generated from Localizable.xcstrings by scripts/update-localizations.py.']
    for key, entry in sorted(catalog['strings'].items()):
        value = entry['localizations'][language]['stringUnit']['value']
        lines.append(f'{json.dumps(key, ensure_ascii=False)} = {json.dumps(value, ensure_ascii=False)};')
    expected = '\n'.join(lines) + '\n'
    path = root / f'packages/shou-core/Sources/Resources/{language}.lproj/Localizable.strings'
    if args.check:
        if not path.exists() or path.read_text(encoding='utf-8') != expected:
            errors.append(str(path.relative_to(root)))
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(expected, encoding='utf-8', newline='\n')
if errors:
    raise SystemExit('Stale localization resources: ' + ', '.join(errors))
print(f'Localization resources {"verified" if args.check else "updated"}: {len(catalog["strings"])} keys, 2 languages.')
