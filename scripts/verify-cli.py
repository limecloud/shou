#!/usr/bin/env python3
"""Exercise the real CLI against temporary workspaces, with no controlling terminal."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import fcntl

root = Path(__file__).resolve().parents[1]
binary = (Path(sys.argv[1]) if len(sys.argv) > 1 else root / '.build/debug/shou').resolve()
checks = 0
with tempfile.TemporaryDirectory(prefix='shou-cli-') as temporary:
    base = Path(temporary).resolve()
    workspace = base / 'workspace'
    artifacts = workspace / 'project/target'
    artifacts.mkdir(parents=True)
    (workspace / 'project/Cargo.toml').write_text('[package]\nname = "fixture"\n')
    (artifacts / 'artifact.bin').write_bytes(b'x' * 8192)
    environment = dict(os.environ, SHOU_DATA_DIR=str(base / 'store'))

    def run(*arguments, expected=0):
        global checks
        process = subprocess.run([str(binary), *arguments, '--json'], env=environment,
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                 start_new_session=True, timeout=30)
        assert process.returncode == expected, (arguments, process.returncode, process.stdout, process.stderr)
        envelope = json.loads(process.stdout)
        assert envelope['api_version'] == '1.0'
        assert envelope['ok'] == (expected == 0), envelope
        assert 'error' in envelope and 'next_actions' in envelope
        checks += 1
        return envelope

    capabilities = run('capabilities')['data']
    assert capabilities['platform'] == 'macos'
    assert all('side_effect' in entry and 'required' in entry for entry in capabilities['commands'])
    scan_command=next(entry for entry in capabilities['commands'] if entry['command'] == 'scan')
    assert scan_command['exactly_one'] == ['workspace', 'location']
    assert 'scope' in scan_command['optional']
    assert any(entry['command'] == 'system scan' for entry in capabilities['commands'])
    locations=run('locations', 'list')['data']
    assert {item['id'] for item in locations} >= {'caches', 'npm', 'cargo', 'xcode', 'chrome', 'codex', 'claude', 'qq'}
    assert all(isinstance(item['exists'], bool) and item['rule_ids'] for item in locations)
    assert run('workspaces', 'list')['data'] == []
    run('scan', '--workspace', 'unused', '--location', 'caches', expected=2)
    run('scan', expected=2)
    run('scan', '--location', 'not-a-location', expected=2)
    run('system', 'scan', '--max-entries', '0', expected=2)
    invalid_projects = run('system', 'scan', '--include-projects', 'yes', expected=2)
    assert invalid_projects['error']['code'] == 'invalid_argument'
    assert 'true or false' in invalid_projects['error']['message']
    assert run('workspaces', 'list')['data'] == []
    run('capabilities', '--yes', 'true', expected=2)
    run('capabilities', '--locale', 'unrecognized', expected=2)
    assert run('rules', 'schema')['data']['additionalProperties'] is False
    for example in sorted((root / 'examples/rules').glob('*.json')):
        assert run('rules', 'validate', '--file', str(example))['data']['valid'] is True
    binding = run('workspaces', 'add', '--path', str(workspace), '--root-ref', 'developer-workspaces')['data']
    workspace_id = binding['id']
    assert run('workspaces', 'show', '--workspace', workspace_id)['data']['accessible'] is True
    run('workspaces', 'add', '--path', str(workspace), '--root-ref', 'duplicate', expected=2)

    catalog = run('rules', 'catalog', '--workspace', workspace_id)['data']
    assert any(rule['id'] == 'shou.builtin.rust-target' for rule in catalog)
    assert all(rule['scope']['root_ref'] == 'developer-workspaces' for rule in catalog)
    invalid_scope = run('scan', '--workspace', workspace_id, '--scope', 'unknown', expected=2)
    assert invalid_scope['error']['code'] == 'invalid_argument'
    cleanup_scan = run('scan', '--workspace', workspace_id, '--scope', 'cleanup')['data']
    assert cleanup_scan['scope'] == 'cleanup'
    assert cleanup_scan['tree_complete'] is False
    cleanup_first_page = run('scan', 'results', '--scan-id', cleanup_scan['scan_id'], '--limit', '1')['data']
    assert cleanup_first_page['next_cursor']
    cleanup_second_page = run('scan', 'results', '--scan-id', cleanup_scan['scan_id'],
                              '--cursor', cleanup_first_page['next_cursor'])['data']
    assert cleanup_first_page['candidates'][0]['id'] not in {item['id'] for item in cleanup_second_page['candidates']}
    for command in ('summary', 'children'):
        refusal = run('analysis', command, '--scan-id', cleanup_scan['scan_id'], expected=6)
        assert refusal['error']['code'] == 'partial_result'
    first_scan = run('scan', '--workspace', workspace_id, '--scope', 'full')['data']
    assert first_scan['scope'] == 'full'
    assert first_scan['tree_complete'] is True
    assert first_scan['reviewable_bytes_estimate'] >= 8192
    overview = run('analysis', 'summary', '--scan-id', first_scan['scan_id'])['data']
    assert overview['root']['allocated_bytes'] >= 8192
    assert any(category['id'] == 'build' for category in overview['categories'])
    children = run('analysis', 'children', '--scan-id', first_scan['scan_id'])['data']
    assert children['entries'][0]['path'] == 'project'
    nested = run('analysis', 'children', '--scan-id', first_scan['scan_id'], '--path', 'project', '--limit', '1')['data']
    assert nested['next_cursor']
    run('analysis', 'children', '--scan-id', first_scan['scan_id'], '--path', '.', '--cursor', nested['next_cursor'], expected=2)
    run('analysis', 'children', '--scan-id', first_scan['scan_id'], '--path', '../outside', expected=2)
    run('rules', 'disable', '--rule-id', 'shou.builtin.rust-target', '--workspace', workspace_id)
    disabled_scan = run('scan', '--workspace', workspace_id)['data']
    assert disabled_scan['eligible_count'] == 0
    run('rules', 'enable', '--rule-id', 'shou.builtin.rust-target', '--workspace', workspace_id)

    definition = json.loads((root / 'examples/rules/rust-target.rule.json').read_text())
    definition['conditions']['min_allocated_bytes'] = 0
    definition['conditions']['newest_descendant_modified_days_at_least'] = 0
    rule_file = base / 'rule.json'
    rule_file.write_text(json.dumps(definition))
    assert run('rules', 'validate', '--file', str(rule_file))['data']['runtime_verified'] is False
    run('rules', 'import', '--file', str(rule_file))
    run('rules', 'import', '--file', str(rule_file))
    with (base / 'store/.mutation.lock').open('r+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run('rules', 'import', '--file', str(rule_file), expected=4)
        fcntl.flock(lock, fcntl.LOCK_UN)
    assert not any(binding['rule_id'] == definition['id'] for binding in run('rules', 'list')['data']['bindings'])
    preview = run('rules', 'preview', '--file', str(rule_file), '--workspace', workspace_id)['data']
    candidates = run('scan', 'results', '--scan-id', preview['scan_id'])['data']['candidates']
    target = next(item for item in candidates if item['relative_path'] == 'project/target')
    assert target['eligible']
    run('plan', 'create', '--scan-id', preview['scan_id'], '--candidate', target['id'], expected=6)
    run('rules', 'enable', '--rule-id', definition['id'], '--workspace', workspace_id)
    scan = run('scan', '--workspace', workspace_id)['data']
    first_page = run('scan', 'results', '--scan-id', scan['scan_id'], '--limit', '1')['data']
    assert first_page['next_cursor']
    second_page = run('scan', 'results', '--scan-id', scan['scan_id'], '--cursor', first_page['next_cursor'])['data']
    assert first_page['candidates'][0]['id'] not in {item['id'] for item in second_page['candidates']}
    run('scan', 'results', '--scan-id', scan['scan_id'], '--cursor', 'wrong:0', expected=2)
    candidates = run('scan', 'results', '--scan-id', scan['scan_id'])['data']['candidates']
    target = next(item for item in candidates if item['relative_path'] == 'project/target')
    run('plan', 'create', '--scan-id', scan['scan_id'], expected=2)
    plan = run('plan', 'create', '--scan-id', scan['scan_id'], '--candidate', target['id'])['data']
    assert run('plan', 'show', '--plan-id', plan['id'])['data']['digest'] == plan['digest']
    refusal = run('plan', 'execute', '--plan-id', plan['id'], expected=7)
    assert refusal['error']['code'] == 'confirmation_required'
    assert (artifacts / 'artifact.bin').read_bytes() == b'x' * 8192
    assert run('history', 'list')['data'] == []
    preset = run('presets', 'save', '--name', 'Daily fixture', '--workspace', workspace_id, '--rule-id', definition['id'])['data']
    assert run('presets', 'scan', '--preset-id', preset['id'])['data']['status'] == 'complete'
    export = run('rules', 'export', '--rule-id', definition['id'])['data']
    assert 'workspace_id' not in export and 'path' not in export['scope']
    assert export['scope']['root_ref'] == 'developer-workspaces'
    invalid = dict(definition, shell='echo untrusted')
    rule_file.write_text(json.dumps(invalid))
    run('rules', 'import', '--file', str(rule_file), expected=2)
    run('workspaces', 'remove', '--workspace', workspace_id)
    assert (artifacts / 'artifact.bin').exists()
    assert run('workspaces', 'list')['data'] == []
print(f'{checks} real CLI contract checks passed; no cleanup targets were modified.')
