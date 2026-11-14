#!/usr/bin/env python3
"""Sign nested macOS code and notarize using an isolated CI keychain."""
import argparse
import base64
from contextlib import contextmanager
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import subprocess
import tempfile
import uuid

SIGNING_SECRETS = ('APPLE_CERTIFICATE', 'APPLE_CERTIFICATE_PASSWORD', 'APPLE_SIGNING_IDENTITY', 'APPLE_TEAM_ID')
NOTARY_SECRETS = ('APPLE_ID', 'APPLE_PASSWORD')
MACHO_MAGIC = {bytes.fromhex(value) for value in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def run(arguments, **kwargs):
    result = subprocess.run([str(value) for value in arguments], text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, **kwargs)
    if result.returncode:
        message = result.stdout
        for name in (*SIGNING_SECRETS, *NOTARY_SECRETS):
            if os.environ.get(name):
                message = message.replace(os.environ[name], '[REDACTED]')
        # CalledProcessError includes argv, which can contain keychain credentials.
        raise SystemExit(f'{Path(arguments[0]).name} failed ({result.returncode}):\n{message}')
    return result.stdout


def validate_environment(notary=False, environment=None):
    environment = os.environ if environment is None else environment
    required = SIGNING_SECRETS + (NOTARY_SECRETS if notary else ())
    missing = [name for name in required if not environment.get(name, '').strip()]
    if missing:
        raise SystemExit('Missing Apple secrets: ' + ', '.join(missing))
    team = environment['APPLE_TEAM_ID']
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise SystemExit('APPLE_TEAM_ID must be a ten-character team identifier')
    identity = environment['APPLE_SIGNING_IDENTITY']
    if not identity.startswith('Developer ID Application: ') or not identity.endswith(f'({team})'):
        raise SystemExit('A Developer ID Application identity from APPLE_TEAM_ID is required')
    try:
        certificate = base64.b64decode(environment['APPLE_CERTIFICATE'], validate=True)
    except ValueError:
        raise SystemExit('APPLE_CERTIFICATE must be single-line PKCS#12 base64') from None
    if not certificate:
        raise SystemExit('The signing certificate is empty')
    return certificate


def find_identity(keychain, name):
    output = run(['security', 'find-identity', '-v', '-p', 'codesigning', keychain])
    matches = re.findall(r'^\s*\d+\) ([A-Fa-f0-9]{40}) "' + re.escape(name) + r'"$', output, re.MULTILINE)
    if len(matches) != 1:
        raise SystemExit('The imported keychain must contain one matching identity and private key')
    return matches[0]


@contextmanager
def signing_environment(notary=False):
    certificate = validate_environment(notary)
    original = shlex.split(run(['security', 'list-keychains', '-d', 'user']))
    with tempfile.TemporaryDirectory(prefix='shou-apple-') as directory:
        temporary = Path(directory)
        keychain = temporary / 'signing.keychain-db'
        p12 = temporary / 'certificate.p12'
        p12.write_bytes(certificate)
        p12.chmod(0o600)
        password = secrets.token_urlsafe(32)
        try:
            run(['security', 'create-keychain', '-p', password, keychain])
            run(['security', 'set-keychain-settings', '-lut', '21600', keychain])
            run(['security', 'unlock-keychain', '-p', password, keychain])
            run(['security', 'list-keychains', '-d', 'user', '-s', keychain, *original])
            run(['security', 'import', p12, '-P', os.environ['APPLE_CERTIFICATE_PASSWORD'],
                 '-k', keychain, '-T', '/usr/bin/codesign', '-T', '/usr/bin/security'])
            run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, keychain])
            environment = dict(os.environ, SHOU_SIGNING_IDENTITY=find_identity(keychain, os.environ['APPLE_SIGNING_IDENTITY']),
                               SHOU_SIGNING_KEYCHAIN=str(keychain), SHOU_SIGNING_TIMESTAMP='required')
            if notary:
                run(['xcrun', 'notarytool', 'store-credentials', 'shou-notary', '--keychain', keychain,
                     '--apple-id', os.environ['APPLE_ID'], '--team-id', os.environ['APPLE_TEAM_ID'],
                     '--password', os.environ['APPLE_PASSWORD']])
                environment['SHOU_NOTARY_PROFILE'] = 'shou-notary'
            # Child build/package commands need keychain references, never raw credentials.
            for name in (*SIGNING_SECRETS, *NOTARY_SECRETS):
                if name != 'APPLE_TEAM_ID':
                    environment.pop(name, None)
            yield environment
        finally:
            try:
                run(['security', 'list-keychains', '-d', 'user', '-s', *original])
            finally:
                if keychain.exists():
                    run(['security', 'delete-keychain', keychain])


def signing_team():
    team = os.environ.get('APPLE_TEAM_ID', '')
    if not team:
        match = re.search(r'\(([A-Z0-9]{10})\)$', os.environ.get('SHOU_SIGNING_IDENTITY', ''))
        team = match[1] if match else ''
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise SystemExit('APPLE_TEAM_ID is required when signing by certificate fingerprint')
    return team


def macho(path):
    if path.is_symlink() or not path.is_file():
        return False
    with path.open('rb') as source:
        return source.read(4) in MACHO_MAGIC


def code_paths(app):
    # rglob does not traverse directory symlinks (including framework aliases).
    binaries = sorted((p for p in app.rglob('*') if macho(p)), key=str)
    bundles = sorted((p for p in app.rglob('*') if not p.is_symlink() and p.is_dir()
                      and p.suffix in {'.app', '.xpc', '.framework', '.bundle'}),
                     key=lambda p: (-len(p.parts), str(p)))
    return binaries, bundles


