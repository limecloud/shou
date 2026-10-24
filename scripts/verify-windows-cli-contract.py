#!/usr/bin/env python3
"""Verify the .NET CLI machine entry without invoking native Windows filesystem APIs."""
from pathlib import Path
import argparse
import json
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--dotnet', type=Path, default=ROOT / '.build/toolchains/dotnet/dotnet')
parser.add_argument('--payload', type=Path, default=ROOT / '.build/windows/bin/Shou.Windows.Cli/release')
options = parser.parse_args()
dotnet = Path(shutil.which(str(options.dotnet)) or options.dotnet).resolve()
if not dotnet.is_file():
    parser.error('The specified dotnet executable is unavailable.')
payload = options.payload.resolve()
checks = 0

with tempfile.TemporaryDirectory(prefix='shou-dotnet-cli-contract-') as directory:
    relocated = Path(directory) / '原生 CLI with spaces'
    shutil.copytree(payload, relocated)
    data_directory = Path(directory) / '私有数据'
    environment = {**os.environ, 'SHOU_DATA_DIR': str(data_directory)}

    def run(arguments, exit_code=0):
        global checks
        result = subprocess.run([str(dotnet), str(relocated / 'shou.dll'), *arguments],
                                cwd=directory, capture_output=True, text=True, encoding='utf-8', timeout=20,
                                stdin=subprocess.DEVNULL, env=environment)
        assert result.returncode in ((exit_code,) if isinstance(exit_code, int) else exit_code), (arguments, result.returncode, result.stdout, result.stderr)
        envelope = json.loads(result.stdout)
        assert envelope['api_version'] == '1.0'
        assert envelope['ok'] == (result.returncode == 0)
        assert envelope['request_id'].startswith('request_')
        assert not result.stderr, result.stderr
        checks += 1
        return envelope

    import xml.etree.ElementTree as ET
    expected_version = ET.parse(Path(__file__).resolve().parents[1] / 'apps/windows/Directory.Build.props').findtext('.//Version')
    assert expected_version
    assert run(['--version', '--json'])['data']['version'].split('+', 1)[0] == expected_version
    capabilities = run(['capabilities', '--json'])['data']
    assert capabilities['platform'] == 'windows'
    assert capabilities['application_version'].split('+', 1)[0] == expected_version
    assert capabilities['api_version'] == '1.0' and capabilities['rule_schema_version'] == '1.0'
    assert capabilities['mutation_available'] is False and capabilities['trash_available'] is False and capabilities['application_uninstall_available'] is False
    assert capabilities['startup_control_available'] is False
    read_commands = {'capabilities', 'rules schema', 'rules catalog', 'system locations', 'rules validate', 'analysis scan', 'applications summary', 'applications inspect', 'applications plan show', 'applications execution show', 'startup list', 'startup inspect', 'startup execution show',
                     'workspaces list', 'workspaces show', 'exclusions list',
                     'rules list', 'rules show', 'rules export', 'scan results',
                     'plan show', 'history list', 'history show', 'history inspect', 'privacy scan show'}
    configuration_commands = {'workspaces add', 'workspaces remove', 'workspaces exclude add', 'workspaces exclude remove',
                              'exclusions global add', 'exclusions global remove', 'rules import', 'rules enable', 'rules disable'}
    snapshot_commands = {'scan', 'rules preview', 'system scan', 'privacy scan'}
    plan_commands = {'plan create', 'applications plan'}
    destructive_commands = {'plan execute', 'applications uninstall', 'startup control'}
    all_commands = read_commands | configuration_commands | snapshot_commands | plan_commands | destructive_commands
    assert {item['command'] for item in capabilities['commands']} == all_commands
    for command in capabilities['commands']:
        expected = 'read' if command['command'] in read_commands else 'configuration' if command['command'] in configuration_commands else 'snapshot' if command['command'] in snapshot_commands else 'plan' if command['command'] in plan_commands else 'destructive'
        assert command['side_effect'] == expected
        assert command['available'] == (command['command'] not in destructive_commands)
        if command['command'] in destructive_commands:
            assert command['unavailable_reason'] == 'native_acceptance_pending'
    assert all({'required', 'optional', 'repeated', 'description'} <= item.keys() for item in capabilities['commands'])
    focused = run(['capabilities', '--command', 'rules', '--json'])['data']['commands']
    assert {item['command'] for item in focused} == {name for name in all_commands if name.startswith('rules ')}
    assert run(['capabilities', '--command', 'analysis scan', '--json'])['data']['commands'][0]['required'] == ['path']
    assert run(['--help', '--json'])['data']['command'] == 'shou'
    assert run(['rules', '--help', '--json'])['data']['commands'] == focused
    assert run(['rules', '--json'])['data']['commands'] == focused
    assert len(run(['workspaces', '--json'])['data']['commands']) == 6
    assert len(run(['workspaces', 'exclude', '--help', '--json'])['data']['commands']) == 2
    assert {command['command'] for command in run(['scan', '--json'])['data']['commands']} == {'scan', 'scan results'}
    assert run(['rules', 'schema', '--json'])['data'] == json.loads((ROOT / 'packages/shou-contracts/rule.schema.json').read_text())
    catalog = run(['rules', 'catalog', '--json'])['data']
    assert len(catalog) == 39 and all(rule['id'].startswith('shou.builtin.') for rule in catalog)
    assert not data_directory.exists()
    workspace = 'ws_' + '0' * 32
    scan_id = 'scan_' + '0' * 32
    privacy_scan_id = 'privacy_scan_' + '0' * 32
    plan_id = 'plan_' + '0' * 32
    execution_id = 'execution_' + '0' * 32
    candidate_id = 'candidate_' + '0' * 32
    application_id = 'application_' + '0' * 64
    uninstall_plan_id = 'uninstall_plan_' + '0' * 32
    review_digest = 'sha256:' + '0' * 64
    startup_operation_id = 'startup_control_' + '0' * 32
    task_path = r'\ShouContractFixture\Task'
    history = run(['capabilities', '--command', 'history', '--json'])['data']['commands']
    assert {command['command'] for command in history} == {'history list', 'history show', 'history inspect'}
    assert all(command['side_effect'] == 'read' for command in history)
    assert capabilities['limits']['history_directory_entries'] == 4096
    assert capabilities['limits']['history_list_bytes'] == 33_554_432
    applications = run(['capabilities', '--command', 'applications', '--json'])['data']['commands']
    assert {command['command']: command['side_effect'] for command in applications} == {
        'applications summary': 'read', 'applications inspect': 'read', 'applications plan': 'plan', 'applications plan show': 'read',
        'applications uninstall': 'destructive', 'applications execution show': 'read'}
    assert capabilities['limits']['application_entries'] == 4000 and capabilities['limits']['application_seconds_max'] == 60
    assert capabilities['limits']['application_activity_entries'] == 20000 and capabilities['limits']['application_activity_seconds'] == 10
    assert capabilities['limits']['application_activity_depth'] == 32 and capabilities['limits']['application_executable_names'] == 128
    startup = run(['capabilities', '--command', 'startup', '--json'])['data']['commands']
    assert {command['command']: command['side_effect'] for command in startup} == {
        'startup list': 'read', 'startup inspect': 'read', 'startup control': 'destructive', 'startup execution show': 'read'}
    assert 'boot/logon scheduled tasks' in startup[0]['description']
    assert 'current-user packaged startup declarations' in startup[0]['description']
    assert 'Task Scheduler enablement and engine state when observed' in startup[0]['description']
    assert capabilities['limits']['startup_entries'] == 2000 and capabilities['limits']['startup_entries_max'] == 10000
    assert capabilities['limits']['startup_seconds'] == 5 and capabilities['limits']['startup_seconds_max'] == 60
    assert capabilities['limits']['startup_task_xml_characters'] == 262144 and capabilities['limits']['startup_task_folder_depth'] == 32
    assert capabilities['limits']['startup_manifest_bytes'] == 4194304
    for arguments in [
        ['privacy', 'scan', '--range', 'today'],
        ['privacy', 'scan', '--path', 'C:/Browser'],
        ['privacy', 'scan', '--range', 'last-hour', '--range', 'all-time'],
        ['privacy', 'scan', '--yes'],
        ['privacy', 'scan', 'show', '--scan-id', scan_id],
        ['privacy', 'scan', 'show', '--scan-id', '../escape'],
        ['privacy', 'scan', 'show', '--scan-id', privacy_scan_id, '--execute', 'true'],
        ['capabilities', '--yes'], ['plan', 'execute', '--yes'],
        ['startup', 'inspect'],
        ['startup', 'inspect', '--task-path', task_path],
        ['startup', 'inspect', '--task-path', task_path, '--action', 'run'],
        ['startup', 'inspect', '--task-path', r'\Folder\..\Task', '--action', 'enable'],
        ['startup', 'inspect', '--task-path', 'C:/Task', '--action', 'disable'],
        ['startup', 'inspect', '--task-path', task_path, '--action', 'enable', '--yes'],
        ['startup', 'control', '--task-path', task_path, '--action', 'enable'],
        ['startup', 'control', '--task-path', task_path, '--action', 'enable', '--review-digest', 'invalid'],
        ['startup', 'control', '--task-path', task_path, '--action', 'disable', '--review-digest', review_digest, '--yes'],
        ['startup', 'control', '--task-path', task_path, '--action', 'disable', '--review-digest', review_digest, '--approved', 'true'],
        ['startup', 'execution', 'show', '--startup-operation-id', '../escape'],
        ['startup', 'execution', 'show', '--startup-operation-id', startup_operation_id, '--retry', 'true'],
        ['startup', 'list', '--source', 'unknown'],
        ['startup', 'list', '--source', 'current-user-run', '--enable', 'true'],
        ['startup', 'list', '--search', 'x' * 257],
        ['startup', 'list', '--search', 'escape\x1b[31m'],
        ['startup', 'list', '--offset', '10001'],
        ['startup', 'list', '--limit', '0'],
        ['startup', 'list', '--limit', '501'],
        ['startup', 'list', '--max-entries', '0'],
        ['startup', 'list', '--max-entries', '10001'],
        ['startup', 'list', '--max-seconds', '0'],
        ['startup', 'list', '--max-seconds', '61'],
        ['applications', 'summary', '--sort', 'size'],
        ['applications', 'summary', '--offset', '-1'],
        ['applications', 'summary', '--offset', '20001'],
        ['applications', 'summary', '--limit', '0'],
        ['applications', 'summary', '--limit', '501'],
        ['applications', 'summary', '--search', 'x' * 257],
        ['applications', 'summary', '--search', 'escape\x1b[31m'],
        ['applications', 'summary', '--max-entries', '20001'],
        ['applications', 'summary', '--max-seconds', '61'],
        ['applications', 'summary', '--uninstall', 'true'],
        ['applications', 'inspect'],
        ['applications', 'inspect', '--application-id', '../escape'],
        ['applications', 'inspect', '--application-id', application_id, '--execute', 'true'],
        ['applications', 'plan', '--application-id', application_id],
        ['applications', 'plan', '--application-id', application_id, '--review-digest', 'not-a-digest', '--allow-installer-data-changes', 'true'],
        ['applications', 'plan', '--application-id', application_id, '--review-digest', review_digest, '--allow-installer-data-changes', 'yes'],
        ['applications', 'plan', '--application-id', application_id, '--review-digest', review_digest, '--allow-installer-data-changes', 'true', '--yes'],
        ['applications', 'plan', 'show', '--uninstall-plan-id', '../escape'],
        ['applications', 'plan', 'show', '--uninstall-plan-id', uninstall_plan_id, '--execute', 'true'],
        ['applications', 'uninstall', '--uninstall-plan-id', '../escape'],
        ['applications', 'uninstall', '--uninstall-plan-id', uninstall_plan_id, '--yes'],
        ['applications', 'uninstall', '--uninstall-plan-id', uninstall_plan_id, '--approved', 'true'],
        ['applications', 'execution', 'show', '--uninstall-plan-id', '../escape'],
        ['applications', 'execution', 'show', '--uninstall-plan-id', uninstall_plan_id, '--retry', 'true'],
        ['capabilities', '--json', '--json'], ['capabilities', '--locale', 'unknown'],
        ['analysis', 'scan'], ['analysis', 'scan', '--path'],
        ['analysis', 'scan', '--path', 'C:/Work', '--path', 'C:/Elsewhere'],
        ['analysis', 'scan', '--path', 'C:/Work', '--max-seconds', 'not-a-number'],
        ['analysis', 'scan', '--path', 'C:/Work', '--max-entries', '0'],
        ['analysis', 'scan', '--path', 'C:/Work', '--unknown', 'value'],
        ['rules', 'schema', '--file', 'unused.json'],
        ['rules', 'catalog', '--workspace', '../escape'],
        ['system', 'locations', '--include-projects', 'yes'],
        ['system', 'scan', '--include-projects', '1'],
        ['system', 'scan', '--max-entries', '0'],
        ['system', 'locations', '--path', 'C:/Work'],
        ['rules', 'validate'], ['rules', 'validate', '--file'],
        ['rules', 'validate', '--file', ''],
        ['rules', 'validate', '--file', 'one.json', '--file', 'two.json'],
        ['rules', 'validate', '--file', 'one.json', '--enable'],
        ['capabilities', '--command', 'unknown'],
        ['capabilities', '--command', 'rules', '--command', 'analysis'],
        ['unknown', '--help'], ['rules', '--help', '--help'],
        ['workspaces', 'add', '--path', 'C:/Work'],
        ['workspaces', 'add', '--path', 'C:/Work', '--root-ref', 'Bad Root'],
        ['workspaces', 'add', '--path', 'C:/Work', '--root-ref', 'work', '--yes'],
        ['workspaces', 'list', '--workspace', workspace],
        ['workspaces', 'show', '--workspace', '../escape'],
        ['workspaces', 'remove', '--workspace', workspace, '--workspace', workspace],
        ['rules', 'enable', '--rule-id', 'dev.cache', '--workspace', workspace, '--version', 'latest'],
        ['rules', 'disable', '--rule-id', '../cache', '--workspace', workspace],
        ['rules', 'import', '--file', 'rule.json', '--enable'],
        ['rules', 'export', '--rule-id', 'dev.cache', '--output', 'arbitrary.json'],
        ['rules', 'preview', '--file', 'rule.json', '--workspace', workspace, '--max-seconds', '0'],
        ['rules', 'preview', '--file', 'rule.json', '--workspace', workspace, '--force'],
        ['scan', '--workspace', '../escape'],
        ['scan', '--workspace', workspace, '--file', 'rule.json'],
        ['scan', '--workspace', workspace, '--workspace', workspace],
        ['scan', '--workspace', workspace, '--max-entries', '0'],
        ['scan', '--workspace', workspace, '--max-seconds', 'not-a-number'],
        ['scan', '--workspace', workspace, '--max-depth', '65'],
        ['scan', '--workspace', workspace, '--yes'],
        ['exclusions', 'global', 'add', '--pattern', '**/keep', '--workspace', workspace],
        ['scan', 'results', '--scan-id', scan_id, '--limit', '501'],
        ['scan', 'results', '--scan-id', '../escape'],
        ['scan', 'results', '--scan-id', scan_id, '--cursor', 'x' * 513],
        ['plan', 'show', '--plan-id', '../escape'],
        ['plan', 'show', '--plan-id', plan_id, '--execute'],
        ['history', 'show', '--execution-id', '../escape'],
        ['history', 'inspect', '--execution-id', execution_id, '--max-seconds', '0'],
        ['history', 'inspect', '--execution-id', execution_id, '--max-entries', '1000001'],
        ['history', 'inspect', '--execution-id', execution_id, '--retry', 'true'],
        ['history', 'list', '--limit', '0'],
        ['history', 'list', '--limit', '501'],
        ['history', 'list', '--cursor', 'x' * 513],
        ['plan', 'create', '--scan-id', scan_id],
        ['plan', 'create', '--scan-id', scan_id, '--candidate', '../escape'],
        ['plan', 'create', '--scan-id', scan_id, '--candidate', candidate_id, '--candidate', candidate_id],
        ['plan', 'create', '--scan-id', scan_id, '--candidate', candidate_id, '--mode', 'auto'],
        ['plan', 'create', '--scan-id', scan_id, '--candidate', candidate_id, '--yes'],
        ['plan', 'execute', '--plan-id', plan_id, '--approved', 'true'],
    ]:
        assert run(arguments + ([] if '--json' in arguments else ['--json']), 2)['error']['code'] == 'invalid_argument'
    for path in ['C:relative', 'C:/Work/../outside', '//server/share', 'C:/Work/file:stream', 'C:/NUL.txt']:
        assert run(['analysis', 'scan', '--path', path, '--json'], 2)['error']['code'] == 'invalid_path'
    assert run(['exclusions', 'global', 'add', '--pattern', '../escape', '--json'], 2)['error']['code'] == 'invalid_rule'
    assert run(['workspaces', 'exclude', 'add', '--workspace', workspace, '--pattern', 'target', '--project', '../escape', '--json'], 2)['error']['code'] == 'invalid_path'
    if not capabilities['host_supported']:
        assert run(['analysis', 'scan', '--path', 'C:/Work', '--json'], 8)['error']['code'] == 'unsupported_platform'
        assert run(['rules', 'validate', '--file', 'C:/Work/rule.json', '--json'], 8)['error']['code'] == 'unsupported_platform'
        for arguments in [
            ['privacy', 'scan'],
            ['privacy', 'scan', '--range', 'last-hour'],
            ['privacy', 'scan', '--range', 'last-day'],
            ['privacy', 'scan', '--range', 'last-seven-days'],
            ['privacy', 'scan', '--range', 'all-time'],
            ['privacy', 'scan', 'show', '--scan-id', privacy_scan_id],
            ['startup', 'inspect', '--task-path', task_path, '--action', 'enable'],
            ['startup', 'control', '--task-path', task_path, '--action', 'disable', '--review-digest', review_digest],
            ['startup', 'execution', 'show', '--startup-operation-id', startup_operation_id],
            ['startup', 'list'], ['startup', 'list', '--source', 'current-user-run', '--search', 'Example', '--limit', '5'],
            ['startup', 'list', '--source', 'scheduled-tasks', '--limit', '5'],
            ['startup', 'list', '--source', 'packaged-startup-tasks', '--limit', '5'],
            ['applications', 'summary'],
            ['applications', 'summary', '--search', 'Example', '--sort', 'registered-size', '--offset', '1', '--limit', '5'],
            ['applications', 'inspect', '--application-id', application_id],
            ['applications', 'plan', '--application-id', application_id, '--review-digest', review_digest, '--allow-installer-data-changes', 'true'],
            ['applications', 'plan', 'show', '--uninstall-plan-id', uninstall_plan_id],
            ['applications', 'uninstall', '--uninstall-plan-id', uninstall_plan_id],
            ['applications', 'execution', 'show', '--uninstall-plan-id', uninstall_plan_id],
            ['system', 'locations'], ['system', 'locations', '--include-projects', 'true'],
            ['system', 'scan'], ['rules', 'catalog', '--workspace', workspace],
            ['workspaces', 'list'], ['workspaces', 'show', '--workspace', workspace],
            ['workspaces', 'add', '--path', 'C:/Work', '--root-ref', 'work'],
            ['workspaces', 'remove', '--workspace', workspace],
            ['workspaces', 'exclude', 'add', '--workspace', workspace, '--pattern', '**/keep'],
            ['workspaces', 'exclude', 'remove', '--workspace', workspace, '--pattern', '**/keep'],
            ['exclusions', 'list'], ['exclusions', 'global', 'add', '--pattern', '**/keep'],
            ['exclusions', 'global', 'remove', '--pattern', '**/keep'],
            ['rules', 'import', '--file', 'C:/Work/rule.json'], ['rules', 'list'],
            ['rules', 'show', '--rule-id', 'dev.cache'], ['rules', 'export', '--rule-id', 'dev.cache'],
            ['rules', 'enable', '--rule-id', 'dev.cache', '--workspace', workspace],
            ['rules', 'disable', '--rule-id', 'dev.cache', '--workspace', workspace],
            ['rules', 'preview', '--file', 'C:/Work/rule.json', '--workspace', workspace],
            ['scan', '--workspace', workspace],
            ['scan', 'results', '--scan-id', scan_id],
            ['plan', 'show', '--plan-id', plan_id],
            ['history', 'list'], ['history', 'show', '--execution-id', execution_id],
            ['history', 'inspect', '--execution-id', execution_id],
            ['plan', 'create', '--scan-id', scan_id, '--candidate', candidate_id, '--mode', 'permanent'],
            ['plan', 'execute', '--plan-id', plan_id],
        ]:
            assert run(arguments + ['--json'], 8)['error']['code'] == 'unsupported_platform'
        assert not data_directory.exists()
    else:
        assert run(['startup', 'control', '--task-path', task_path, '--action', 'enable', '--review-digest', review_digest, '--json'], 8)['error']['code'] == 'unsupported_capability'
        assert run(['startup', 'execution', 'show', '--startup-operation-id', startup_operation_id, '--json'], 5)['error']['code'] == 'not_found'
        assert not data_directory.exists()
        startup = run(['startup', 'list', '--max-entries', '1', '--limit', '1', '--json'], (0, 6))['data']
        assert len(startup['sources']) == 10 and len(startup['items']) <= 1
        assert sum(source['inspected_entries'] or 0 for source in startup['sources']) <= 1
        assert 'scheduled_boot_logon_tasks_visible_to_current_user_only' in startup['limitations']
        assert 'packaged_startup_declarations_only' in startup['limitations']
        assert all(item['enablement'] == 'unknown' and item['running_state'] == 'not_observed' and item['control_available'] is False for item in startup['items'])
        assert 'scheduled_task_state_is_not_startup_activation_or_process_state' in startup['limitations']
        for item in startup['items']:
            if item['scheduled_task'] is not None:
                assert item['source'] == 'scheduled_tasks'
                assert isinstance(item['scheduled_task']['enabled'], bool)
                assert item['scheduled_task']['state'] in ('unknown', 'disabled', 'queued', 'ready', 'running')
        assert not data_directory.exists()
        applications = run(['applications', 'summary', '--max-entries', '1', '--limit', '1', '--json'], (0, 6))['data']
        assert len(applications['sources']) == 4 and len(applications['items']) <= 1
        assert sum(source['inspected_entries'] or 0 for source in applications['sources']) <= 1
        assert 'uninstall_unavailable' in applications['limitations']
        assert not data_directory.exists()
        assert run(['applications', 'plan', 'show', '--uninstall-plan-id', uninstall_plan_id, '--json'], 5)['error']['code'] == 'not_found'
        assert run(['applications', 'execution', 'show', '--uninstall-plan-id', uninstall_plan_id, '--json'], 5)['error']['code'] == 'not_found'
        assert run(['applications', 'uninstall', '--uninstall-plan-id', uninstall_plan_id, '--json'], 8)['error']['code'] == 'unsupported_capability'
        assert run(['applications', 'plan', '--application-id', application_id, '--review-digest', review_digest,
                    '--allow-installer-data-changes', 'false', '--json'], 7)['error']['code'] == 'installer_data_consent_required'
        assert not data_directory.exists()
        example = json.loads((ROOT / 'examples/rules/rust-target.rule.json').read_text())
        example['platforms'] = ['windows']
        rule_path = relocated / '规则 with spaces.json'
        rule_path.write_text(json.dumps(example, ensure_ascii=False), encoding='utf-8')
        validation = run(['rules', 'validate', '--file', str(rule_path), '--json'])['data']
        assert validation['valid'] and not validation['runtime_verified']
        assert validation['rule_id'] == example['id']
        assert run(['workspaces', 'list', '--json'])['data'] == []
        assert run(['rules', 'list', '--json'])['data']['bindings'] == []
        empty_history = run(['history', 'list', '--json'])['data']
        assert empty_history['state'] == 'complete' and empty_history['entries'] == []
        assert empty_history['issues'] == [] and empty_history['total_count'] == 0
        assert run(['history', 'show', '--execution-id', execution_id, '--json'], 5)['error']['code'] == 'not_found'
        assert run(['history', 'inspect', '--execution-id', execution_id, '--json'], 5)['error']['code'] == 'not_found'
        assert run(['plan', 'show', '--plan-id', plan_id, '--json'], 5)['error']['code'] == 'not_found'
        assert not data_directory.exists()
        root = Path(directory) / '工作区 with spaces'
        root.mkdir()
        (root / 'Cargo.toml').write_text('[package]\nname="fixture"\n', encoding='utf-8')
        target = root / 'target'
        target.mkdir()
        cache = target / 'cache.bin'
        cache.write_bytes(b'fixture bytes')
        registered = run(['workspaces', 'add', '--path', str(root), '--root-ref', 'developer-workspaces', '--json'])['data']
        workspace = registered['id']
        assert run(['workspaces', 'show', '--workspace', workspace, '--json'])['data']['accessible']
        builtins = run(['rules', 'catalog', '--workspace', workspace, '--json'])['data']
        assert len(builtins) == 16
        initial_scan = run(['scan', '--workspace', workspace, '--json'])['data']
        assert any(rule['rule_id'] == 'shou.builtin.rust-target' for rule in initial_scan['rules'])
        assert initial_scan['candidate_count'] >= 1
        for rule in builtins:
            run(['rules', 'disable', '--rule-id', rule['id'], '--version', rule['version'], '--workspace', workspace, '--json'])
        example['conditions'] = {'min_allocated_bytes': 0}
        rule_path.write_text(json.dumps(example, ensure_ascii=False), encoding='utf-8')
        imported = run(['rules', 'import', '--file', str(rule_path), '--json'])['data']
        assert imported['provenance'] == 'local_file'
        assert all(binding['enabled'] is False for binding in run(['rules', 'list', '--json'])['data']['bindings'])
        assert run(['rules', 'export', '--rule-id', example['id'], '--json'])['data'] == example
        unbound = run(['scan', '--workspace', workspace, '--json'])['data']
        assert unbound['rules'] == [] and unbound['candidate_count'] == 0 and unbound['preview_only'] is False
        preview = run(['rules', 'preview', '--file', str(rule_path), '--workspace', workspace, '--json'])['data']
        assert preview['candidate_count'] == 1 and preview['preview_only'] is True
        assert preview['rules'] == [{'rule_id': example['id'], 'digest': imported['digest']}]
        binding = run(['rules', 'enable', '--rule-id', example['id'], '--workspace', workspace, '--json'])['data']
        assert binding['enabled'] and binding['digest'] == imported['digest']
        preview = run(['rules', 'preview', '--file', str(rule_path), '--workspace', workspace, '--json'])['data']
        assert preview['candidate_count'] == 1 and preview['execution_available'] is False and preview['preview_only'] is True
        results = run(['scan', 'results', '--scan-id', preview['scan_id'], '--limit', '1', '--json'])['data']
        assert results['candidates'][0]['state'] == 'review' and results['execution_available'] is False
        assert results['configuration_revision'] == preview['configuration_revision']
        assert results['preview_only'] is True
        scan = run(['scan', '--workspace', workspace, '--json'])['data']
        assert scan['rules'] == preview['rules'] and scan['candidate_count'] == 1 and scan['preview_only'] is False
        scan_results = run(['scan', 'results', '--scan-id', scan['scan_id'], '--json'])['data']
        assert scan_results['preview_only'] is False and scan_results['execution_available'] is False
        selected = scan_results['candidates'][0]['id']
        plan = run(['plan', 'create', '--scan-id', scan['scan_id'], '--candidate', selected, '--mode', 'permanent', '--json'])['data']
        plan_id = plan['id']
        assert plan['action'] == 'permanent' and len(plan['items']) == 1
        assert run(['plan', 'show', '--plan-id', plan_id, '--json'])['data']['digest'] == plan['digest']
        assert run(['plan', 'execute', '--plan-id', plan_id, '--json'], 8)['error']['code'] == 'unsupported_capability'
        assert run(['history', 'list', '--json'])['data']['entries'] == []
        assert run(['plan', 'create', '--scan-id', scan['scan_id'], '--candidate', selected, '--json'], 8)['error']['code'] == 'unsupported_capability'
        draft_candidate = results['candidates'][0]['id']
        assert run(['plan', 'create', '--scan-id', preview['scan_id'], '--candidate', draft_candidate, '--mode', 'permanent', '--json'], 4)['error']['code'] == 'preview_only'
        second = {**example, 'id': 'dev.another-cache'}
        second_path = relocated / 'second.rule.json'
        second_path.write_text(json.dumps(second, ensure_ascii=False), encoding='utf-8')
        second_import = run(['rules', 'import', '--file', str(second_path), '--json'])['data']
        run(['rules', 'enable', '--rule-id', second['id'], '--workspace', workspace, '--json'])
        multi = run(['scan', '--workspace', workspace, '--json'])['data']
        assert multi['candidate_count'] == 2 and multi['preview_only'] is False
        assert {rule['rule_id']: rule['digest'] for rule in multi['rules']} == {
            example['id']: imported['digest'], second['id']: second_import['digest']}
        run(['rules', 'disable', '--rule-id', second['id'], '--workspace', workspace, '--json'])
        partial = run(['rules', 'preview', '--file', str(rule_path), '--workspace', workspace, '--max-entries', '2', '--json'], 6)['data']
        assert partial['state'] == 'partial' and partial['tree_complete'] is False
        partial_results = run(['scan', 'results', '--scan-id', partial['scan_id'], '--json'], 6)['data']
        assert partial_results['state'] == 'partial' and partial_results['execution_available'] is False
        run(['exclusions', 'global', 'add', '--pattern', '**/cache.bin', '--json'])
        blocked = run(['rules', 'preview', '--file', str(rule_path), '--workspace', workspace, '--json'])['data']
        blocked_results = run(['scan', 'results', '--scan-id', blocked['scan_id'], '--json'])['data']
        assert 'excluded' in blocked_results['candidates'][0]['blocked_reasons']
        run(['exclusions', 'global', 'remove', '--pattern', '**/cache.bin', '--json'])
        example['conditions']['min_allocated_bytes'] = 1
        rule_path.write_text(json.dumps(example, ensure_ascii=False), encoding='utf-8')
        assert run(['rules', 'import', '--file', str(rule_path), '--json'], 4)['error']['code'] == 'version_conflict'
        assert run(['rules', 'disable', '--rule-id', example['id'], '--workspace', workspace, '--json'])['data']['enabled'] is False
        disabled = run(['scan', '--workspace', workspace, '--json'])['data']
        assert disabled['candidate_count'] == 0 and disabled['rules'] == []
        run(['workspaces', 'remove', '--workspace', workspace, '--json'])
        assert run(['workspaces', 'list', '--json'])['data'] == []
        assert run(['rules', 'list', '--json'])['data']['bindings'] == []
        assert cache.read_bytes() == b'fixture bytes'
        assert len(run(['rules', 'list', '--json'])['data']['rules']) == 2
        assert run(['plan', 'show', '--plan-id', plan_id, '--json'])['data']['digest'] == plan['digest']
        rule_path.write_text('{}', encoding='utf-8')
        assert run(['rules', 'validate', '--file', str(rule_path), '--json'], 2)['error']['code'] == 'invalid_rule'
        rule_path.write_bytes(b' ' * 262_145)
        assert run(['rules', 'validate', '--file', str(rule_path), '--json'], 6)['error']['code'] == 'resource_limit'

    dependencies = json.loads((relocated / 'shou.deps.json').read_text())['libraries']
    assert not any('windowsappsdk' in name.lower() or 'presentation' in name.lower() for name in dependencies)

print(f'{checks} .NET CLI contract checks passed, including relocation and unsupported-path refusal. Native filesystem acceptance is separate.')
