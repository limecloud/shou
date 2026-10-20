#!/usr/bin/env python3
"""Exercise the real CLI against temporary workspaces, with no controlling terminal."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import fcntl
import hashlib
import zipfile

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

    def run(*arguments, expected=0, env_override=None):
        global checks
        process = subprocess.run([str(binary), *arguments, '--json'], env=env_override or environment,
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                 start_new_session=True, timeout=30)
        accepted = (expected,) if isinstance(expected, int) else expected
        assert process.returncode in accepted, (arguments, process.returncode, process.stdout, process.stderr)
        envelope = json.loads(process.stdout)
        assert envelope['api_version'] == '1.0'
        assert envelope['ok'] == (process.returncode == 0), envelope
        assert 'error' in envelope and 'next_actions' in envelope
        checks += 1
        return envelope

    blocked_store = base / 'startup-store-file'
    blocked_store.write_text('preserve this file; startup discovery does not open a record store')
    startup_environment = dict(environment, SHOU_DATA_DIR=str(blocked_store))
    # Discovery remains usable even if the business record store is damaged.
    discovered = run('capabilities', env_override=startup_environment)['data']
    focused = run('capabilities', '--command', 'skills', env_override=startup_environment)['data']
    assert {item['command'] for item in focused['commands']} == {'skills list', 'skills read', 'skills install', 'skills export'}
    exact = run('capabilities', '--command', 'rules import', env_override=startup_environment)['data']
    assert [item['command'] for item in exact['commands']] == ['rules import']
    run('capabilities', '--command', 'unknown', expected=2, env_override=startup_environment)
    scoped_help = run('skills', '--help', env_override=startup_environment)['data']
    assert 'skills install' in scoped_help and 'applications uninstall' not in scoped_help
    assert run('skills', env_override=startup_environment)['data'] == scoped_help
    leaf_help = run('skills', 'read', '--help', env_override=startup_environment)['data']
    assert '--file' in leaf_help and 'skills install' not in leaf_help
    run('unknown', '--help', expected=2, env_override=startup_environment)
    assert not (base / 'store').exists()
    startup = run('startup', 'list', expected=(0, 6), env_override=startup_environment)['data']
    assert startup['scope'] == 'launchd_definitions' and startup['include_system'] is False
    assert len(startup['sources']) == 3
    assert all(not source['location']['system_owned'] for source in startup['sources'])
    assert startup['unavailable_sources'] == ['login_items', 'background_task_registrations', 'embedded_helpers']
    assert all(item['configured_state'] in {'unknown', 'enabled', 'disabled'}
               and item['runtime_state'] in {'unknown', 'loaded', 'running', 'not_loaded'}
               and item['control_capability'] == ('launchctl_user_agent' if item['source_id'] == 'macos.user_agents' else 'system_settings')
               and 'program_arguments' not in item and 'environment_variables' not in item for item in startup['items'])
    system_startup = run('startup', 'list', '--include-system', 'true', expected=(0, 6), env_override=startup_environment)['data']
    assert system_startup['include_system'] is True and len(system_startup['sources']) == 5
    assert sum(source['location']['system_owned'] for source in system_startup['sources']) == 2
    run('startup', 'list', '--include-system', 'yes', expected=2)
    run('startup', 'list', '--enable', 'true', expected=2)
    user_agent = next((item for item in startup['items'] if item['control_capability'] == 'launchctl_user_agent'), None)
    if user_agent:
        denied = run('startup', 'control', '--path', user_agent['path'], '--action', 'disable', expected=(2, 7))
        assert denied['error']['code'] == 'confirmation_required'
    run('startup', 'control', '--path', str(base / 'missing.plist'), '--action', 'disable', expected=2)
    assert blocked_store.read_text() == 'preserve this file; startup discovery does not open a record store'
    assert not (base / 'store').exists()

    # Skill discovery is independent of record-store availability and includes
    # every file required when the directory is copied into an agent's skills.
    skill = run('agent', 'skill', env_override=startup_environment)['data']
    skill_directory = Path(skill['directory'])
    assert skill['name'] == 'shou-rule-authoring'
    assert Path(skill['entrypoint']) == skill_directory / 'SKILL.md'
    assert skill['instructions'] == (root / 'skills/shou-rule-authoring/SKILL.md').read_text()
    assert run('skills', 'read', 'shou-rule-authoring', env_override=startup_environment)['data']['content'] == skill['instructions']
    for arguments in [('shou-rule-authoring', 'references/questionnaire.md'),
                      ('shou-rule-authoring/references/questionnaire.md',)]:
        content = run('skills', 'read', *arguments, env_override=startup_environment)['data']['content']
        assert content == (skill_directory / 'references/questionnaire.md').read_text()
    for arguments in [('unknown',), ('shou-rule-authoring', '../SKILL.md'),
                      ('shou-rule-authoring', 'SKILL.md', 'extra'),
                      ('shou-rule-authoring/SKILL.md', 'references/questionnaire.md'),
                      ('shou-rule-authoring', '--file', 'SKILL.md')]:
        run('skills', 'read', *arguments, expected=2, env_override=startup_environment)
    for relative in ('references/questionnaire.md', 'agents/openai.yaml'):
        assert (skill_directory / relative).read_bytes() == (root / 'skills/shou-rule-authoring' / relative).read_bytes()

    bundled_skills = run('skills', 'list', env_override=startup_environment)['data']
    assert len(bundled_skills) == 1 and bundled_skills[0]['name'] == skill['name']
    skill_files = bundled_skills[0]['files']
    assert set(skill_files) == {'SKILL.md', 'references/questionnaire.md', 'agents/openai.yaml'}
    for relative in skill_files:
        read = run('skills', 'read', '--file', relative, env_override=startup_environment)['data']
        assert read['file'] == relative and read['content'] == (skill_directory / relative).read_text()
    raw = subprocess.run([str(binary), 'skills', 'read'], env=startup_environment,
                         stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
    assert raw.returncode == 0 and raw.stdout == (skill_directory / 'SKILL.md').read_bytes()
    checks += 1
    for relative in ('../SKILL.md', '/etc/passwd', 'references/../SKILL.md', 'missing.md'):
        assert run('skills', 'read', '--file', relative, expected=2,
                   env_override=startup_environment)['error']['code'] == 'invalid_argument'
    assert run('skills', 'install', '--agent', 'workbuddy', expected=2,
               env_override=startup_environment)['error']['code'] == 'invalid_argument'

    # Every write stays in this fixture, never a real client's skills directory.
    skills_parent = base / 'agent-skills'
    installed = run('skills', 'install', '--agent', 'codex', '--directory', str(skills_parent),
                    env_override=startup_environment)['data']
    installed_directory = skills_parent / skill['name']
    assert installed['state'] == 'installed' and Path(installed['directory']) == installed_directory
    assert {p.relative_to(installed_directory).as_posix() for p in installed_directory.rglob('*') if p.is_file()} == set(skill_files) | {'.shou-skill-manifest.json'}
    for relative in skill_files:
        assert (installed_directory / relative).read_bytes() == (skill_directory / relative).read_bytes()
    current = run('skills', 'install', '--agent', 'codex', '--directory', str(skills_parent),
                  env_override=startup_environment)['data']
    assert current['state'] == 'already_current'
    local_content = b'Local instructions must be preserved.\n'
    (installed_directory / 'SKILL.md').write_bytes(local_content)
    conflict = run('skills', 'install', '--agent', 'codex', '--directory', str(skills_parent),
                   expected=4, env_override=startup_environment)
    assert conflict['error']['code'] == 'version_conflict'
    assert (installed_directory / 'SKILL.md').read_bytes() == local_content
    assert not list(skills_parent.glob('.shou-rule-authoring-*'))

    # A previous managed version can update, retaining an exact backup.
    manifest_path = installed_directory / '.shou-skill-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    manifest['files']['SKILL.md'] = 'sha256:' + hashlib.sha256(local_content).hexdigest()
    manifest_path.write_text(json.dumps(manifest))
    updated = run('skills', 'install', '--agent', 'codex', '--directory', str(skills_parent),
                  env_override=startup_environment)['data']
    assert updated['state'] == 'updated'
    backup = Path(updated['backup_directory'])
    assert backup.parent == skills_parent and (backup / 'SKILL.md').read_bytes() == local_content
    assert (installed_directory / 'SKILL.md').read_bytes() == (skill_directory / 'SKILL.md').read_bytes()
    claude = run('skills', 'install', '--agent', 'claude-code', '--directory', str(base / 'claude-skills'),
                 env_override=startup_environment)['data']
    assert claude['agent'] == 'claude-code' and claude['state'] == 'installed'

    outside = base / 'outside-skill-destination'
    outside.mkdir()
    linked_parent = base / 'linked-skills'
    linked_parent.symlink_to(outside, target_is_directory=True)
    assert run('skills', 'install', '--agent', 'codex', '--directory', str(linked_parent),
               expected=2, env_override=startup_environment)['error']['code'] == 'invalid_argument'
    destination_parent = base / 'linked-destination'
    destination_parent.mkdir()
    (destination_parent / skill['name']).symlink_to(outside, target_is_directory=True)
    run('skills', 'install', '--agent', 'codex', '--directory', str(destination_parent),
        expected=2, env_override=startup_environment)
    assert not list(outside.iterdir())
    (installed_directory / 'local-link').symlink_to(outside, target_is_directory=True)
    run('skills', 'install', '--agent', 'codex', '--directory', str(skills_parent),
        expected=4, env_override=startup_environment)
    assert (installed_directory / 'local-link').is_symlink()

    archive = base / 'shou-skill.zip'
    assert run('skills', 'export', '--output', str(archive),
               env_override=startup_environment)['data']['state'] == 'exported'
    with zipfile.ZipFile(archive) as package:
        names = {name for name in package.namelist() if not name.endswith('/')}
        assert names == {skill['name'] + '/' + relative for relative in skill_files}
        for relative in skill_files:
            assert package.read(skill['name'] + '/' + relative) == (skill_directory / relative).read_bytes()
    archive_bytes = archive.read_bytes()
    run('skills', 'export', '--output', str(archive), expected=4, env_override=startup_environment)
    assert archive.read_bytes() == archive_bytes
    run('skills', 'export', '--output', str(base / 'skill.txt'), expected=2, env_override=startup_environment)
    linked_archive = base / 'linked-skill.zip'
    linked_archive.symlink_to(archive)
    run('skills', 'export', '--output', str(linked_archive), expected=2, env_override=startup_environment)
    assert linked_archive.is_symlink() and archive.read_bytes() == archive_bytes
    assert blocked_store.read_text() == 'preserve this file; startup discovery does not open a record store'
    assert not (base / 'store').exists()

    applications = run('applications', 'list', expected=(0, 6), env_override=startup_environment)['data']
    assert applications['scope'] == 'application_directories'
    assert all(not source['source']['system_owned'] for source in applications['sources'])
    assert len(applications['sources']) == 2
    assert applications['unavailable_sources'] == ['other_accounts', 'custom_install_locations', 'package_receipts', 'embedded_helpers']
    run('applications', 'list', '--include-system', 'yes', expected=2)
    run('applications', 'uninstall', '--plan-id', 'missing', '--yes', 'true', expected=2)
    run('applications', 'plan', '--review-id', 'missing', '--component', 'missing', '--include-user-data', 'yes', expected=2)
    run('applications', 'inspect', '--path', str(workspace), '--max-entries', '0', expected=2)
    assert blocked_store.read_text() == 'preserve this file; startup discovery does not open a record store'

    capabilities = run('capabilities')['data']
    assert capabilities['platform'] == 'macos'
    assert all('side_effect' in entry and 'required' in entry for entry in capabilities['commands'])
    assert next(entry for entry in capabilities['commands'] if entry['command'] == 'agent skill')['side_effect'] == 'read'
    for command in ('skills list', 'skills read'):
        assert next(entry for entry in capabilities['commands'] if entry['command'] == command)['side_effect'] == 'read'
    for command in ('skills install', 'skills export'):
        assert next(entry for entry in capabilities['commands'] if entry['command'] == command)['side_effect'] == 'configuration'
    assert next(entry for entry in capabilities['commands'] if entry['command'] == 'applications uninstall')['side_effect'] == 'destructive'
    assert next(entry for entry in capabilities['commands'] if entry['command'] == 'applications plan')['repeated'] == ['component']
    startup_command = next(entry for entry in capabilities['commands'] if entry['command'] == 'startup list')
    assert startup_command['side_effect'] == 'read' and startup_command['optional'] == ['include-system']
    scan_command=next(entry for entry in capabilities['commands'] if entry['command'] == 'scan')
    assert scan_command['exactly_one'] == ['workspace', 'location']
    assert 'scope' in scan_command['optional']
    assert any(entry['command'] == 'system scan' for entry in capabilities['commands'])

    # Privacy discovery and invalid inputs never open real browser databases.
    privacy_specs = {
        'privacy scan': ('snapshot', [], ['range'], []),
        'privacy scan show': ('read', ['scan-id'], [], []),
        'privacy plan': ('plan', ['scan-id', 'source'], ['acknowledge-sign-out'], ['source']),
        'privacy plan show': ('read', ['plan-id'], [], []),
        'privacy execute': ('destructive', ['plan-id'], [], []),
        'privacy history': ('read', [], [], []),
    }
    privacy_discovery = run('capabilities', '--command', 'privacy',
                            env_override=startup_environment)['data']['commands']
    assert {entry['command'] for entry in privacy_discovery} == set(privacy_specs)
    for entry in privacy_discovery:
        side_effect, required, optional, repeated = privacy_specs[entry['command']]
        assert (entry['side_effect'], entry['required'], entry['optional'], entry['repeated']) == (
            side_effect, required, optional, repeated)
    privacy_help = run('privacy', '--help', env_override=startup_environment)['data']
    assert all(command in privacy_help for command in privacy_specs)
    assert 'applications uninstall' not in privacy_help
    assert run('privacy', env_override=startup_environment)['data'] == privacy_help
    for command in privacy_specs:
        help_text = run(*command.split(), '--help', env_override=startup_environment)['data']
        assert command in help_text
        if command == 'privacy scan':
            assert all(value in help_text for value in ('last-hour', 'last-day', 'last-seven-days', 'all-time'))
        elif command == 'privacy plan':
            assert 'Repeatable: --source' in help_text and '--acknowledge-sign-out' in help_text
        elif command == 'privacy execute':
            assert 'Permanently' in help_text and 'No Trash or restore capability' in help_text
    assert blocked_store.read_text() == 'preserve this file; startup discovery does not open a record store'

    privacy_store = base / 'privacy-store'
    privacy_environment = dict(environment, SHOU_DATA_DIR=str(privacy_store))
    assert run('privacy', 'history', env_override=privacy_environment)['data'] == []
    invalid_range = run('privacy', 'scan', '--range', 'invalid', expected=2,
                        env_override=privacy_environment)
    assert invalid_range['error']['code'] == 'invalid_argument'
    assert invalid_range['error']['message'] == 'Unknown privacy time range.'
    assert not list(privacy_store.rglob('*.json'))
    invalid_consent = run('privacy', 'plan', '--scan-id', 'missing',
                          '--source', 'source-one', '--source', 'source-two',
                          '--acknowledge-sign-out', 'yes', expected=2,
                          env_override=privacy_environment)
    assert invalid_consent['error']['code'] == 'invalid_argument'
    assert invalid_consent['error']['message'] == 'acknowledge-sign-out must be true or false.'
    # Both distinct and duplicate source values are accepted as repeated options;
    # absent scan records are rejected before any source evidence can be accessed.
    for second_source in ('source-two', 'source-one'):
        missing_scan = run('privacy', 'plan', '--scan-id', 'missing',
                           '--source', 'source-one', '--source', second_source,
                           expected=2, env_override=privacy_environment)
        assert missing_scan['error']['code'] == 'invalid_argument'
        assert missing_scan['error']['message'] == 'Privacy record does not exist.'
    for arguments in (('scan', 'show', '--scan-id', 'missing'),
                      ('plan', 'show', '--plan-id', 'missing'),
                      ('execute', '--plan-id', 'missing')):
        missing_record = run('privacy', *arguments, expected=2, env_override=privacy_environment)
        assert missing_record['error']['code'] == 'invalid_argument'
        assert missing_record['error']['message'] == 'Privacy record does not exist.'
    assert run('privacy', 'execute', '--plan-id', 'missing', '--yes', 'true', expected=2,
               env_override=privacy_environment)['error']['code'] == 'invalid_argument'
    assert run('privacy', 'history', env_override=privacy_environment)['data'] == []
    assert not list(privacy_store.rglob('*.json'))

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
    assert any(entry['command'] == 'exclusions global add' for entry in capabilities['commands'])
    empty_exclusions = run('exclusions', 'list')['data']
    assert empty_exclusions['global_patterns'] == [] and empty_exclusions['effective_patterns'] == []
    run('exclusions', 'list', '--workspace', 'unknown-workspace', expected=2)
    run('workspaces', 'exclude', 'add', '--workspace', workspace_id, '--project', '../project', '--pattern', '**', expected=2)
    run('workspaces', 'exclude', 'add', '--workspace', workspace_id, '--project', 'project', '--pattern', '**')
    project_exclusions = run('exclusions', 'list', '--workspace', workspace_id)['data']
    assert project_exclusions['workspace_patterns'] == ['project/**']
    assert run('exclusions', 'global', 'add', '--pattern', '**/target/**')['data']['global_patterns'] == ['**/target/**']
    combined = run('exclusions', 'list', '--workspace', workspace_id)['data']
    assert combined['workspace_id'] == workspace_id
    assert combined['effective_patterns'] == ['project/**', '**/target/**']
    run('exclusions', 'global', 'add', '--pattern', '/outside', expected=2)
    blocked_scan = run('scan', '--workspace', workspace_id)['data']
    blocked_results = run('scan', 'results', '--scan-id', blocked_scan['scan_id'])['data']['candidates']
    blocked_target = next(item for item in blocked_results if item['relative_path'] == 'project/target')
    assert not blocked_target['eligible'] and 'excluded_descendant' in blocked_target['reasons']
    run('plan', 'create', '--scan-id', blocked_scan['scan_id'], '--candidate', blocked_target['id'], expected=2)
    assert run('exclusions', 'global', 'remove', '--pattern', '**/target/**')['data']['global_patterns'] == []
    assert run('exclusions', 'list', '--workspace', workspace_id)['data']['workspace_patterns'] == ['project/**']
    run('workspaces', 'exclude', 'remove', '--workspace', workspace_id, '--project', 'project', '--pattern', '**')
    assert run('exclusions', 'list', '--workspace', workspace_id)['data']['effective_patterns'] == []
    assert (artifacts / 'artifact.bin').read_bytes() == b'x' * 8192
    inspection_command = next(entry for entry in capabilities['commands'] if entry['command'] == 'history inspect')
    assert inspection_command['side_effect'] == 'read' and inspection_command['required'] == ['execution-id']
    run('history', 'inspect', '--execution-id', 'execution_missing', expected=2)
    run('history', 'inspect', '--execution-id', 'execution_missing', '--max-seconds', 'invalid', expected=2)
    saved_item = plan['items'][0]
    inspection_id = 'execution_cli_inspection'
    synthetic = {
        'id': inspection_id, 'plan_id': plan['id'], 'workspace': plan['workspace'],
        'created_at': plan['created_at'], 'entry_point': 'cli', 'state': 'executing',
        'items': [{'id': saved_item['id'], 'original_path': str(artifacts),
                   'relative_path': 'project/target', 'manifest': saved_item['manifest'],
                   'state': 'moving', 'allocated_bytes_estimate': 8192}]
    }
    history_directory = base / 'store/history'
    history_directory.mkdir(exist_ok=True, mode=0o700)
    receipt_path = history_directory / f'{inspection_id}.json'
    receipt_path.write_text(json.dumps(synthetic))
    receipt_path.chmod(0o600)
    before_inspection = receipt_path.read_bytes()
    inspected = run('history', 'inspect', '--execution-id', inspection_id)['data']
    assert inspected['unfinished'] and inspected['recorded_state'] == 'executing'
    assert inspected['items'][0]['state'] == 'verified_original'
    assert inspected['items'][0]['original']['state'] == 'matches'
    assert inspected['items'][0]['trash']['state'] == 'not_recorded'
    limited = run('history', 'inspect', '--execution-id', inspection_id, '--max-entries', '1', expected=6)
    assert limited['data']['status'] == 'partial'
    run('history', 'inspect', '--execution-id', inspection_id, '--max-entries', '0', expected=2)
    followup_directory = base / 'store/followups'
    followup_directory.mkdir(exist_ok=True, mode=0o700)
    followup_path = followup_directory / 'followup_cli_inspection.json'
    followup_path.write_text(json.dumps({'id': 'followup_cli_inspection', 'execution_id': inspection_id,
                                       'item_id': saved_item['id'], 'action': 'restore',
                                       'created_at': plan['created_at'], 'state': 'pending'}))
    followup_path.chmod(0o600)
    pending = run('history', 'inspect', '--execution-id', inspection_id, expected=6)['data']
    assert pending['unfinished'] and pending['items'][0]['state'] == 'needs_verification'
    with open(base / 'store/.mutation.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run('history', 'inspect', '--execution-id', inspection_id, expected=4)
        fcntl.flock(lock, fcntl.LOCK_UN)
    assert receipt_path.read_bytes() == before_inspection
    assert json.loads(followup_path.read_text())['state'] == 'pending'
    assert (artifacts / 'artifact.bin').read_bytes() == b'x' * 8192
    run('workspaces', 'remove', '--workspace', workspace_id)
    assert (artifacts / 'artifact.bin').exists()
    assert run('workspaces', 'list')['data'] == []
print(f'{checks} real CLI contract checks passed; no cleanup targets were modified.')
