#!/usr/bin/env python3
"""Verify portable Skill install/export using only exclusively generated paths."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
request = runpy.run_path(str(ROOT / "scripts/verify-desktop-bridge.py"))["request"]


def snapshot(directory):
    return {path.relative_to(directory).as_posix(): path.read_bytes()
            for path in directory.rglob("*") if path.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", required=True, type=Path)
    args = parser.parse_args()
    engine = args.engine.resolve(strict=True)
    checks = 0
    with tempfile.TemporaryDirectory(prefix="shou-agent-setup-") as directory:
        base = Path(directory).resolve()
        blocked = base / "blocked-record-store"
        blocked.write_text("keep; setup does not open cleanup records")
        environment = dict(os.environ, SHOU_DATA_DIR=str(blocked))

        def bridge(operation, values=None, *, expected=True, confirmation="cancel", before=None):
            nonlocal checks
            value, prompted = request(engine, environment, operation, values, confirmation, before)
            assert value["ok"] == expected, (operation, value)
            checks += 1
            return (value["data"] if expected else value["error"]), prompted

        def cli(*arguments, expected=True):
            nonlocal checks
            result = subprocess.run([str(engine), *arguments, "--json"], env=environment,
                                    stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
            value = json.loads(result.stdout)
            assert value["ok"] == expected and (result.returncode == 0) == expected, value
            checks += 1
            return value["data"] if expected else value["error"]

        setup, prompted = bridge("agent.setup")
        assert not prompted and {client["id"] for client in setup["clients"]} == {"codex", "claude-code"}
        skill = setup["skill"]
        assert skill["name"] == "shou-rule-authoring"
        assert Path(skill["entrypoint"]) == Path(skill["directory"]) / "SKILL.md"
        shipped = {path: (Path(skill["directory"]) / path).read_bytes()
                   for path in ("SKILL.md", "references/questionnaire.md", "agents/openai.yaml")}
        assert skill["instructions"].encode() == shipped["SKILL.md"]
        for client in setup["clients"]:
            assert Path(client["directory"]).is_absolute()
        error, _ = bridge("agent.setup", {"directory": str(base)}, expected=False)
        assert error["code"] == "invalid_argument"
        for values in ({}, {"agent": "workbuddy"}, {"agent": "codex", "directory": 42},
                       {"agent": "codex", "directory": str(base), "yes": True}):
            bridge("skills.preview", values, expected=False)
        for operation, values in (
            ("skills.install", {"agent": "codex", "directory": str(base), "review_digest": "foreign", "yes": True}),
            ("skills.export", {}), ("skills.export", {"output": 42}),
            ("skills.export", {"output": str(base / "unreviewed.zip"), "yes": True}),
        ):
            error, prompted = bridge(operation, values, expected=False)
            assert not prompted and error["code"] == "invalid_argument"
        assert not (base / "unreviewed.zip").exists()
        print("PASS bundled setup discovery, strict input and record-store independence", flush=True)

        parent = base / "skills 中文 & quoted ' parent"
        target = parent / skill["name"]
        selection = dict(agent="codex", directory=str(parent))
        preview, prompted = bridge("skills.preview", selection)
        assert not prompted and preview["state"] == "installed" and Path(preview["directory"]) == target
        assert not parent.exists(), "Preview must not create directories"
        install = dict(selection, review_digest=preview["digest"])
        bridge("skills.install", selection, expected=False)
        error, _ = bridge("skills.install", dict(install, review_digest="foreign"), expected=False)
        assert error["code"] == "plan_stale" and not parent.exists()
        for consent in ("cancel", "wrong", "wrong-digest", "eof"):
            _, prompted = bridge("skills.install", install, expected=False, confirmation=consent)
            assert prompted and not parent.exists()
        installed, prompted = bridge("skills.install", install, confirmation="accept")
        assert prompted and installed["state"] == "installed"
        assert snapshot(target) == {**shipped, ".shou-skill-manifest.json": (target / ".shou-skill-manifest.json").read_bytes()}
        original = snapshot(target)
        current = cli("skills", "install", "--agent", "codex", "--directory", str(parent))
        assert current["state"] == "already_current" and snapshot(target) == original
        print("PASS read-only preview, scope-bound consent, cancellation and exact repeated install", flush=True)

        (target / "SKILL.md").write_bytes(b"generated personal edits; keep")
        changed = snapshot(target)
        error = cli("skills", "install", "--agent", "codex", "--directory", str(parent), expected=False)
        assert error["code"] == "version_conflict" and snapshot(target) == changed
        assert not list(parent.glob(".shou-rule-authoring-backup-*"))
        manifest_path = target / ".shou-skill-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["files"]["SKILL.md"] = "sha256:" + hashlib.sha256((target / "SKILL.md").read_bytes()).hexdigest()
        manifest_path.write_text(json.dumps(manifest))
        previous = snapshot(target)
        preview, _ = bridge("skills.preview", selection)
        assert preview["state"] == "updated"

        def change_manifest(_):
            manifest_path.write_text(manifest_path.read_text() + "\n")

        error, prompted = bridge("skills.install", dict(selection, review_digest=preview["digest"]), expected=False,
                                 confirmation="accept", before=change_manifest)
        assert prompted and error["code"] == "plan_stale"
        assert not list(parent.glob(".shou-rule-authoring-backup-*"))
        manifest_path.write_bytes(previous[".shou-skill-manifest.json"])
        preview, _ = bridge("skills.preview", selection)
        updated, _ = bridge("skills.install", dict(selection, review_digest=preview["digest"]), confirmation="accept")
        backup = Path(updated["backup_directory"])
        assert updated["state"] == "updated" and backup.parent == parent and snapshot(backup) == previous
        assert all((target / name).read_bytes() == content for name, content in shipped.items())
        assert not list(parent.glob(".shou-rule-authoring-install-*"))
        claude = cli("skills", "install", "--agent", "claude-code", "--directory", str(base / "claude"))
        assert claude["agent"] == "claude-code" and claude["state"] == "installed"
        unknown = target / "personal-note.txt"
        unknown.write_text("keep unknown file")
        changed = snapshot(target)
        bridge("skills.preview", selection, expected=False)
        assert snapshot(target) == changed
        print("PASS personal edit preservation, reviewed-state changes, complete managed backups and both clients", flush=True)

        output = base / "Skill 中文 & user's export.zip"
        for consent in ("cancel", "wrong", "wrong-digest", "eof"):
            _, prompted = bridge("skills.export", dict(output=str(output)), expected=False, confirmation=consent)
            assert prompted and not output.exists()
        exported, prompted = bridge("skills.export", dict(output=str(output)), confirmation="accept")
        assert prompted and exported["state"] == "exported" and Path(exported["path"]) == output
        with zipfile.ZipFile(output) as archive:
            assert archive.testzip() is None
            assert set(archive.namelist()) == {skill["name"] + "/" + name for name in shipped}
            for name, content in shipped.items():
                assert archive.read(skill["name"] + "/" + name) == content
                assert archive.getinfo(skill["name"] + "/" + name).flag_bits & 0x800
        before_export = output.read_bytes()
        error = cli("skills", "export", "--output", str(output), expected=False)
        assert error["code"] == "version_conflict" and output.read_bytes() == before_export
        second = base / "deterministic.zip"
        cli("skills", "export", "--output", str(second))
        assert second.read_bytes() == before_export
        cli("skills", "export", "--output", str(base / "invalid.txt"), expected=False)

        raced = base / "concurrent-output.zip"

        def occupy_output(_):
            raced.write_bytes(b"generated concurrent output; keep")

        error, prompted = bridge("skills.export", dict(output=str(raced)), expected=False,
                                 confirmation="accept", before=occupy_output)
        assert prompted and error["code"] == "version_conflict" and raced.read_bytes() == b"generated concurrent output; keep"
        print("PASS portable ZIP contents/CRC/UTF-8/determinism, consent, exclusive output and concurrent conflict", flush=True)

        outside = base / "outside folder"
        outside.mkdir()
        (outside / "keep.txt").write_text("keep external folder")
        linked = base / "linked parent"
        if os.name == "nt":
            shell = Path(os.environ["SystemRoot"]) / "System32/cmd.exe"
            subprocess.run([str(shell), "/d", "/c", "mklink", "/J", str(linked), str(outside)],
                           check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        else:
            linked.symlink_to(outside, target_is_directory=True)
        try:
            cli("skills", "install", "--agent", "codex", "--directory", str(linked), expected=False)
            bridge("skills.preview", dict(agent="codex", directory=str(linked)), expected=False)
            cli("skills", "export", "--output", str(linked / "refused.zip"), expected=False)
            assert snapshot(outside) == {"keep.txt": b"keep external folder"}
        finally:
            if os.name == "nt":
                linked.rmdir()
            else:
                linked.unlink()
        assert blocked.read_text() == "keep; setup does not open cleanup records"
        print("PASS linked-parent/junction refusal without changing its target or cleanup records", flush=True)
    print(f"{checks} external agent setup CLI/desktop contracts passed; generated fixtures only.")


if __name__ == "__main__":
    main()
