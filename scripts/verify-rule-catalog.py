#!/usr/bin/env python3
"""Validate Shou rule resources and negative scope fixtures without network access."""
import argparse
import copy
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "packages/shou-core/Sources/Resources"

def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_pattern(pattern):
    require(isinstance(pattern, str) and 0 < len(pattern.encode()) <= 2048, "Invalid path pattern size")
    require(not re.search(r"[\\:$~{}\[\]`\x00-\x1f\x7f]", pattern), "Unsafe path pattern characters")
    parts = pattern.split("/")
    require(all(part and part not in (".", "..") and ("**" not in part or part == "**") for part in parts), "Unsafe path traversal")
    require(any(re.search(r"[^*?]", part) for part in parts), "A target must have a literal component")


def validate(rules, locations):
    require(len(rules) == len({rule["id"] for rule in rules}), "Duplicate rule identifiers")
    require(len(locations) == len({(value["platform"], value["id"]) for value in locations}), "Duplicate scoped location")
    require(len(locations) == len({(value["platform"], value["relativePath"]) for value in locations}), "Duplicate scoped path")
    ids = {rule["id"] for rule in rules}
    location_ids = {(value["platform"], value["id"]) for value in locations}
    for location in locations:
        validate_pattern(location["relativePath"])
        require("*" not in location["relativePath"] and "?" not in location["relativePath"], "Location roots must be exact")
        require(location["relativePath"] not in ("Library", "Library/Application Support", "Library/Containers"), "Overbroad scan root")
        require(any(rule["location"] == location["id"] for rule in rules), "Location has no rules")
    for rule in rules:
        platforms = rule.get("platforms", ["macos", "windows"] if rule["location"] == "projects" else ["macos"])
        require(platforms and len(platforms) == len(set(platforms)) and set(platforms) <= {"macos", "windows"}, "Invalid rule platforms")
        require(rule["patterns"] and len(rule["patterns"]) == len(set(rule["patterns"])), "Empty or duplicated rule patterns")
        for pattern in rule["patterns"]:
            validate_pattern(pattern)
        if rule["location"] != "projects":
            require(all((platform, rule["location"]) in location_ids for platform in platforms), "Orphaned platform location")
        bundle_ids = rule.get("applicationBundleIdentifiers", [])
        require(len(bundle_ids) == len(set(bundle_ids)), "Duplicate activity identifiers")
        require(all(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9.-]+", value) for value in bundle_ids), "Invalid activity identity")

def self_test(rules, locations):
    cases=[]
    duplicate=copy.deepcopy(rules); duplicate.append(duplicate[0]); cases.append((duplicate,locations))
    for pattern in ("../outside", "**", "C:/Windows", "cache/../../home", "cache\\escape"):
        invalid=copy.deepcopy(rules); invalid[0]["patterns"]=[pattern]; cases.append((invalid,locations))
    invalid=copy.deepcopy(rules); invalid[0]["platforms"]=["unknown"]; cases.append((invalid,locations))
    invalid=copy.deepcopy(locations); invalid[0]["relativePath"]="Library"; cases.append((rules,invalid))
    for invalid_rules, invalid_locations in cases:
        try:
            validate(invalid_rules,invalid_locations)
        except (ValueError,KeyError):
            continue
        raise ValueError("Unsafe catalog fixture was accepted")
    return len(cases)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test",action="store_true")
    args=parser.parse_args()
    rules=json.loads((RESOURCES / "builtin-rules.json").read_text())
    locations=json.loads((RESOURCES / "known-locations.json").read_text())
    validate(rules,locations)
    rejected=self_test(rules,locations) if args.self_test else 0
    print(f"Rule catalog verified: {len(rules)} rules, {sum(len(rule['patterns']) for rule in rules)} patterns, {len(locations)} locations; {rejected} rejected negative fixtures. Native acceptance is separate.")


if __name__ == "__main__":
    main()
