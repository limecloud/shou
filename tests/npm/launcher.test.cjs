'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, symlinkSync, cpSync, realpathSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join, resolve } = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { once } = require('node:events');
const { platforms, resolveNative } = require('../../packages/shou-npm/lib/launcher.cjs');

const source = resolve(__dirname, '../../packages/shou-npm');
const version = '1.2.3-test.1';
function json(path, value) { writeFileSync(path, JSON.stringify(value)); }

function fixture(t) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'shou npm 路径 ')));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const dependencies = Object.fromEntries(Object.values(platforms).map(name => [name, version]));
  json(join(root, 'package.json'), { name: '@limecloud/shou', version, optionalDependencies: dependencies });
  const directories = {};
  for (const [target, name] of Object.entries(platforms)) {
    const [platform, arch] = target.split('-');
    const directory = join(root, 'node_modules', name);
    directories[target] = directory;
    mkdirSync(join(directory, 'vendor'), { recursive: true });
    json(join(directory, 'package.json'), { name, version, os: [platform], cpu: [arch],
      exports: { './package.json': './package.json', './payload.json': './payload.json' } });
    json(join(directory, 'payload.json'), { schema_version: 1, version, platform, arch,
      executable: platform === 'win32' ? 'vendor/shou.exe' : 'vendor/shou' });
    if (platform === 'darwin') {
      writeFileSync(join(directory, 'vendor/shou'), '#!/usr/bin/env node\nconsole.log(JSON.stringify({args:process.argv.slice(2),cwd:process.cwd()}));\n', { mode: 0o755 });
      for (const bundle of ['Shou_ShouCore.bundle', 'Shou_ShouContracts.bundle', 'Shou_ShouAgentSupport.bundle']) mkdirSync(join(directory, 'vendor', bundle));
    } else {
      for (const file of ['shou.exe', 'shou.dll', 'shou.deps.json', 'shou.runtimeconfig.json', 'coreclr.dll', 'hostfxr.dll',
        'hostpolicy.dll', 'System.Private.CoreLib.dll', 'Shou.Windows.Core.dll', 'Shou.Windows.Platform.dll']) writeFileSync(join(directory, 'vendor', file), 'fixture');
    }
  }
  return { root, directories };
}

for (const target of Object.keys(platforms)) {
  test(`select exact installed payload for ${target}`, t => {
    const { root, directories } = fixture(t);
    const [platform, arch] = target.split('-');
    const executable = resolveNative(root, { platform, arch, release: platform === 'darwin' ? '23.0.0' : '10.0.22000' });
    assert.equal(executable, join(directories[target], 'vendor', platform === 'darwin' ? 'shou' : 'shou.exe'));
  });
}

test('reject unsupported platforms, process architectures and older operating systems', t => {
  const { root } = fixture(t);
  for (const host of [
    { platform: 'linux', arch: 'x64', release: '6.0' },
    { platform: 'win32', arch: 'ia32', release: '10.0.22000' },
    { platform: 'darwin', arch: 'arm64', release: '22.9.0' },
    { platform: 'win32', arch: 'arm64', release: '10.0.21999' },
    { platform: 'win32', arch: 'arm64', release: 'unknown' },
  ]) assert.throws(() => resolveNative(root, host), /Unsupported|requires/);
});

const mac = { platform: 'darwin', arch: 'arm64', release: '23.0.0' };
test('missing optional dependencies give an exact-version reinstall command without falling back', t => {
  const { root, directories } = fixture(t);
  rmSync(directories['darwin-arm64'], { recursive: true });
  assert.throws(() => resolveNative(root, mac), /shou-darwin-arm64@1\.2\.3-test\.1.*include=optional/);
});

test('only versions explicitly included by the public manifest can run', t => {
  const { root } = fixture(t);
  json(join(root, 'package.json'), { name: '@limecloud/shou', version, optionalDependencies: {} });
  assert.throws(() => resolveNative(root, mac), /does not include darwin\/arm64/);
});

test('reject mismatched version, payload platform, descriptor path and missing runtime', t => {
  const { root, directories } = fixture(t);
  const directory = directories['darwin-arm64'];
  const descriptor = JSON.parse(readFileSync(join(directory, 'payload.json')));
  for (const patch of [{ version: '1.2.2' }, { platform: 'win32' }, { executable: '../../outside' }]) {
    json(join(directory, 'payload.json'), { ...descriptor, ...patch });
    assert.throws(() => resolveNative(root, mac), /does not match/);
  }
  json(join(directory, 'payload.json'), descriptor);
  rmSync(join(directories['win32-arm64'], 'vendor/coreclr.dll'));
  assert.throws(() => resolveNative(root, { platform: 'win32', arch: 'arm64', release: '10.0.22000' }), /incomplete or invalid/);
});

