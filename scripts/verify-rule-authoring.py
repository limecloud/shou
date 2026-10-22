#!/usr/bin/env python3
"""Verify desktop rule authoring against the real engine and generated files."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile


def main():
    engine = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/shou").resolve(strict=True)
    specification = importlib.util.spec_from_file_location("desktop_fixture_protocol", Path(__file__).with_name("verify-desktop-bridge.py"))
    protocol = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(protocol)
    requests = 0
    with tempfile.TemporaryDirectory(prefix="shou-rule-authoring-", dir=Path.home() if os.name == "nt" else None) as temporary:
        root = Path(temporary).resolve()
        workspace = root / "中文 authoring & literal"
        target = workspace / "project" / "output-cache"
        target.mkdir(parents=True)
        (target / "output.bin").write_bytes(b"generated authoring fixture" * 64)
        keep = target / "keep" / "sentinel.txt"
        keep.parent.mkdir()
        keep.write_text("must be retained", encoding="utf-8")
        (target.parent / "package.json").write_text("{}", encoding="utf-8")
        for number in range(205):
            directory = workspace / "generated" / f"row-{number:03}"
            directory.mkdir(parents=True)
            (directory / "output.bin").write_bytes(b"generated bounded-preview fixture")
        protocol.set_fixture_owner(workspace)
        before = {str(path.relative_to(workspace)): path.read_bytes() for path in workspace.rglob("*") if path.is_file()}
        environment = dict(os.environ, SHOU_DATA_DIR=str(root / "records"))

        def call(operation, values=None, error=None):
            nonlocal requests
            result, confirmed = protocol.request(engine, environment, operation, values)
            requests += 1
            assert not confirmed, (operation, result)
            if error:
                assert not result["ok"] and result["error"]["code"] == error, (operation, result)
                return result
            assert result["ok"], (operation, result)
            return result["data"]

        capabilities = call("capabilities")
        assert capabilities["features"]["rule_authoring"] is True
        registered = call("workspace.add", dict(path=str(workspace), root_ref="authoring-fixture"))
        initial = call("configuration")["configuration"]
        fields = dict(name="Generated authoring fixture", relative_patterns=["**/output-cache"], project_markers=["package.json"],
                      exclusions=["project/output-cache/keep/**"], max_depth=8, minimum_allocated_bytes=0,
                      minimum_age_days=None, rebuild_note="Only generated fixtures; rebuild with the fixture generator.",
                      limitations=["Retain the sentinel and user data."], high_risk=False)
        inputs = dict(workspace_id=registered["id"], rule_id="personal.authoring-fixture", mode="patterns", fields=fields)
        drafted = call("rules.draft", inputs)
        rule = drafted["rule"]
        assert rule["platforms"] == [capabilities["platform"]]
        assert rule["scope"]["follow_symlinks"] is False and rule["scope"]["cross_filesystems"] is False
        assert call("configuration")["configuration"] == initial
        call("rules.draft", dict(inputs, fields=dict(fields, shell="unavailable")), error="invalid_rule")
        call("rules.draft", dict(inputs, fields=dict(fields, max_depth=True)), error="invalid_rule")
        call("rules.draft", dict(inputs, fields=dict(fields, relative_patterns=["../outside"])), error="invalid_rule")
        call("rules.draft", dict(inputs, rule_id="shou.builtin.forged"), error="version_conflict")
        print("PASS shared closed-contract authoring, field types, namespace and no implicit import", flush=True)

        exact = call("rules.draft", dict(inputs, mode="folder", folder=str(target)))
        assert exact["rule"]["match"]["relative_patterns"] == ["project/output-cache"]
        relative = call("rules.draft", dict(inputs, mode="folder", folder="project/output-cache"))
        assert relative["rule"] == exact["rule"]
        for invalid in [str(workspace), str(root / "outside"), "../outside", "project/output-cache/*"]:
            result, confirmed = protocol.request(engine, environment, "rules.draft", dict(inputs, mode="folder", folder=invalid))
            requests += 1
            assert not confirmed and not result["ok"], result
        print("PASS exact-folder containment, relative paths and no wildcard broadening", flush=True)

        preview = call("rules.draft.preview", dict(workspace_id=registered["id"], json=drafted["json"]))
        assert preview["status"] == "complete" and preview["blocked_count"] == 1
        assert preview["rows"][0]["status"] == "blocked" and "excluded_descendant" in preview["rows"][0]["reasons"]
        assert call("configuration")["configuration"] == initial
        call("plan", dict(scan_id=preview["scan_id"], candidate_ids=["not-executable"]), error="partial_result")
        large_fields = dict(fields, relative_patterns=["generated/row-*"], project_markers=[], exclusions=[])
        large = call("rules.draft", dict(inputs, fields=large_fields))
        bounded = call("rules.draft.preview", dict(workspace_id=registered["id"], json=large["json"]))
        assert bounded["total_count"] == 205 and len(bounded["rows"]) == 200 and bounded["matched_count"] == 205
        partial = call("rules.draft.preview", dict(workspace_id=registered["id"], json=large["json"], budget=dict(max_entries=1)))
        assert partial["status"] == "partial"
        assert call("configuration")["configuration"] == initial
        print("PASS unimported read-only previews, protection reasons, 200-row display budget and partial coverage", flush=True)

        validate_input = dict(workspace_id=registered["id"], json=drafted["json"])
        validated = call("rules.validate", validate_input)
        wrong_root = copy.deepcopy(rule)
        wrong_root["scope"]["root_ref"] = "unregistered-root"
        call("rules.validate", dict(validate_input, json=json.dumps(wrong_root)), error="invalid_rule")
        invalid_schema = dict(rule, shell="unavailable")
        failure = call("rules.validate", dict(validate_input, json=json.dumps(invalid_schema)), error="invalid_rule")
        assert "issues" in failure["error"]["details"]
        old = call("rules.import", dict(validate_input, require_new_version=True, configuration_revision=validated["configuration_revision"]))
        imported = call("configuration")["configuration"]
        assert imported["bindings"] == [] and len(imported["rules"]) == 1
        call("rules.import", dict(validate_input, require_new_version="true"), error="invalid_argument")
        call("rules.import", dict(validate_input, require_new_version=True), error="version_conflict")
        print("PASS explicit disabled import, schema issue details, workspace validation and immutable versions", flush=True)

        binding = call("rules.set", dict(workspace_id=registered["id"], rule_id=rule["id"], version=rule["version"], enabled=True))
        revised = call("rules.revision", dict(rule_id=rule["id"], version=rule["version"]))
        assert revised["rule"]["version"] == "0.1.1" and revised["rule"]["id"] == rule["id"]
        revision_input = dict(original_rule_id=rule["id"], json=revised["json"])
        revision_validation = call("rules.validate", revision_input)
        changed_id = dict(revised["rule"], id="personal.foreign-id")
        call("rules.validate", dict(revision_input, json=json.dumps(changed_id)), error="invalid_rule")
        call("rules.validate", dict(revision_input, json=drafted["json"]), error="version_conflict")
        call("rules.import", dict(revision_input, require_new_version=False), error="invalid_argument")
        call("exclusions.set", dict(pattern="globally-retained/**", remove=False))
        current = call("configuration")["configuration"]
        call("rules.import", dict(revision_input, require_new_version=True, configuration_revision=revision_validation["configuration_revision"]), error="plan_stale")
        assert call("configuration")["configuration"] == current
        fresh = call("rules.validate", revision_input)
        saved = call("rules.import", dict(revision_input, require_new_version=True, configuration_revision=fresh["configuration_revision"]))
        final = call("configuration")["configuration"]
        assert final["bindings"] == [binding] and binding["version"] == "0.1.0"
        assert final["rules"][0] == old and final["rules"][1] == saved
        assert len(final["rules"]) == 2
        print("PASS same-ID revisions, stale-save refusal under the lock and retained enabled old-version binding", flush=True)

        # Save actual enabled bindings in the core, then scan by stored ID.
        call("rules.set", dict(workspace_id=registered["id"], rule_id="shou.builtin.rust-target", enabled=False))
        reviewed = call("configuration")["configuration"]
        saved_selection = call("presets.save", dict(name="Generated enabled selection", workspace_id=registered["id"], configuration_revision=reviewed["revision"]))
        assert rule["id"] in saved_selection["rule_ids"] and "shou.builtin.rust-target" not in saved_selection["rule_ids"]
        saved_configuration = call("configuration")["configuration"]
        assert saved_configuration["bindings"] == reviewed["bindings"] and saved_configuration["presets"] == [saved_selection]
        call("presets.save", dict(name="Stale", workspace_id=registered["id"], configuration_revision=reviewed["revision"]), error="plan_stale")
        call("presets.save", dict(name="Forged", workspace_id=registered["id"], configuration_revision=saved_configuration["revision"], rule_ids=["other.rule"]), error="invalid_argument")
        fresh_scan = call("presets.scan", dict(preset_id=saved_selection["id"]))
        assert fresh_scan["workspace_id"] == registered["id"] and fresh_scan["scan_id"] != preview["scan_id"]
        call("presets.scan", dict(preset_id=saved_selection["id"], workspace_id="foreign"), error="invalid_argument")
        call("presets.scan", dict(preset_id="unknown"), error="invalid_argument")
        call("rules.set", dict(workspace_id=registered["id"], rule_id=rule["id"], version=rule["version"], enabled=False))
        disabled = call("configuration")["configuration"]
        call("presets.scan", dict(preset_id=saved_selection["id"]), error="invalid_argument")
        assert call("configuration")["configuration"] == disabled
        print("PASS saved enabled selections, stale-save refusal, fresh scoped scans and disabled-rule refusal without implicit enablement", flush=True)

        # Scoped protection must never silently become a global exclusion.
        other_workspace = root / "other-workspace"
        other_target = other_workspace / "project" / "output-cache"
        other_target.mkdir(parents=True)
        (other_target / "sentinel.bin").write_bytes(b"other generated fixture")
        (other_target.parent / "package.json").write_text("{}", encoding="utf-8")
        protocol.set_fixture_owner(other_workspace)
        other = call("workspace.add", dict(path=str(other_workspace), root_ref="other-authoring-fixture"))
        protection_rule = copy.deepcopy(rule)
        protection_rule["id"] = "personal.exclusion-preview"
        protection_rule["exclude"]["relative_patterns"] = []
        protection_input = dict(workspace_id=registered["id"], json=json.dumps(protection_rule))
        assert call("rules.draft.preview", protection_input)["matched_count"] == 1
        call("exclusions.set", dict(workspace_id=registered["id"], project="project", pattern="**", remove=False))
        scoped = call("configuration")["configuration"]
        assert next(item for item in scoped["workspaces"] if item["id"] == registered["id"])["exclusions"] == ["project/**"]
        assert next(item for item in scoped["workspaces"] if item["id"] == other["id"])["exclusions"] == []
        assert scoped["global_exclusions"] == ["globally-retained/**"]
        protected = call("rules.draft.preview", protection_input)
        assert protected["blocked_count"] == 1 and protected["matched_count"] == 0
        other_rule = copy.deepcopy(protection_rule)
        other_rule["scope"]["root_ref"] = "other-authoring-fixture"
        assert call("rules.draft.preview", dict(workspace_id=other["id"], json=json.dumps(other_rule)))["matched_count"] == 1
        for invalid in [dict(workspace_id=None), dict(workspace_id=""), dict(workspace_id=42), dict(workspace_id="missing"),
                        dict(project="project"), dict(workspace=registered["id"]),
                        dict(workspace_id=registered["id"], project="../outside"),
                        dict(workspace_id=registered["id"], project="project*"),
                        dict(workspace_id=registered["id"], project=None)]:
            call("exclusions.set", dict(pattern="keep/**", remove=False, **invalid), error="invalid_rule" if invalid.get("project") == "../outside" else "invalid_argument")
        assert call("configuration")["configuration"] == scoped
        call("exclusions.set", dict(workspace_id=registered["id"], pattern="project/**", remove=True))
        assert call("rules.draft.preview", protection_input)["matched_count"] == 1
        call("exclusions.set", dict(workspace_id=other["id"], pattern="retained/**", remove=False))
        unscoped = call("configuration")["configuration"]
        assert next(item for item in unscoped["workspaces"] if item["id"] == registered["id"])["exclusions"] == []
        assert next(item for item in unscoped["workspaces"] if item["id"] == other["id"])["exclusions"] == ["retained/**"]
        assert unscoped["global_exclusions"] == scoped["global_exclusions"]
        assert (other_target / "sentinel.bin").read_bytes() == b"other generated fixture"
        print("PASS global/workspace/project exclusion isolation, protected ancestors, scope typo/type refusal and exact removal", flush=True)

        after = {str(path.relative_to(workspace)): path.read_bytes() for path in workspace.rglob("*") if path.is_file()}
        assert before == after and call("history") == []
    print(f"{requests} real rule-authoring requests passed; no cleanup confirmation accepted and all generated file contents retained.")


if __name__ == "__main__":
    main()
