#!/usr/bin/env python3
"""Confirm real CLI cleanup for generated fixtures and restore; purge is opt-in."""
from pathlib import Path
import argparse
import errno
import hashlib
import json
import os
import pty
import select
import signal
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', nargs='?', type=Path, default=root / '.build/debug/shou')
parser.add_argument('--native-trash-purge', action='store_true', help='Explicitly test permanent removal of generated fixture items after restoration.')
options = parser.parse_args()
binary = options.binary.resolve()


def confirm(arguments, environment, phrase, expected_paths):
    output_read, output_write = os.pipe()
    pid, terminal = pty.fork()
    if pid == 0:
        os.close(output_read)
        os.dup2(output_write, 1)
        os.close(output_write)
        os.execve(str(binary), [str(binary), *arguments, '--json'], environment)
    os.close(output_write)
    transcript, output = bytearray(), bytearray()
    readers = {terminal, output_read}
    sent = finished = False
    deadline = time.monotonic() + 60
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
                assert {entry['original_path'] for entry in scope['items']} == expected_paths
                assert scope['workspace']['path'] == environment['SHOU_FIXTURE_WORKSPACE']
                assert scope['selected_item_count'] == len(expected_paths)
                os.write(terminal, phrase.encode() + b'\n')
                sent = True
        assert not readers and sent, transcript.decode(errors='replace')
        _, status = os.waitpid(pid, 0)
        finished = True
        assert os.waitstatus_to_exitcode(status) == 0, (transcript.decode(), output.decode())
        envelope = json.loads(output)
        assert envelope['ok'], envelope
        return envelope['data']
    finally:
        if not finished:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(terminal)
        os.close(output_read)


with tempfile.TemporaryDirectory(prefix='shou-native-cli-') as temporary:
    base = Path(temporary).resolve()
    workspace = base / 'workspace'
    workspace.mkdir()
    targets = [workspace / 'Rust 项目/target', workspace / 'web/node_modules']
    for target in targets:
        target.mkdir(parents=True)
        for index in range(17):
            (target / f'generated-{index}.bin').write_bytes(bytes([index]) * 4096)
    (workspace / 'Rust 项目/Cargo.toml').write_text('[package]\nname = "fixture"\n')
    (workspace / 'Rust 项目/main.rs').write_text('fn main() {}\n')
    (workspace / 'web/package.json').write_text('{}')
    outside = base / 'retained-outside.txt'
    outside.write_text('Do not change this fixture.')
    outside_inode = outside.stat().st_ino
    link = targets[0] / 'outside-link'
    link.symlink_to(outside)
    environment = os.environ | {'SHOU_DATA_DIR': str(base / 'store'), 'SHOU_FIXTURE_WORKSPACE': str(workspace)}

    def hashes():
        return {str(path.relative_to(workspace)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in workspace.rglob('*') if path.is_file() and not path.is_symlink()}

    original = hashes()

    def run(*arguments):
        result = subprocess.run([str(binary), *arguments, '--json'], env=environment,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                start_new_session=True, timeout=60)
        assert result.returncode == 0, (arguments, result.stdout, result.stderr)
        return json.loads(result.stdout)['data']

    binding = run('workspaces', 'add', '--path', str(workspace), '--root-ref', 'native-cli-fixture')

    def trash():
        scan = run('scan', '--workspace', binding['id'])
        candidates = run('scan', 'results', '--scan-id', scan['scan_id'], '--limit', '500')['candidates']
        selected = [item for item in candidates if str(workspace / item['relative_path']) in {str(p) for p in targets}]
        assert len(selected) == 2 and all(item['eligible'] for item in selected), selected
        arguments = ['plan', 'create', '--scan-id', scan['scan_id']]
        for item in selected:
            arguments.extend(['--candidate', item['id']])
        plan = run(*arguments)
        receipt = confirm(['plan', 'execute', '--plan-id', plan['id']], environment,
                          'TRASH ' + plan['id'], {str(p) for p in targets})
        assert receipt['state'] == 'completed' and all(item['state'] == 'trashed' for item in receipt['items'])
        assert all(not target.exists() for target in targets)
        assert outside.read_text() == 'Do not change this fixture.' and outside.stat().st_ino == outside_inode
        return receipt

    def permanent_plan():
        scan = run('scan', '--workspace', binding['id'])
        candidates = run('scan', 'results', '--scan-id', scan['scan_id'], '--limit', '500')['candidates']
        selected = [item for item in candidates if str(workspace / item['relative_path']) == str(targets[0])]
        assert len(selected) == 1 and selected[0]['eligible'], selected
        plan = run('plan', 'create', '--scan-id', scan['scan_id'], '--candidate', selected[0]['id'], '--mode', 'permanent')
        receipt = confirm(['plan', 'execute', '--plan-id', plan['id']], environment,
                          'PURGE ' + plan['id'], {str(targets[0])})
        assert receipt['state'] == 'completed' and receipt['operation'] == 'permanent_cleanup'
        assert len(receipt['items']) == 1 and receipt['items'][0]['state'] == 'purged'
        assert not targets[0].exists()
        assert outside.read_text() == 'Do not change this fixture.' and outside.stat().st_ino == outside_inode
        return receipt

    def recreate_first_target():
        targets[0].mkdir(parents=True)
        for index in range(17):
            (targets[0] / f'generated-{index}.bin').write_bytes(bytes([index]) * 4096)
        (targets[0] / 'outside-link').symlink_to(outside)

    def followup(receipt, action):
        for item in receipt['items']:
            result = confirm(['history', action, '--execution-id', receipt['id'], '--item', item['id']],
                             environment, action.upper() + ' ' + receipt['id'], {item['original_path']})
            assert len(result) == 1 and result[0]['state'] == 'completed'
            original = next(entry for entry in item['manifest'] if entry['path'] == '.')
            try:
                current = os.lstat(item['trash_path'])
            except FileNotFoundError:
                pass
            else:
                assert (current.st_dev, current.st_ino) != (original['device'], original['inode']), item['trash_path']
            assert Path(item['original_path']).exists() == (action == 'restore')

    followup(trash(), 'restore')
    assert hashes() == original
    assert link.is_symlink() and link.resolve() == outside
    if options.native_trash_purge:
        permanent_plan()
        recreate_first_target()
        second = trash()
        followup(second, 'purge')
        retained = {path: digest for path, digest in original.items()
                    if not any(str(workspace / path).startswith(str(target) + '/') for target in targets)}
        assert hashes() == retained
    assert outside.read_text() == 'Do not change this fixture.' and outside.stat().st_ino == outside_inode
    assert len(run('history', 'list')) == (3 if options.native_trash_purge else 1)
    for receipt in run('history', 'list'):
        expected_followups = 0 if receipt.get('operation') == 'permanent_cleanup' else 2
        assert len(run('history', 'show', '--execution-id', receipt['id'])['followups']) == expected_followups
flow = 'restore and explicit purge' if options.native_trash_purge else 'restore only (no purge)'
print(f'Real CLI TTY confirmation, native Trash, selected-item {flow}, Unicode paths, hashes, and outside-link retention passed.')
