#!/usr/bin/env python3
"""Cancel real CLI TTY reviews in an isolated store; never authorize an operation."""
from pathlib import Path
import errno
import json
import os
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time


root = Path(__file__).resolve().parents[3]
binary = (Path(sys.argv[1]) if len(sys.argv) > 1 else root / '.build/debug/shou').resolve()
checks = 0


def cancelled_review(arguments, environment, phrase):
    """Keep the machine envelope on stdout, separate from the controlling TTY."""
    stdout_read, stdout_write = os.pipe()
    pid, terminal = pty.fork()
    if pid == 0:
        os.close(stdout_read)
        os.dup2(stdout_write, 1)
        os.close(stdout_write)
        os.execve(str(binary), [str(binary), *arguments, '--json'], environment)
    os.close(stdout_write)
    transcript = bytearray()
    stdout = bytearray()
    readers = {terminal, stdout_read}
    cancelled = False
    finished = False
    deadline = time.monotonic() + 30
    try:
        while readers and time.monotonic() < deadline:
            ready, _, _ = select.select(list(readers), [], [], 0.2)
            for descriptor in ready:
                try:
                    data = os.read(descriptor, 65536)
                except OSError as error:
                    if descriptor == terminal and error.errno == errno.EIO:
                        data = b''
                    else:
                        raise
                if not data:
                    readers.remove(descriptor)
                    continue
                (transcript if descriptor == terminal else stdout).extend(data)
            if not cancelled and phrase.encode() in transcript:
                # No test ever sends TRASH, RESTORE or PURGE authorization.
                os.write(terminal, b'cancel\n')
                cancelled = True
        assert not readers, 'CLI review did not finish after cancellation'
        _, status = os.waitpid(pid, 0)
        finished = True
        assert cancelled, transcript.decode(errors='replace')
        assert os.waitstatus_to_exitcode(status) == 130, (transcript, stdout, status)
        envelope = json.loads(stdout)
        assert envelope['ok'] is False and envelope['status'] == 'cancelled', envelope
        assert envelope['error']['code'] == 'cancelled', envelope
        text = transcript.decode()
        review, _ = json.JSONDecoder().raw_decode(text.lstrip())
        return review, text
    finally:
        if not finished:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(terminal)
        os.close(stdout_read)


