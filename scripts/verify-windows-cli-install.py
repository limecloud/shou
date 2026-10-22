#!/usr/bin/env python3
"""Verify the real user-command installer and native launcher in generated directories."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--launcher", type=Path, required=True)
    parser.add_argument("--installer", type=Path, required=True, help="Built Shou.Windows.Checks.dll")
    parser.add_argument("--dotnet", type=Path, required=True)
    parser.add_argument("--probe", type=Path)
    args = parser.parse_args()
    assert os.name == "nt", "Run native Windows CLI launcher verification on Windows."
    engine, template, installer, dotnet = [path.resolve(strict=True) for path in (args.engine, args.launcher, args.installer, args.dotnet)]
    with tempfile.TemporaryDirectory(prefix="shou-cli-install-") as directory:
        root = Path(directory).resolve()
        blocked = root / "blocked-record-store"
        blocked.write_text("keep; user command installation is independent of cleanup records")
        environment = dict(os.environ, SHOU_DATA_DIR=str(blocked))
        source_hashes = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in (engine, template)}

        def install(target, output, expected=True):
            result = subprocess.run([str(dotnet), str(installer), "--install-cli-fixture", str(template), str(target), str(output)],
                                    capture_output=True, env=environment, timeout=60)
            assert (result.returncode == 0) == expected, (result.returncode, result.stdout, result.stderr)
            return json.loads(result.stdout) if expected else None

        destination = root / "user CLI 中文 & %PATH% ' quoted"
        result = install(engine, destination)
        launcher = Path(result["launcher"])
        assert launcher == destination / "shou.exe" and not result["already_current"]
        assert launcher.read_bytes() == template.read_bytes()
        assert install(engine, destination)["already_current"]
        before = (destination / "shou.target").read_bytes()
        assert before == ("Shou CLI target v1\n" + str(engine) + "\n").encode()
        for arguments in (("--version",), ("agent", "skill", "--json"),
                          ("capabilities", "--command", "skills", "--json"), ("skills", "read"),
                          ("skills", "read", "missing", "--json")):
            direct = subprocess.run([str(engine), *arguments], capture_output=True, env=environment, cwd=root, timeout=30)
            forwarded = subprocess.run([str(launcher), *arguments], capture_output=True, env=environment, cwd=root, timeout=30)
            assert forwarded.returncode == direct.returncode, (arguments, direct, forwarded)
            if "--json" in arguments:
                first, second = json.loads(direct.stdout), json.loads(forwarded.stdout)
                first.pop("request_id", None); second.pop("request_id", None)
                assert first == second, (first, second)
            else:
                assert forwarded.stdout == direct.stdout
        print("PASS real installer, repeated install, bundled resources, read/discovery, streams and CLI error exit forwarding", flush=True)

        if args.probe:
            probe = args.probe.resolve(strict=True)
            package = root / "generated target 中文 & %PATH% ' quoted"
            package.mkdir()
            target = package / "shou.exe"
            shutil.copy2(probe, target)
            probe_directory = root / "probe user command"
            probe_launcher = Path(install(target, probe_directory)["launcher"])
            values = ["", "plain", "space value", "中文 emoji 🥭", "\"quoted\"", "trailing\\", "\\\\server\\path\\", "a\\\"b", "& whoami", "%PATH%", "!HOME!", "$(no-command)", "line\nbreak", "tab\tvalue", "x" * 8192]
            payload = b"generated stdin\x00\xff\nkeep binary bytes"
            run = subprocess.run([str(probe_launcher), *values], input=payload, capture_output=True, cwd=package, env=environment, timeout=30)
            assert run.returncode == 37 and run.stderr == b"generated probe stderr\n", run
            lines = run.stdout.splitlines()
            assert lines[-1] == b"stdin:" + payload.hex().encode()
            assert bytes.fromhex(lines[-2].removeprefix(b"cwd:").decode()).decode("utf-16-le") == str(package)
            assert [bytes.fromhex(line.removeprefix(b"arg:").decode()).decode("utf-16-le") for line in lines[:-2]] == values
            child_error = subprocess.run([str(probe_launcher), "--return-126"], input=b"", capture_output=True, cwd=package, env=environment, timeout=30)
            assert child_error.returncode == 126 and child_error.stderr == b"generated probe stderr\n"
            # A changed command is retained; installing does not execute it.
            original = probe_launcher.read_bytes()
            probe_launcher.write_bytes(b"generated personal command; keep")
            install(target, probe_directory, expected=False)
            assert probe_launcher.read_bytes() == b"generated personal command; keep"
            probe_launcher.write_bytes(original)
            print("PASS empty/quoted/Unicode/backslash/metacharacter arguments, original working directory, binary stdin, stderr and exact exit code", flush=True)

        # Only a generated junction is created, and its destination retains a sentinel.
        outside = root / "outside folder"
        outside.mkdir(); (outside / "keep.txt").write_bytes(b"keep")
        shutil.copy2(args.probe.resolve(strict=True) if args.probe else engine, outside / "shou.exe")
        linked = root / "linked parent"
        shell = Path(os.environ["SystemRoot"]) / "System32/cmd.exe"
        subprocess.run([str(shell), "/d", "/c", "mklink", "/J", str(linked), str(outside)], check=True, capture_output=True, timeout=10)
        try:
            install(engine, linked / "CLI", expected=False)
            assert {path.name for path in outside.iterdir()} == {"keep.txt", "shou.exe"} and (outside / "keep.txt").read_bytes() == b"keep"
            # Native launchers independently reject a junction in their target path.
            (destination / "shou.target").write_bytes(("Shou CLI target v1\n" + str(linked / "shou.exe") + "\n").encode())
            refused = subprocess.run([str(launcher), "--version"], capture_output=True, env=environment, timeout=10)
            assert refused.returncode == 126
        finally:
            linked.rmdir()
        for content in (b"invalid", b"Shou CLI target v1\nC:/missing/shou.exe\n", before.replace(b"Shou CLI target v1", b"Shou CLI target v2"),
                        b"Shou CLI target v1\n\xff\n", b"x" * 32769,
                        ("Shou CLI target v1\n" + str(launcher) + "\n").encode()):
            (destination / "shou.target").write_bytes(content)
            refused = subprocess.run([str(launcher)], capture_output=True, env=environment, timeout=10)
            assert refused.returncode == 126
        (destination / "shou.target").write_bytes(before)
        (destination / "personal.txt").write_bytes(b"keep unknown entry")
        install(engine, destination, expected=False)
        assert (destination / "personal.txt").read_bytes() == b"keep unknown entry"
        assert not list(root.glob(".shou-cli-install-*"))
        assert all(hashlib.sha256(path.read_bytes()).hexdigest() == value for path, value in source_hashes.items())
        assert blocked.read_text() == "keep; user command installation is independent of cleanup records"
        print("PASS conflicting content, malformed/missing targets, native junction refusal and retained sources/cleanup records; generated fixtures only", flush=True)


if __name__ == "__main__":
    main()
