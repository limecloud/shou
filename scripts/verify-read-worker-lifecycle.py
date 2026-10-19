#!/usr/bin/env python3
"""Verify the real read worker exits after its requesting parent disappears."""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import signal
import subprocess
import sys
import time
import uuid


def write_json(path, value):
    with path.open('x') as handle:
        json.dump(value, handle, indent=2)
        handle.write('\n')
    path.chmod(0o600)


def parent_stage(executable, evidence):
    channel = evidence / 'channel'
    channel.mkdir(mode=0o700)
    request_id = str(uuid.uuid4())
    write_json(channel / 'request.json', {
        'version': 1, 'id': request_id, 'parent_pid': os.getpid(),
        'operation': 'inspect', 'path': str(evidence / 'workspace'),
        'budget': {'max_entries': 200_000, 'max_seconds': 30, 'max_depth': 10},
    })
    worker = subprocess.Popen(
        [str(executable), '--internal-read-worker', str(channel)],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    write_json(evidence / 'worker.json', {'pid': worker.pid, 'request_id': request_id})
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            progress = json.loads((channel / 'progress.json').read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            progress = None
        if progress and progress.get('id') == request_id and worker.poll() is None:
            write_json(evidence / 'parent-exit.json', {
                'pid': os.getpid(), 'worker_pid': worker.pid,
                'worker_alive': True, 'progress': progress,
                'result_already_present': (channel / 'result.json').exists(),
            })
            # Exit without Popen cleanup: the worker's watchdog owns this boundary.
            os._exit(86)
        if worker.poll() is not None:
            raise RuntimeError('Worker finished before the parent-exit boundary.')
        time.sleep(0.01)
    raise RuntimeError('Worker did not publish validated progress in time.')


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def verify(executable, evidence):
    executable = executable.resolve(strict=True)
    evidence.mkdir(parents=True, exist_ok=False)
    evidence = evidence.resolve()
    workspace = evidence / 'workspace'
    workspace.mkdir()
    # Hard links keep this fixture small while making traversal outlive the timer.
    seeds = []
    for number in range(8):
        seed = workspace / f'preserve-{number}.txt'
        seed.write_text(f'read-only lifecycle fixture {number}\n')
        seeds.append(seed)
    expected = {seed.name: hashlib.sha256(seed.read_bytes()).hexdigest() for seed in seeds}
    for directory in range(250):
        folder = workspace / f'group-{directory:03d}'
        folder.mkdir()
        for number in range(400):
            os.link(seeds[number % len(seeds)], folder / f'entry-{number:03d}')
    parent = subprocess.Popen([
        sys.executable, str(Path(__file__).resolve()), '--parent-stage',
        '--bin', str(executable), '--evidence', str(evidence),
    ])
    try:
        assert parent.wait(timeout=15) == 86, 'Parent must exit after observing live worker progress.'
        boundary = json.loads((evidence / 'parent-exit.json').read_text())
        assert not boundary['result_already_present'], 'Boundary must precede scan completion.'
        worker_pid = boundary['worker_pid']
        started = time.monotonic()
        while alive(worker_pid) and time.monotonic() - started < 5:
            time.sleep(0.01)
        elapsed = time.monotonic() - started
        assert not alive(worker_pid), 'Read worker remained alive after parent exit.'
        assert not (evidence / 'channel/result.json').exists(), 'Interrupted traversal must not publish scan evidence.'
        actual_count = sum(len(files) for _, _, files in os.walk(workspace))
        assert actual_count == 100_008
        assert all(hashlib.sha256((workspace / name).read_bytes()).hexdigest() == digest for name, digest in expected.items())
        assert all(seed.stat().st_nlink == 12_501 for seed in seeds)
        report = {
            'checked_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'executable': str(executable), 'executable_sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
            'parent_exit': 86, 'worker_pid': worker_pid, 'worker_absent': True,
            'observed_exit_seconds_after_parent_wait': elapsed, 'published_result': False,
            'fixture_files_retained': actual_count, 'seed_hashes': expected,
            'seed_link_counts_retained': True, 'cleanup_or_store_access': False,
        }
        write_json(evidence / 'verification.json', report)
        print(f'Read worker parent-exit boundary passed; {actual_count:,} fixture entries retained, no scan result published.')
    finally:
        if parent.poll() is None:
            parent.kill()
            parent.wait(timeout=5)
        marker = evidence / 'worker.json'
        if marker.exists():
            pid = json.loads(marker.read_text())['pid']
            if alive(pid):
                command = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True, check=False).stdout
                if '--internal-read-worker ' + str(evidence / 'channel') in command:
                    os.kill(pid, signal.SIGKILL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--parent-stage', action='store_true', help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.parent_stage:
        parent_stage(arguments.bin, arguments.evidence)
    else:
        verify(arguments.bin, arguments.evidence)


if __name__ == '__main__':
    main()
