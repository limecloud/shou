#!/usr/bin/env python3
"""Verify native uninstall and restoration of uniquely generated macOS fixtures; never purge."""
from pathlib import Path
import errno
import hashlib
import json
import os
import plistlib
import pty
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

root = Path(__file__).resolve().parents[1]
binary = (Path(sys.argv[1]) if len(sys.argv) > 1 else root / '.build/debug/shou').resolve()
base = Path(tempfile.mkdtemp(prefix='shou-uninstall-cli-')).resolve()
identifier = 'dev.shou.generated.uninstall.' + uuid.uuid4().hex
home = Path.home()
app = home / 'Applications' / ('Shou 清理验收 ' + identifier.rsplit('.', 1)[1] + '.app')
cache = home / 'Library/Caches' / identifier
logs = home / 'Library/Logs' / identifier
preferences = home / 'Library/Preferences' / (identifier + '.plist')
support = home / 'Library/Application Support' / identifier
retained = home / 'Library/Application Support' / (identifier + '.retained')
targets = [app, cache, logs, preferences, support]
environment = os.environ | {'SHOU_DATA_DIR': str(base / 'store')}

for path in targets + [retained]:
    assert not path.exists() and not path.is_symlink(), path
    assert path.parent.resolve() == path.parent, path.parent
for path in [app / 'Contents/MacOS', cache, logs, support, retained]:
    path.mkdir(parents=True)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier, 'CFBundleName': 'Shou 清理验收', 'CFBundlePackageType': 'APPL', 'CFBundleExecutable': 'Fixture'}, fmt=plistlib.FMT_BINARY))
(app / 'Contents/MacOS/Fixture').write_bytes(b'inert generated application fixture')
(cache / 'payload.bin').write_bytes(b'generated cache' * 4096)
(logs / 'log.txt').write_text('generated application log\n')
preferences.write_bytes(plistlib.dumps({'generated': True, 'value': 'restore me'}, fmt=plistlib.FMT_BINARY))
(support / 'personal.bin').write_bytes(b'generated personal app data')
(retained / 'sentinel.txt').write_text('This unrelated generated directory must survive.\n')


def hashes():
    files = []
    for path in targets + [retained]:
        if path.is_file():
            files.append(path)
        elif path.is_dir():
            files.extend(child for child in path.rglob('*') if child.is_file() and not child.is_symlink())
    return {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}


original = hashes()
(base / 'fixture.json').write_text(json.dumps({'application': str(app), 'identifier': identifier, 'targets': list(map(str, targets)), 'retained': str(retained), 'hashes': original}, ensure_ascii=False, indent=2))
print(f'Generated fixture evidence: {base}', flush=True)


def run(*arguments, expected=0):
    result = subprocess.run([str(binary), *arguments, '--json'], env=environment, stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, start_new_session=True, timeout=90)
    assert result.returncode == expected, (arguments, result.returncode, result.stdout, result.stderr)
    return json.loads(result.stdout)


def confirm(arguments, phrase, expected_paths, cancel=False):
    output_read, output_write = os.pipe()
    pid, terminal = pty.fork()
    if pid == 0:
        os.close(output_read)
        os.dup2(output_write, 1)
        os.close(output_write)
        os.execve(str(binary), [str(binary), *arguments, '--json'], environment)
    os.close(output_write)
    readers = {terminal, output_read}
    transcript, output = bytearray(), bytearray()
    sent = finished = False
    deadline = time.monotonic() + 90
    try:
        while readers and time.monotonic() < deadline:
            for descriptor in select.select(list(readers), [], [], 0.1)[0]:
                try:
                    data = os.read(descriptor, 65536)
                except OSError as error:
                    if descriptor == terminal and error.errno == errno.EIO:
                        data = b''
                    else:
                        raise
                if not data:
                    readers.remove(descriptor)
                else:
                    (transcript if descriptor == terminal else output).extend(data)
            if not sent and phrase.encode() in transcript:
                scope, _ = json.JSONDecoder().raw_decode(transcript.decode().lstrip())
                assert {item['original_path'] for item in scope['items']} == expected_paths
                assert scope['selected_item_count'] == len(expected_paths)
                assert scope['irreversible'] is False
                (base / ('cancel-scope.json' if cancel else arguments[0] + '-scope.json')).write_text(json.dumps(scope, ensure_ascii=False, indent=2))
                os.write(terminal, b'CANCEL\n' if cancel else phrase.encode() + b'\n')
                sent = True
        assert not readers and sent, transcript.decode(errors='replace')
        _, status = os.waitpid(pid, 0)
        finished = True
        envelope = json.loads(output)
        if cancel:
            assert envelope['error']['code'] == 'cancelled' and os.waitstatus_to_exitcode(status) != 0
        else:
            assert os.waitstatus_to_exitcode(status) == 0 and envelope['ok'], envelope
        return envelope
    finally:
        if not finished:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(terminal)
        os.close(output_read)


review = run('applications', 'inspect', '--path', str(app))['data']
components = [item for item in review['components'] if item['eligible']]
assert len(components) == 5
selection = [argument for item in components for argument in ['--component', item['id']]]
denied = run('applications', 'plan', '--review-id', review['id'], *selection, expected=7)
assert denied['error']['code'] == 'confirmation_required'
plan = run('applications', 'plan', '--review-id', review['id'], *selection, '--include-user-data', 'true')['data']
assert run('applications', 'plan', 'show', '--plan-id', plan['id'])['data'] == plan
assert run('applications', 'uninstall', '--plan-id', plan['id'], expected=7)['error']['code'] == 'confirmation_required'
arguments = ['applications', 'uninstall', '--plan-id', plan['id']]
paths = set(map(str, targets))
confirm(arguments, 'UNINSTALL ' + plan['id'], paths, cancel=True)
assert hashes() == original and run('history', 'list')['data'] == []
receipt = confirm(arguments, 'UNINSTALL ' + plan['id'], paths)['data']
assert receipt['operation'] == 'application_uninstall' and receipt['state'] == 'completed'
assert all(item['state'] == 'trashed' and item['uninstall_origin'] and not Path(item['original_path']).exists() for item in receipt['items'])
assert run('history', 'inspect', '--execution-id', receipt['id'])['data']['status'] == 'complete'
restore = ['history', 'restore', '--execution-id', receipt['id']]
restore += [argument for item in receipt['items'] for argument in ['--item', item['id']]]
restored = confirm(restore, 'RESTORE ' + receipt['id'], paths)['data']
assert len(restored) == 5 and all(item['state'] == 'completed' for item in restored)
assert hashes() == original
inspection = run('history', 'inspect', '--execution-id', receipt['id'])['data']
assert inspection['status'] == 'complete' and all(item['state'] == 'restored' for item in inspection['items'])
for item in receipt['items']:
    assert not Path(item['trash_path']).exists(), item['trash_path']
(base / 'verified.json').write_text(json.dumps({'receipt': receipt, 'inspection': inspection, 'hashes_match': True, 'purge': False}, ensure_ascii=False, indent=2))
# Remove only this script's uniquely generated, fully restored fixture paths.
for path in targets + [retained]:
    if path.is_dir():
        shutil.rmtree(path)
    else:
        path.unlink()
print('PASS native CLI uninstall: explicit consent, TTY cancellation/refusal, five-component Trash, independent restore, hashes and retained sentinel; no purge.')
