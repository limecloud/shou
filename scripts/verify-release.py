#!/usr/bin/env python3
"""Inspect the actual distribution archives, native signatures, versions, and update URL."""
from pathlib import Path
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import xml.etree.ElementTree as ET

tag, output = sys.argv[1], Path(sys.argv[2]).resolve()
version = tag.removeprefix('v')
archive = output / f'Shou-{version}-macos-universal.zip'
image = output / f'Shou-{version}-macos-universal.dmg'
cli = output / f'shou-{version}-macos-universal.tar.gz'
namespace = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
item = ET.parse(output / 'appcast.xml').find('./channel/item')
assert item is not None
enclosure = item.find('enclosure')
assert enclosure is not None
assert enclosure.attrib['url'] == f'https://github.com/limecloud/shou/releases/download/{tag}/{archive.name}'
assert int(enclosure.attrib['length']) == archive.stat().st_size
assert enclosure.attrib.get(f'{{{namespace["sparkle"]}}}edSignature')
feed_version = item.find('sparkle:version', namespace)
assert feed_version is not None and feed_version.text == version


def verify_app(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleShortVersionString'] == info['CFBundleVersion'] == version
    assert info['SUFeedURL'] == 'https://github.com/limecloud/shou/releases/latest/download/appcast.xml'
    assert info['SURequireSignedFeed'] and info['SUVerifyUpdateBeforeExtraction']
    assert (app / 'Contents/Resources/LICENSE.txt').read_bytes() == Path('LICENSE').read_bytes()
    assert (app / 'Contents/Resources/Sparkle-LICENSE.txt').read_bytes() == Path('.build/artifacts/sparkle/Sparkle/LICENSE').read_bytes()
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    for relative in ('Contents/MacOS/Shou', 'Contents/Helpers/shou', 'Contents/Frameworks/Sparkle.framework/Sparkle'):
        architectures = subprocess.check_output(['lipo', '-archs', str(app / relative)], text=True).split()
        assert set(architectures) == {'arm64', 'x86_64'}, (relative, architectures)
    result = subprocess.check_output([str(app / 'Contents/Helpers/shou'), '--version'], text=True)
    assert result.startswith(f'shou {version} ')
    assert (app / 'Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app').is_dir()
    links = subprocess.check_output(['otool', '-L', str(app / 'Contents/MacOS/Shou')], text=True)
    assert '@rpath/Sparkle.framework/' in links


def verify_packaged_resource_lookup(executable, resources, base, app=None):
    # Distinct valid fixture catalogs prove that a relocated binary reads its
    # shipped resources even when the developer's SwiftPM build still exists.
    for name in ('builtin-rules.json', 'known-locations.json'):
        (resources / name).write_text('[]\n')
    if app:
        subprocess.run(['codesign', '--force', '--sign', '-', str(resources)], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    workspace = base / 'workspace'
    workspace.mkdir(parents=True)
    environment = os.environ | {'SHOU_DATA_DIR': str(base / 'store')}

    def run(*arguments):
        result = json.loads(subprocess.check_output([str(executable), *arguments, '--json'], env=environment))
        assert result['ok'], result
        return result['data']

    binding = run('workspaces', 'add', '--path', str(workspace), '--root-ref', 'resource-probe')
    assert run('locations', 'list') == [], 'Packaged scan locations were ignored'
    assert run('rules', 'catalog', '--workspace', binding['id']) == [], 'Packaged cleanup rules were ignored'
    assert run('rules', 'schema'), 'Packaged rule schema could not be loaded'


with tempfile.TemporaryDirectory(prefix='shou-distribution-') as directory:
    base = Path(directory).resolve()
    subprocess.run(['ditto', '-x', '-k', str(archive), str(base / 'zip')], check=True)
    verify_app(base / 'zip/Shou.app')
    with tarfile.open(cli) as package:
        assert all(not p.name.startswith('/') and '..' not in Path(p.name).parts for p in package)
        package.extractall(base / 'cli', filter='data')
    executable = base / 'cli/shou'
    assert set(subprocess.check_output(['lipo', '-archs', str(executable)], text=True).split()) == {'arm64', 'x86_64'}
    assert subprocess.check_output([str(executable), '--version'], text=True).startswith(f'shou {version} ')
    environment = os.environ | {'SHOU_DATA_DIR': str(base / 'store')}
    capabilities = json.loads(subprocess.check_output([str(executable), 'capabilities', '--json'], env=environment))
    assert capabilities['data']['application_version'] == version
    assert json.loads(subprocess.check_output([str(executable), 'rules', 'schema', '--json'], env=environment))['ok']
    verify_packaged_resource_lookup(executable, base / 'cli/Shou_ShouCore.bundle', base / 'cli-probe')
    probe = base / 'probe/Shou.app'
    subprocess.run(['ditto', str(base / 'zip/Shou.app'), str(probe)], check=True)
    probe_executable = probe / 'Contents/MacOS/Shou'
    shutil.copy2(probe / 'Contents/Helpers/shou', probe_executable)
    verify_packaged_resource_lookup(probe_executable, probe / 'Contents/Resources/Shou_ShouCore.bundle', base / 'app-probe', app=probe)
    mounted = plistlib.loads(subprocess.check_output(['hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', str(image)]))
    volume = next(Path(entry['mount-point']) for entry in mounted['system-entities'] if 'mount-point' in entry)
    try:
        verify_app(volume / 'Shou.app')
        assert (volume / 'Applications').is_symlink()
        assert (volume / 'Applications').readlink() == Path('/Applications')
    finally:
        subprocess.run(['hdiutil', 'detach', str(volume)], check=True)
print('Universal DMG, ZIP, standalone CLI, relocated application resources, bundled updater, versions, and feed verified.')