with tempfile.TemporaryDirectory(prefix='shou-cli-review-') as temporary:
    base = Path(temporary).resolve()
    workspace = base / 'workspace'
    target = workspace / 'project/target'
    target.mkdir(parents=True)
    (workspace / 'project/Cargo.toml').write_text('[package]\nname = "review-fixture"\n')
    for index in range(257):
        (target / f'manifest-child-{index:03}.bin').write_bytes(b'x' * 16)
    environment = dict(os.environ, SHOU_DATA_DIR=str(base / 'store'))

    def run(*arguments):
        result = subprocess.run([str(binary), *arguments, '--json'], env=environment,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                start_new_session=True, timeout=30)
        assert result.returncode == 0, (arguments, result.stdout, result.stderr)
        return json.loads(result.stdout)['data']

    binding = run('workspaces', 'add', '--path', str(workspace), '--root-ref', 'review-fixture')
    scan = run('scan', '--workspace', binding['id'])
    candidates = run('scan', 'results', '--scan-id', scan['scan_id'])['candidates']
    candidate = next(item for item in candidates if item['relative_path'] == 'project/target')
    plan = run('plan', 'create', '--scan-id', scan['scan_id'], '--candidate', candidate['id'])
    assert len(plan['items'][0]['manifest']) == 258
    # Read commands retain complete evidence; only the interactive review is compact.
    assert run('plan', 'show', '--plan-id', plan['id']) == plan
    review, transcript = cancelled_review(['plan', 'execute', '--plan-id', plan['id']], environment,
                                          'TRASH ' + plan['id'])
    assert review['action'] == 'trash' and review['plan_id'] == plan['id']
    assert review['digest'] == plan['digest'] and review['selected_item_count'] == 1
    assert review['workspace']['path'] == str(workspace)
    assert review['items'][0]['original_path'] == str(target)
    assert review['items'][0]['risk'] == candidate['risk']
    assert review['items'][0]['rebuild_notes'] == candidate['rebuild_notes']
    assert review['items'][0]['limitations'] == candidate['limitations']
    assert review['allocated_bytes_estimate'] == plan['items'][0]['candidate']['allocated_bytes_estimate']
    assert 'manifest-child-' not in transcript and '"manifest"' not in transcript
    assert '"identity"' not in transcript and len(transcript.encode()) < 16384
    assert run('history', 'list') == []
    checks += 1

    # Synthetic receipts provide review data only. Their paths are within this fixture,
    # not the system Trash, and cancellation occurs before any filesystem operation.
    item = plan['items'][0]
    selected = dict(id=item['id'], original_path=str(target), relative_path='project/target',
                    trash_path=str(base / 'fake-trash/selected'), manifest=item['manifest'],
                    state='trashed', allocated_bytes_estimate=candidate['allocated_bytes_estimate'])
    other = dict(selected, id='unselected_item', relative_path='unselected-target',
                 original_path=str(workspace / 'unselected-target'), trash_path=str(base / 'fake-trash/unselected'))
    receipt = dict(id='execution_review_fixture', plan_id=plan['id'], workspace=plan['workspace'],
                   created_at=plan['created_at'], entry_point='cli', state='completed', items=[selected, other])
    history = base / 'store/history'
    history.mkdir(exist_ok=True, mode=0o700)
    (history / (receipt['id'] + '.json')).write_text(json.dumps(receipt))
    digests = []
    for action, locale in [('restore', 'en'), ('purge', 'zh-CN')]:
        review, transcript = cancelled_review(['history', action, '--execution-id', receipt['id'],
                                               '--item', selected['id'], '--locale', locale], environment,
                                              action.upper() + ' ' + receipt['id'])
        assert review['action'] == action and review['execution_id'] == receipt['id']
        assert review['plan_id'] == plan['id'] and review['selected_item_count'] == 1
        assert review['irreversible'] == (action == 'purge')
        assert len(review['items']) == 1 and review['items'][0]['id'] == selected['id']
        assert review['items'][0]['original_path'] == str(target)
        assert review['items'][0]['trash_path'] == selected['trash_path']
        assert review['items'][0]['risk'] == candidate['risk']
        assert review['items'][0]['rebuild_notes'] == candidate['rebuild_notes']
        assert 'unselected-target' not in transcript and 'manifest-child-' not in transcript
        assert '"manifest"' not in transcript and len(transcript.encode()) < 16384
        assert review['digest'].startswith('sha256:') and len(review['digest']) == 71
        if locale == 'zh-CN':
            assert '其他输入取消' in transcript and '不可撤销' in transcript
        digests.append(review['digest'])
        checks += 1
    assert digests[0] != digests[1], 'The confirmation digest must bind the action'

    receipt['id'] = 'execution_missing_plan_fixture'
    receipt['plan_id'] = 'plan_unavailable'
    (history / (receipt['id'] + '.json')).write_text(json.dumps(receipt))
    review, _ = cancelled_review(['history', 'restore', '--execution-id', receipt['id'],
                                  '--item', selected['id'], '--locale', 'en'], environment, 'RESTORE ' + receipt['id'])
    assert review['items'][0]['risk'] == 'unavailable'
    assert review['items'][0]['rebuild_notes'] == []
    assert 'unavailable' in review['items'][0]['limitations'][0]
    followups = base / 'store/followups'
    assert not followups.exists() or not list(followups.glob('*.json'))
    assert len(list(target.glob('manifest-child-*.bin'))) == 257
    assert all(path.read_bytes() == b'x' * 16 for path in target.glob('*.bin'))
    checks += 1

print(f'{checks} compact CLI confirmation checks passed; all operations were cancelled.')
