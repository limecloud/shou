#!/usr/bin/env python3
"""Check documentation links, language navigation, identifiers, and fenced JSON."""
from pathlib import Path
from urllib.parse import unquote, urlsplit
import json
import os
import re

root = Path(__file__).resolve().parents[1]
excluded = {'.build', '.git', 'dist', '.shou-local', 'output'}
documents = []
for directory, children, files in os.walk(root):
    children[:] = [name for name in children if name not in excluded]
    documents.extend(Path(directory) / name for name in files if name.endswith('.md'))
documents.sort()
errors = []
links = 0
for path in documents:
    content = path.read_text(encoding='utf-8')
    fence = None
    buffer = []
    for number, line in enumerate(content.splitlines(), 1):
        marker = re.match(r'^\s*(`{3,}|~{3,})(.*)$', line)
        if marker:
            token, suffix = marker.groups()
            if fence is None:
                fence = (token, suffix.strip(), number)
                buffer = []
            elif token[0] == fence[0][0] and len(token) >= len(fence[0]) and not suffix.strip():
                if fence[1] == 'json':
                    try:
                        json.loads('\n'.join(buffer))
                    except ValueError as error:
                        errors.append(f'{path.relative_to(root)}:{fence[2]}: {error}')
                fence = None
            continue
        if fence:
            buffer.append(line)
            continue
        for target in re.findall(r'\[[^\]\n]+\]\(([^)\n]+)\)', line):
            parsed = urlsplit(target.strip('<>').split(' ', 1)[0])
            if parsed.scheme or parsed.netloc or not parsed.path:
                continue
            links += 1
            if not (path.parent / unquote(parsed.path)).exists():
                errors.append(f'{path.relative_to(root)}:{number}: missing {target}')
    if fence:
        errors.append(f'{path.relative_to(root)}: unclosed code fence')
    if not content.endswith('\n'):
        errors.append(f'{path.relative_to(root)}: missing final newline')

readmes = [root / 'README.md'] + [root / f'README.{locale}.md' for locale in ['zh-CN', 'zh-TW', 'ja', 'ko', 'de', 'fr', 'es', 'pt-BR', 'ru', 'uk']]
for current in readmes:
    navigation = re.findall(r'\[([^\]]+)\]\((README(?:\.[A-Za-z-]+)?\.md)\)', current.read_text(encoding='utf-8'))
    if not navigation or navigation[0] != ('English', 'README.md'):
        errors.append(f'{current.name}: language navigation must start with English')
    for target in readmes:
        if current != target and f']({target.name})' not in current.read_text(encoding='utf-8'):
            errors.append(f'{current.name}: missing language link to {target.name}')

for english in (root / 'docs').rglob('*.md'):
    relative = english.relative_to(root / 'docs')
    if 'zh-CN' in relative.parts:
        continue
    chinese = root / 'docs/zh-CN' / relative
    if not chinese.exists():
        errors.append(f'Missing Chinese edition: {relative}')
        continue
    for prefix in ('F', 'US', 'UC', 'AC', 'DEC'):
        pattern = rf'\b{prefix}\d{{2}}\b'
        if set(re.findall(pattern, english.read_text(encoding='utf-8'))) != set(re.findall(pattern, chinese.read_text(encoding='utf-8'))):
            errors.append(f'{relative}: inconsistent {prefix} identifiers')

if errors:
    raise SystemExit('\n'.join(errors))
print(f'Documentation verified: {len(documents)} Markdown files, {links} local links, {len(readmes)} README languages.')
