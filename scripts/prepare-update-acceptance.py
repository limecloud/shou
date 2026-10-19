#!/usr/bin/env python3
"""Serve a signed local update for an isolated copy of the real desktop application."""
from functools import partial
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
import argparse
import json
import os
import plistlib
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('application', type=Path)
parser.add_argument('private_key', type=Path)
parser.add_argument('--installed-app', type=Path, help='Use an actual previous release for the installed copy.')
arguments = parser.parse_args()
source = arguments.application.resolve()
key = arguments.private_key.resolve()
installed_source = arguments.installed_app.resolve() if arguments.installed_app else source
new_version = plistlib.loads((source / 'Contents/Info.plist').read_bytes())['CFBundleVersion']
old_version = plistlib.loads((installed_source / 'Contents/Info.plist').read_bytes())['CFBundleVersion'] if arguments.installed_app else '0.0.9'
assert old_version != new_version, 'The installed and update versions must differ.'
root = Path(__file__).resolve().parents[1]
# Keep isolated application data outside privacy-protected source folders.
base = Path(tempfile.mkdtemp(prefix='shou-update-acceptance-')).resolve()
web = base / 'web'
web.mkdir()
server = HTTPServer(('127.0.0.1', 0), partial(SimpleHTTPRequestHandler, directory=str(web)))
feed = f'http://127.0.0.1:{server.server_port}/appcast.xml'
identifier = 'dev.limecloud.shou.update-acceptance-' + uuid.uuid4().hex[:8]
data_directory = base / 'store'
workspace = base / 'workspace'
target = workspace / 'project/target'
target.mkdir(parents=True)
(target / 'generated.bin').write_bytes(b'fixture' * 4096)
(workspace / 'project/Cargo.toml').write_text('[package]\nname = "ui-fixture"\n')
(workspace / 'project/main.rs').write_text('fn main() {}\n')
for directory, version, original in [('installed', old_version, installed_source), ('new', new_version, source)]:
    app = base / directory / 'Shou.app'
    app.parent.mkdir()
    subprocess.run(['ditto', str(original), str(app)], check=True)
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info.update(CFBundleIdentifier=identifier, CFBundleShortVersionString=version, CFBundleVersion=version,
                SUFeedURL=feed, SUEnableAutomaticChecks=False,
                LSEnvironment={'SHOU_DATA_DIR': str(data_directory)},
                NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
    info_path.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(base / 'new/Shou.app'), str(web / f'Shou-{new_version}.zip')], check=True)
tools = root / '.build/artifacts/sparkle/Sparkle/bin'
subprocess.run([str(tools / 'generate_appcast'), '--ed-key-file', str(key), '--download-url-prefix', f'http://127.0.0.1:{server.server_port}/',
                '--maximum-deltas', '0', '-o', str(web / 'appcast.xml'), str(web)], check=True)
subprocess.run([str(tools / 'sign_update'), '--ed-key-file', str(key), '--verify', str(web / 'appcast.xml')], check=True)
environment = os.environ | {'SHOU_DATA_DIR': str(data_directory)}
result = subprocess.run([str(source / 'Contents/Helpers/shou'), 'workspaces', 'add', '--path', str(workspace), '--root-ref', 'desktop-acceptance', '--json'],
                        env=environment, capture_output=True, text=True, check=True)
binding = json.loads(result.stdout)['data']
details = {'base': str(base), 'application': str(base / 'installed/Shou.app'), 'bundle_id': identifier,
           'installed_version': old_version, 'update_version': new_version,
           'feed': feed, 'workspace': str(workspace), 'workspace_id': binding['id'], 'store': str(data_directory)}
(base / 'acceptance.json').write_text(json.dumps(details, indent=2) + '\n')
print(json.dumps(details), flush=True)
print('Serving the generated signed update; stop this process after UI verification.', flush=True)
try:
    server.serve_forever()
finally:
    server.server_close()
