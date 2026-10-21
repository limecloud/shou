#!/usr/bin/env python3
"""Compare read-only directory scans and sampled worker threads on one generated tree."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True, type=Path)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('Worker thread sampling requires macOS ps -M.')
    binaries = {name: getattr(args, name).resolve(strict=True) for name in ('baseline', 'candidate')}
    base = args.evidence.resolve()
    base.mkdir(parents=True, exist_ok=False)
    workspace = base / 'workspace'
    workspace.mkdir()
    # Many short-lived directories stress completion scheduling, unlike a few wide folders.
    for group in range(16):
        for branch in range(128):
            parent = workspace / f'group-{group}' / f'branch-{branch}'
            for leaf in range(4):
                directory = parent / f'leaf-{leaf}'
                directory.mkdir(parents=True)
                (directory / 'generated.bin').write_bytes(b'generated metadata fixture\n')
    files = list(workspace.rglob('generated.bin'))
    original = {str(p.relative_to(workspace)): digest(p) for p in files}
    expected_count = 1 + sum(1 for _ in workspace.rglob('*'))
    runs = []
    for round_number, order in enumerate((('baseline', 'candidate'), ('candidate', 'baseline'))):
        for name in order:
            run_dir = base / f'{round_number}-{name}'
            run_dir.mkdir()
            env = dict(os.environ, SHOU_DATA_DIR=str(run_dir / 'records'), SHOU_STORAGE_SCAN_WORKERS='8')
            started = time.monotonic()
            peak_threads = 0
            samples = 0
            with (run_dir / 'stdout.json').open('w') as stdout, (run_dir / 'stderr.log').open('w') as stderr:
                process = subprocess.Popen([str(binaries[name]), 'analysis', 'scan', '--path', str(workspace), '--json'],
                                           env=env, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr)
                try:
                    while process.poll() is None:
                        if time.monotonic() - started > 120:
                            raise TimeoutError('Generated scan exceeded 120 seconds.')
                        children = subprocess.run(['pgrep', '-P', str(process.pid)], capture_output=True, text=True,
                                                  timeout=5).stdout.split()
                        # Standalone CLI scans run directly; desktop scans use a read child.
                        for child in [str(process.pid), *children]:
                            observed = subprocess.run(['ps', '-M', '-p', child, '-o', 'pid='],
                                                      capture_output=True, text=True, timeout=5)
                            # On macOS -M uses its fixed thread layout despite -o.
                            count = sum(1 for line in observed.stdout.splitlines()
                                        if child in line.split()[:2])
                            peak_threads = max(peak_threads, count)
                            samples += 1
                        time.sleep(0.05)
                finally:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=15)
            elapsed = time.monotonic() - started
            response = json.loads((run_dir / 'stdout.json').read_text())
            assert process.returncode == 0 and response['ok'], response
            scan = response['data']
            assert scan['status'] == 'complete' and scan['entry_count'] == expected_count, scan
            summary = subprocess.run([str(binaries[name]), 'analysis', 'summary', '--scan-id', scan['scan_id'], '--json'],
                                     env=env, capture_output=True, text=True, check=True, timeout=15)
            root = json.loads(summary.stdout)['data']['root']
            assert root['file_count'] == len(files), root
            row = {'engine': name, 'round': round_number, 'seconds': elapsed, 'entry_count': scan['entry_count'],
                   'root': root, 'peak_sampled_scan_process_threads': peak_threads, 'thread_samples': samples}
            runs.append(row)
            print(json.dumps(row), flush=True)
    assert original == {str(p.relative_to(workspace)): digest(p) for p in files}
    assert len({(r['root']['logical_bytes'], r['root']['allocated_bytes'], r['root']['file_count']) for r in runs}) == 1
    result = {'platform': platform.platform(), 'engines': {k: {'path': str(p), 'sha256': digest(p)} for k, p in binaries.items()},
              'conditions': 'Same generated APFS tree; warm scans; alternating order; eight readers requested; '
                            'ps sampling overhead included equally; peak per-process thread counts include non-reader threads.',
              'generated_file_count': len(files), 'expected_entry_count': expected_count, 'retained_hashes_match': True,
              'runs': runs, 'medians': {name: {'seconds': statistics.median(r['seconds'] for r in runs if r['engine'] == name),
                                             'peak_sampled_scan_process_threads': statistics.median(r['peak_sampled_scan_process_threads'] for r in runs if r['engine'] == name)}
                                      for name in binaries}}
    (base / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result['medians'], indent=2))


if __name__ == '__main__':
    main()
