#!/usr/bin/env python3
"""Verify a packaged CLI launcher with isolated, relocated and quoted paths."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (Path(sys.argv[1]) if len(sys.argv) > 1 else root / '.build/debug').resolve()
with tempfile.TemporaryDirectory(prefix='shou-cli-install-') as temporary:
    base = Path(temporary).resolve()
    package = base / "CLI's relocated files"
    package.mkdir()
    shutil.copy2(source / 'shou', package / 'shou')
    for name in ('Shou_ShouCore.bundle', 'Shou_ShouContracts.bundle', 'Shou_ShouAgentSupport.bundle'):
        shutil.copytree(source / name, package / name, symlinks=True)
    blocked = base / 'blocked-store'
    blocked.write_text('preserve')
    environment = dict(os.environ, SHOU_DATA_DIR=str(blocked))
    bin_directory = base / "user's bin"

    def install(directory=bin_directory, expected=0):
        process = subprocess.run([sys.executable, str(root / 'scripts/install-cli.py'),
                                  '--executable', str(package / 'shou'), '--bin-directory', str(directory)],
                                 env=environment, capture_output=True, text=True, timeout=30)
        assert process.returncode == expected, (process.stdout, process.stderr)
        return json.loads(process.stdout) if expected == 0 else process

    assert install()['state'] == 'installed'
    launcher = bin_directory / 'shou'
    contents = launcher.read_bytes()
    assert not launcher.is_symlink() and os.access(launcher, os.X_OK)
    assert install()['state'] == 'already_current' and launcher.read_bytes() == contents
    skill = json.loads(subprocess.check_output([str(launcher), 'agent', 'skill', '--json'], env=environment))['data']
    assert Path(skill['entrypoint']).resolve().is_relative_to(package)
    assert skill['instructions'] == (root / 'skills/shou-rule-authoring/SKILL.md').read_text()
    capability = json.loads(subprocess.check_output([str(launcher), 'capabilities', '--command', 'skills', '--json'], env=environment))
    assert capability['ok'] and len(capability['data']['commands']) == 4
    read = subprocess.check_output([str(launcher), 'skills', 'read', 'shou-rule-authoring'], env=environment)
    assert read == (root / 'skills/shou-rule-authoring/SKILL.md').read_bytes()
    invalid = subprocess.run([str(launcher), 'skills', 'read', 'missing', '--json'], env=environment, capture_output=True)
    assert invalid.returncode == 2 and json.loads(invalid.stdout)['error']['code'] == 'invalid_argument'
    launcher.write_bytes(b'local entry must be preserved\n')
    install(expected=1)
    assert launcher.read_bytes() == b'local entry must be preserved\n'
    external = base / 'external'
    external.mkdir()
    linked = base / 'linked-bin'
    linked.symlink_to(external, target_is_directory=True)
    install(linked, expected=1)
    assert not list(external.iterdir())
    linked_entry = base / 'linked-entry'
    linked_entry.mkdir()
    (linked_entry / 'shou').symlink_to(launcher)
    install(linked_entry, expected=1)
    assert (linked_entry / 'shou').is_symlink() and blocked.read_text() == 'preserve'
print('CLI launcher verified: relocated resources, quoted paths, argument/exit forwarding, repeated install and conflict preservation.')
