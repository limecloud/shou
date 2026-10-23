'use strict';

const { spawn } = require('node:child_process');
const { readFileSync, realpathSync, statSync } = require('node:fs');
const { createRequire } = require('node:module');
const { release, constants } = require('node:os');
const { dirname, join, relative, isAbsolute, sep } = require('node:path');

const platforms = Object.freeze({
  'darwin-arm64': '@limecloud/shou-darwin-arm64',
  'darwin-x64': '@limecloud/shou-darwin-x64',
  'win32-arm64': '@limecloud/shou-win32-arm64',
  'win32-x64': '@limecloud/shou-win32-x64',
});
const macBundles = ['Shou_ShouCore.bundle', 'Shou_ShouContracts.bundle', 'Shou_ShouAgentSupport.bundle'];

function readJSON(path) { return JSON.parse(readFileSync(path, 'utf8')); }

function requireContained(root, path, directory = false) {
  const actual = realpathSync(path);
  const child = relative(root, actual);
  if (!child || child === '..' || child.startsWith(`..${sep}`) || isAbsolute(child)
      || !(directory ? statSync(actual).isDirectory() : statSync(actual).isFile())) {
    throw new Error('The native package has an invalid layout. Reinstall @limecloud/shou.');
  }
  return actual;
}

function resolveNative(packageRoot, host = { platform: process.platform, arch: process.arch, release: release() }) {
  const name = platforms[`${host.platform}-${host.arch}`];
  if (!name) throw new Error(`Unsupported system/Node architecture: ${host.platform}/${host.arch}. Use macOS or Windows with arm64 or x64 Node.js.`);
  const versionParts = host.release.split('.').map(Number);
  if (host.platform === 'darwin' && (!Number.isInteger(versionParts[0]) || versionParts[0] < 23)) {
    throw new Error('Shou requires macOS 14 or later.');
  }
  if (host.platform === 'win32' && (versionParts.length < 3 || !versionParts.slice(0, 3).every(Number.isInteger)
      || versionParts[0] < 10 || versionParts[0] === 10 && (versionParts[1] < 0 || versionParts[1] === 0 && versionParts[2] < 22000))) {
    throw new Error('Shou requires Windows 11, build 22000 or later.');
  }
  const manifestPath = join(packageRoot, 'package.json');
  const manifest = readJSON(manifestPath);
  if (manifest.optionalDependencies?.[name] !== manifest.version) {
    throw new Error(`${manifest.name}@${manifest.version} does not include ${host.platform}/${host.arch}. Check this version's supported platforms.`);
  }
  const resolveFromPackage = createRequire(manifestPath);
  let nativeManifestPath;
  let payloadPath;
  try {
    nativeManifestPath = resolveFromPackage.resolve(`${name}/package.json`);
    payloadPath = resolveFromPackage.resolve(`${name}/payload.json`);
  } catch {
    throw new Error(`Missing native package ${name}@${manifest.version}. Reinstall with "npm install --global --include=optional @limecloud/shou@${manifest.version}"; do not use --omit=optional.`);
  }
  const root = realpathSync(dirname(nativeManifestPath));
  requireContained(root, nativeManifestPath);
  requireContained(root, payloadPath);
  if (dirname(realpathSync(payloadPath)) !== root) throw new Error('The native package exports an invalid payload descriptor.');
  const nativeManifest = readJSON(nativeManifestPath);
  const payload = readJSON(payloadPath);
  const executableName = host.platform === 'win32' ? 'shou.exe' : 'shou';
  if (nativeManifest.name !== name || nativeManifest.version !== manifest.version
      || JSON.stringify(nativeManifest.os) !== JSON.stringify([host.platform])
      || JSON.stringify(nativeManifest.cpu) !== JSON.stringify([host.arch])
      || payload.schema_version !== 1 || payload.version !== manifest.version
      || payload.platform !== host.platform || payload.arch !== host.arch
      || payload.executable !== `vendor/${executableName}`) {
    throw new Error(`Native package ${name} does not match the launcher version/platform. Reinstall @limecloud/shou@${manifest.version}.`);
  }
  try {
    const executable = requireContained(root, join(root, 'vendor', executableName));
    if (host.platform === 'darwin') {
      for (const bundle of macBundles) requireContained(root, join(root, 'vendor', bundle), true);
    } else {
      for (const file of ['shou.dll', 'shou.deps.json', 'shou.runtimeconfig.json', 'coreclr.dll', 'hostfxr.dll',
        'hostpolicy.dll', 'System.Private.CoreLib.dll', 'Shou.Windows.Core.dll', 'Shou.Windows.Platform.dll']) {
        requireContained(root, join(root, 'vendor', file));
      }
    }
    return executable;
  } catch (error) {
    throw new Error(`Native package ${name} is incomplete or invalid. Reinstall @limecloud/shou@${manifest.version}.`, { cause: error });
  }
}

function launch(executable, args) {
  const child = spawn(executable, args, { stdio: 'inherit', shell: false, windowsHide: false });
  let failed = false;
  const handlers = new Map();
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    const handler = () => {
      // The Windows console delivers Ctrl+C to both processes; child.kill(SIGINT) would force termination.
      if (process.platform === 'win32' && signal === 'SIGINT') return;
      try { child.kill(signal); } catch { /* The child may have already exited. */ }
    };
    handlers.set(signal, handler);
    process.on(signal, handler);
  }
  const clearHandlers = () => { for (const [signal, handler] of handlers) process.removeListener(signal, handler); };
  child.once('error', error => {
    failed = true;
    clearHandlers();
    console.error(`shou: Unable to start the native CLI: ${error.message}`);
    process.exitCode = 1;
  });
  child.once('close', (code, signal) => {
    clearHandlers();
    if (failed) return;
    if (signal && process.platform !== 'win32') {
      try { process.kill(process.pid, signal); return; } catch { /* Retain a nonzero result if the signal is unavailable. */ }
    }
    process.exitCode = signal ? 128 + (constants.signals[signal] || 1) : code ?? 1;
  });
  return child;
}

module.exports = { platforms, resolveNative, launch };
