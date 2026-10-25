#!/usr/bin/env python3
"""Verify read-only diagnostics and execute generated Bash completion scripts."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
binary = (Path(sys.argv[1]) if len(sys.argv) > 1 else root / '.build/debug/shou').resolve()
checks = 0
with tempfile.TemporaryDirectory(prefix='shou-support-') as temporary:
    base = Path(temporary).resolve()
    store = base / 'private-name' / 'records'
    environment = dict(os.environ, SHOU_DATA_DIR=str(store))

    def run(*arguments, codes=(0,)):
        global checks
        result = subprocess.run([str(binary), *arguments], env=environment, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, start_new_session=True, timeout=15)
        assert result.returncode in codes, (arguments, result.returncode, result.stdout, result.stderr)
        checks += 1
        return result.stdout

    diagnostic = json.loads(run('diagnostics', '--json', codes=(0, 6)))
    report = diagnostic['data']
    assert report['format_version'] == 1 and report['platform'] in {'macos', 'linux'}
    assert len(report['checks']) == 3 and report['status'] in {'complete', 'partial'}
    assert next(c for c in report['checks'] if c['id'] == 'local_records')['state'] == 'not_configured'
    assert not store.parent.exists()
    assert str(base) not in json.dumps(report) and 'private-name' not in json.dumps(report)
    assert '诊断报告' in run('diagnostics', '--locale', 'zh-CN', codes=(0, 6))
    run('diagnostics', '--unknown', 'value', '--json', codes=(2,))
    run('completion', '--shell', 'fish', '--json', codes=(2,))
    discovered = json.loads(run('capabilities', '--json'))['data']['commands']
    scripts = {}
    for shell in ('bash', 'zsh'):
        scripts[shell] = run('completion', '--shell', shell)
        encoded = json.loads(run('completion', '--shell', shell, '--json'))['data']
        assert encoded == {'shell': shell, 'script': scripts[shell]}
        destination = base / ('completion.' + shell)
        destination.write_text(scripts[shell])
        executable = shutil.which(shell)
        if executable:
            result = subprocess.run([executable, '-n', str(destination)], capture_output=True, text=True, timeout=10)
            assert result.returncode == 0, (shell, result.stderr)
            checks += 1

    def complete(words, current):
        global checks
        # Arguments are passed as argv, never interpolated into shell source.
        script = 'source "$1"; shift; COMP_CWORD="$1"; shift; COMP_WORDS=("$@"); _shou; printf "%s\\n" "${COMPREPLY[@]}"'
        result = subprocess.run(['bash', '--noprofile', '--norc', '-c', script, 'shou-completion-test',
                                 str(base / 'completion.bash'), str(current), *words],
                                env=environment, capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr
        checks += 1
        return set(result.stdout.splitlines())

    roots = complete(['shou', ''], 1)
    assert {s['command'].split()[0] for s in discovered} <= roots
    assert {'summary', 'children', 'large-files', 'scan'} <= complete(['shou', 'analysis', ''], 2)
    assert complete(['shou', 'analysis', 'la'], 2) == {'large-files'}
    assert '--scan-id' in complete(['shou', 'analysis', 'children', ''], 3)
    assert complete(['shou', 'completion', '--shell', ''], 3) == {'bash', 'zsh'}
    assert complete(['shou', '--locale', ''], 2) == {'en', 'zh-CN'}
    assert complete(['shou', '--locale', 'zh-CN', 'analysis', 'la'], 4) == {'large-files'}
    assert complete(['shou', 'analysis', 'plan', '--mode', ''], 4) == {'permanent', 'trash'}
    assert not complete(['shou', 'analysis', 'children', '--scan-id', ''], 4) - {''}
    path = base / 'generated installer.pkg'
    path.write_text('synthetic installer placeholder')
    assert str(path) in complete(['shou', 'analysis', 'scan', '--path', str(base) + '/generated'], 4)
    hostile = '$(touch ' + str(base / 'must-not-exist') + ')'
    complete(['shou', hostile, ''], 2)
    assert not (base / 'must-not-exist').exists() and not store.parent.exists()
    store.parent.mkdir()
    store.write_text('generated record-store conflict; preserve bytes')
    before = store.read_bytes()
    conflict = json.loads(run('diagnostics', '--json', codes=(0, 6)))['data']
    assert next(c for c in conflict['checks'] if c['id'] == 'local_records')['state'] == 'attention'
    run('completion', '--shell', 'bash')
    assert store.read_bytes() == before
print(f'{checks} CLI support checks passed: diagnostics privacy/no writes, Bash behavior and available-shell syntax.')