test('native executables cannot resolve through a link outside the platform package', { skip: process.platform === 'win32' }, t => {
  const { root, directories } = fixture(t);
  const executable = join(directories['darwin-arm64'], 'vendor/shou');
  const outside = join(root, 'outside');
  writeFileSync(outside, 'fixture');
  rmSync(executable);
  symlinkSync(outside, executable);
  assert.throws(() => resolveNative(root, mac), /incomplete or invalid/);
});

function processFixture(t) {
  const { root } = fixture(t);
  const helper = join(root, 'helper.cjs');
  writeFileSync(helper, `
const fs = require('node:fs');
const mode = process.argv[2];
if (mode === 'echo') {
  console.log(JSON.stringify({ args: process.argv.slice(3), cwd: process.cwd(), input: fs.readFileSync(0, 'utf8') }));
  console.error('native stderr'); process.exit(6);
} else if (mode === 'cancel') {
  process.on('SIGTERM', () => { console.error('cancelled'); process.exit(130); });
  console.log('ready'); setInterval(() => {}, 1000);
} else if (mode === 'signal') { process.kill(process.pid, 'SIGTERM'); }
`);
  const runner = join(root, 'runner.cjs');
  writeFileSync(runner, `const { launch } = require(${JSON.stringify(join(source, 'lib/launcher.cjs'))}); launch(process.argv[2], process.argv.slice(3));`);
  return { root, helper, runner };
}

test('arguments, cwd, stdin, stdout, stderr and nonzero exit status are preserved without shell evaluation', t => {
  const { root, helper, runner } = processFixture(t);
  const args = ['a b', '你好', '"quoted"', "'single'", '$HOME', '$(exit 99)', '`exit 99`', '--json'];
  const result = spawnSync(process.execPath, [runner, process.execPath, helper, 'echo', ...args], { cwd: root, input: 'terminal input', encoding: 'utf8' });
  assert.equal(result.status, 6);
  assert.deepEqual(JSON.parse(result.stdout), { args, cwd: root, input: 'terminal input' });
  assert.equal(result.stderr, 'native stderr\n');
});

test('the public bin resolves its installed platform package', { skip: process.platform !== 'darwin' }, t => {
  const { root, directories } = fixture(t);
  cpSync(join(source, 'bin'), join(root, 'bin'), { recursive: true });
  cpSync(join(source, 'lib'), join(root, 'lib'), { recursive: true });
  const result = spawnSync(process.execPath, [join(root, 'bin/shou.cjs'), 'a b', '参数'], { cwd: root, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { args: ['a b', '参数'], cwd: root });
  assert.ok(directories[`darwin-${process.arch}`]);
});

test('spawn failures stay on stderr with exit one and leave JSON stdout empty', t => {
  const { root, runner } = processFixture(t);
  const result = spawnSync(process.execPath, [runner, join(root, 'missing.exe')], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
  assert.match(result.stderr, /Unable to start the native CLI/);
});

test('native termination signals remain signals', { skip: process.platform === 'win32' }, t => {
  const { helper, runner } = processFixture(t);
  const result = spawnSync(process.execPath, [runner, process.execPath, helper, 'signal'], { encoding: 'utf8' });
  assert.equal(result.signal, 'SIGTERM');
});

test('parent termination reaches the child and waits for its observed exit', { skip: process.platform === 'win32', timeout: 10000 }, async t => {
  const { helper, runner } = processFixture(t);
  const child = spawn(process.execPath, [runner, process.execPath, helper, 'cancel'], { stdio: ['pipe', 'pipe', 'pipe'] });
  t.after(() => child.kill('SIGKILL'));
  let stderr = '';
  child.stderr.on('data', bytes => { stderr += bytes; });
  const closed = once(child, 'close');
  await new Promise((resolveReady, reject) => {
    child.once('error', reject);
    child.stdout.once('data', bytes => bytes.toString().includes('ready') ? resolveReady() : reject(new Error('Unexpected native output')));
  });
  child.kill('SIGTERM');
  const [code, signal] = await closed;
  assert.equal(code, 130);
  assert.equal(signal, null);
  assert.equal(stderr, 'cancelled\n');
});
