#!/usr/bin/env python3
"""Verify the reviewed Mole inventory and declarative path mapping without network access."""

import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "packages/shou-core/Sources/Resources"
MANIFEST = ROOT / "docs/engineering/mole-coverage.json"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_pattern(pattern):
    require(isinstance(pattern, str) and 0 < len(pattern.encode()) <= 2048, "Invalid path pattern size")
    require(not re.search(r"[\\:$~{}\[\]`\x00-\x1f\x7f]", pattern), "Unsafe path pattern characters")
    parts = pattern.split("/")
    require(all(part and part not in (".", "..") and ("**" not in part or part == "**") for part in parts), "Unsafe path traversal")
    require(any(re.search(r"[^*?]", part) for part in parts), "A target must have a literal component")


def validate(manifest, rules, locations):
    require(manifest["schemaVersion"] == 1, "Unsupported coverage manifest")
    upstream = manifest["upstream"]
    require(re.fullmatch(r"[0-9a-f]{40}", upstream["commit"]), "Source commit must be immutable")
    require(upstream["license"] == "GPL-3.0", "Upstream license attribution is missing")
    require(upstream["testedAppCount"] == 844, "The reviewed upstream inventory count changed")
    require(re.fullmatch(r"[0-9a-f]{64}", upstream["testedAppsHTMLSHA256"]), "Missing source inventory digest")
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
    inventory = manifest["inventory"]
    require(len(inventory) == upstream["testedAppCount"], "Inventory count does not match upstream snapshot")
    require(len({app["sourceId"] for app in inventory}) == len(inventory), "Duplicate inventory entry")
    require(len({app["sourceURL"] for app in inventory}) == len(inventory), "Duplicate guide URL")
    for app in inventory:
        require(app["sourceURL"].startswith("https://mole.fit/zh/tested-apps/"), "Invalid inventory source")
        require(app["name"] and app["searchHints"] and app["reason"], "Missing inventory provenance or reason")
        require(set(app["declaredRuleIds"]) <= ids, "Inventory references an unknown rule")
        expected = "declared-cache-or-log-paths" if app["declaredRuleIds"] else "inventory-only"
        require(app["coverage"] == expected, "Misleading inventory coverage status")
        require(all(value in app["searchHints"] for value in app["bundleIdentifierHints"]), "Invented inventory identity")
        require(all(value.lower() != app["name"].lower() and not value.lower().endswith((".zip", ".dmg", ".pkg")) for value in app["bundleIdentifierHints"]), "Product names and download filenames are not bundle identities")
        require(app["bundleIdentifierHints"] or app.get("identityGap"), "Missing identity gap")
    imported = manifest["importedRuleSources"]
    imported_ids = [row["ruleId"] for row in imported]
    require(len(imported_ids) == len(set(imported_ids)), "Duplicate imported rule source")
    require(set(imported_ids) == {rule["id"] for rule in rules if rule.get("platforms") == ["macos"]}, "Imported declarations and source mapping diverged")
    source_files = {row["file"]: row for row in manifest["sourceFiles"]}
    for row in imported:
        require(row["sources"], "Imported rule has no reviewed source")
        for source in row["sources"]:
            require(source["file"] in source_files and source["line"] > 0, "Invalid imported source reference")
            expected = f"https://github.com/tw93/mole/blob/{upstream['commit']}/{source['file']}#L{source['line']}"
            require(source["sourceURL"] == expected, "Imported source URL is not pinned")
    statuses = {"declared-path", "narrower-declaration", "deferred-runtime-or-privileged", "retained-personal-or-sensitive", "deferred-dynamic-selector", "deferred-owner-or-state-review"}
    for row in manifest["pathReferences"]:
        require(row["file"] in source_files and row["line"] > 0 and row["path"], "Invalid source path reference")
        require(row["coverage"] in statuses and row["reason"], "Unexplained path coverage gap")
        require(set(row["declaredRuleIds"] + row["narrowerRuleIds"] + row["parentRuleIds"]) <= ids, "Path references unknown declarations")
        require((row["coverage"] == "declared-path") == bool(row["declaredRuleIds"]), "Inconsistent exact path mapping")
    require(len(manifest["behaviorGaps"]) >= 6 and all(value["reason"] for value in manifest["behaviorGaps"]), "Missing behavioral boundaries")


def validate_source(manifest, checkout):
    commit = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    require(commit == manifest["upstream"]["commit"], "Source checkout differs from reviewed commit")
    lines = {}
    for row in manifest["sourceFiles"]:
        data = (checkout / row["file"]).read_bytes()
        require(hashlib.sha256(data).hexdigest() == row["sha256"], "Reviewed source file drift: " + row["file"])
        lines[row["file"]] = data.decode().splitlines()
    for row in manifest["importedRuleSources"]:
        for source in row["sources"]:
            line = lines[source["file"]][source["line"] - 1]
            if "function" in source:
                require(line.startswith(source["function"] + "()"), "Source function mapping drift")


def self_test(manifest, rules, locations):
    validate(manifest, rules, locations)
    cases = []
    changed = copy.deepcopy(manifest)
    changed["inventory"].pop()
    cases.append((changed, rules, locations))
    changed = copy.deepcopy(manifest)
    changed["inventory"][0]["bundleIdentifierHints"].append("invented.identity")
    cases.append((changed, rules, locations))
    changed = copy.deepcopy(manifest)
    changed["importedRuleSources"][0]["sources"][0]["sourceURL"] = "https://github.com/tw93/mole/blob/main/example"
    cases.append((changed, rules, locations))
    changed = copy.deepcopy(rules)
    changed[-1]["patterns"] = ["../personal"]
    cases.append((manifest, changed, locations))
    changed = copy.deepcopy(rules)
    changed[-1]["platforms"] = ["windows"]
    cases.append((manifest, changed, locations))
    changed = copy.deepcopy(locations)
    changed[-1]["relativePath"] = "Library/Application Support"
    cases.append((manifest, rules, changed))
    for index, arguments in enumerate(cases):
        try:
            validate(*arguments)
        except ValueError:
            continue
        raise ValueError(f"Negative coverage fixture {index + 1} was accepted")
    return len(cases)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-checkout", type=Path)
    parser.add_argument("--tested-apps-html", type=Path)
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text())
    rules = json.loads((RESOURCES / "builtin-rules.json").read_text())
    locations = json.loads((RESOURCES / "known-locations.json").read_text())
    validate(manifest, rules, locations)
    if arguments.source_checkout:
        validate_source(manifest, arguments.source_checkout)
    if arguments.tested_apps_html:
        require(hashlib.sha256(arguments.tested_apps_html.read_bytes()).hexdigest() == manifest["upstream"]["testedAppsHTMLSHA256"], "Tested-app inventory HTML differs from reviewed snapshot")
    negative_count = self_test(manifest, rules, locations) if arguments.self_test else 0
    declared = sum(bool(app["declaredRuleIds"]) for app in manifest["inventory"])
    print(f"Mole coverage verified: {len(manifest['inventory'])} upstream tested apps; {declared} mapped to cache/log declarations; {len(manifest['inventory']) - declared} inventory-only gaps; {len(rules)} Shou rules, {sum(len(rule['patterns']) for rule in rules)} patterns, {len(locations)} locations; {negative_count} rejected negative fixtures. This is not native application-test evidence.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Mole coverage verification failed: {error}")
