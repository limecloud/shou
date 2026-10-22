#!/usr/bin/env python3
"""Check Windows UI catalog references without requiring a Windows desktop."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
WINDOWS = ROOT / "apps/windows"


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        assert key not in result, f"Duplicate catalog source: {key!r}"
        result[key] = value
    return result


def catalog_key(source):
    return "t" + hashlib.sha256(source.encode("utf-8")).hexdigest()[:16]


def placeholders(value):
    # CompositeFormat syntax is additionally parsed by the .NET process checks.
    return Counter(re.findall(r"(?<!\{)\{\d+(?:,-?\d+)?(?::[^{}]+)?\}(?!\})", value))


def main():
    catalog = json.loads((WINDOWS / "Shou.Windows.Services/Resources/UiStrings.json").read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    assert isinstance(catalog, dict) and catalog, "Missing Windows interface catalog"
    by_key = {catalog_key(source): source for source in catalog}
    assert len(by_key) == len(catalog), "UI key collision"
    for source, english in catalog.items():
        assert isinstance(english, str) and english, f"Empty translation: {source!r}"
        assert not re.search(r"[\u4e00-\u9fff]", english), f"Untranslated English text: {source!r}"
        assert placeholders(source) == placeholders(english), f"Changed format parameters: {source!r}"
    shared = ROOT / "packages/shou-core/Sources/Resources/zh-Hans.lproj/Localizable.strings"
    shared_sources = {json.loads(match[1]) for match in re.finditer(r'^("(?:[^"\\]|\\.)*") = ', shared.read_text(encoding="utf-8"), re.M)}
    sources = set()
    csharp_count = xaml_count = 0
    literal_call = re.compile(r'(?<![\w.])(?:UiText\.)?[TF]\(\s*("(?:[^"\\]|\\.)*")')
    for project in ("Shou.Windows", "Shou.Windows.Services"):
        for path in sorted((WINDOWS / project).glob("*.cs")):
            text = path.read_text(encoding="utf-8")
            for match in literal_call.finditer(text):
                source = json.loads(match[1])
                assert source in catalog or source in shared_sources, f"Missing C# source at {path.relative_to(ROOT)}:{text.count(chr(10), 0, match.start()) + 1}: {source!r}"
                sources.add(source)
                csharp_count += 1
        for path in sorted((WINDOWS / project).glob("*.xaml")):
            tree = ET.parse(path)
            for element in tree.iter():
                for value in [*element.attrib.values(), element.text or ""]:
                    assert not re.search(r"[\u4e00-\u9fff]", value), f"Hardcoded XAML text: {path.relative_to(ROOT)}: {value!r}"
                    for key in re.findall(r"\{local:Text (t[0-9a-f]{16})\}", value):
                        assert key in by_key, f"Missing XAML key in {path.relative_to(ROOT)}: {key}"
                        sources.add(by_key[key])
                        xaml_count += 1
    assert not set(catalog) - sources, f"Unused catalog entries: {sorted(set(catalog) - sources)!r}"
    print(f"Windows localization passed: {len(catalog)} messages, {csharp_count} C# references, {xaml_count} XAML references, zh-CN/en; format parameters preserved.")


if __name__ == "__main__":
    main()