def verify_code(path, team, runtime=True, timestamp=True):
    run(['codesign', '--verify', '--strict', path])
    details = run(['codesign', '--display', '--verbose=4', path]).splitlines()
    if (f'TeamIdentifier={team}' not in details
            or not any(line.startswith('Authority=Developer ID Application:') for line in details)
            or (runtime and not any('flags=' in line and 'runtime' in line for line in details))
            or (timestamp and not any(line.startswith('Timestamp=') for line in details))):
        raise SystemExit(f'Invalid Developer ID team, hardened runtime or timestamp: {path}')


def verify_app(app, timestamp=True):
    team = signing_team()
    binaries, _ = code_paths(app)
    if not binaries:
        raise SystemExit('The app contains no native executables')
    for binary in binaries:
        verify_code(binary, team, timestamp=timestamp)
    run(['codesign', '--verify', '--deep', '--strict', app])
    verify_code(app, team, timestamp=timestamp)


def sign_app(app):
    identity = os.environ.get('SHOU_SIGNING_IDENTITY', '')
    if not identity or identity == '-':
        raise SystemExit('An explicit Developer ID signing identity is required')
    timestamp = os.environ.get('SHOU_SIGNING_TIMESTAMP', 'none') != 'none'
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info['ShouSigningMode'] = 'developer-id'
    info_path.write_bytes(plistlib.dumps(info))
    options = ['codesign', '--force', '--sign', identity, '--options', 'runtime',
               '--timestamp' if timestamp else '--timestamp=none', '--preserve-metadata=entitlements']
    if os.environ.get('SHOU_SIGNING_KEYCHAIN'):
        options += ['--keychain', os.environ['SHOU_SIGNING_KEYCHAIN']]
    binaries, bundles = code_paths(app)
    for binary in binaries:
        identifier = ['--identifier', 'dev.limecloud.shou.cli'] if binary == app / 'Contents/Helpers/shou' else []
        run([*options, *identifier, binary])
    # Sign Sparkle's helpers/XPC/updater before their enclosing framework and app.
    for bundle in [*bundles, app]:
        run([*options, bundle])
    verify_app(app, timestamp=timestamp)


def notarize(archive, evidence):
    profile, keychain = os.environ.get('SHOU_NOTARY_PROFILE'), os.environ.get('SHOU_SIGNING_KEYCHAIN')
    if not profile or not keychain:
        raise SystemExit('Notarization requires the isolated signing run --notarize context')
    if evidence.exists():
        raise SystemExit(f'Notarization evidence already exists; inspect the original submission: {evidence}')
    evidence.mkdir(parents=True)
    auth = ['--keychain-profile', profile, '--keychain', keychain, '--output-format', 'json']
    submission = json.loads(run(['xcrun', 'notarytool', 'submit', archive, *auth]))
    identifier = submission.get('id', '')
    try:
        uuid.UUID(identifier)
    except (ValueError, AttributeError):
        raise SystemExit('Apple did not return a valid notarization submission ID') from None
    (evidence / 'submission.json').write_text(json.dumps(submission, indent=2) + '\n')
    print(f'Apple notarization submission: {identifier}', flush=True)
    result = json.loads(run(['xcrun', 'notarytool', 'wait', identifier, *auth, '--timeout', '25m']))
    (evidence / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    if result.get('id') != identifier or result.get('status') != 'Accepted':
        raise SystemExit(f'Notarization was not accepted. Inspect existing submission {identifier}; do not resubmit blindly.')


def notarize_app(app, evidence):
    verify_app(app)
    with tempfile.TemporaryDirectory(prefix='shou-notarize-') as directory:
        archive = Path(directory) / 'Shou.zip'
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive])
        notarize(archive, evidence)
    run(['xcrun', 'stapler', 'staple', app])
    run(['xcrun', 'stapler', 'validate', app])
    run(['spctl', '--assess', '--type', 'execute', '--verbose=4', app])


def notarize_dmg(image, evidence):
    identity = os.environ.get('SHOU_SIGNING_IDENTITY')
    keychain = os.environ.get('SHOU_SIGNING_KEYCHAIN')
    if not identity or not keychain:
        raise SystemExit('DMG signing requires an isolated signing context')
    run(['codesign', '--force', '--sign', identity, '--keychain', keychain, '--timestamp', image])
    verify_code(image, signing_team(), runtime=False)
    notarize(image, evidence)
    run(['xcrun', 'stapler', 'staple', image])
    run(['xcrun', 'stapler', 'validate', image])
    run(['spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=4', image])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    check = commands.add_parser('check')
    check.add_argument('--notarize', action='store_true')
    execute = commands.add_parser('run')
    execute.add_argument('--notarize', action='store_true')
    execute.add_argument('command', nargs=argparse.REMAINDER)
    for name in ('sign-app', 'verify-app', 'verify-code', 'notarize-app', 'notarize-dmg'):
        command = commands.add_parser(name)
        command.add_argument('path', type=Path)
        if name.startswith('notarize-'):
            command.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'check':
        validate_environment(args.notarize)
    elif args.action == 'run':
        command = args.command[1:] if args.command[:1] == ['--'] else args.command
        if not command:
            parser.error('run requires a command after --')
        with signing_environment(args.notarize) as environment:
            raise SystemExit(subprocess.run(command, env=environment).returncode)
    elif args.action == 'sign-app':
        sign_app(args.path.resolve())
    elif args.action == 'verify-app':
        verify_app(args.path.resolve())
    elif args.action == 'verify-code':
        verify_code(args.path.resolve(), signing_team())
    elif args.action == 'notarize-app':
        notarize_app(args.path.resolve(), args.evidence.resolve())
    else:
        notarize_dmg(args.path.resolve(), args.evidence.resolve())


if __name__ == '__main__':
    main()
