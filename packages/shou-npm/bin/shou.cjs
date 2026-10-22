#!/usr/bin/env node
'use strict';

const { spawnSync } = require('node:child_process');
const { release } = require('node:os');
const { join } = require('node:path');

if (process.platform !== 'darwin' || !['arm64', 'x64'].includes(process.arch)
    || Number(release().split('.')[0]) < 23) {
  console.error('@limecloud/shou requires macOS 14 or later on Apple Silicon or Intel.');
  process.exit(1);
}

// Use the actual native path so SwiftPM can find its adjacent resource bundles.
const result = spawnSync(join(__dirname, '..', 'vendor', 'shou'), process.argv.slice(2), {
  stdio: 'inherit',
});

if (result.error) {
  console.error(`Unable to start Shou: ${result.error.message}`);
  process.exit(1);
}
if (result.signal) {
  process.kill(process.pid, result.signal);
} else {
  process.exit(result.status ?? 1);
}
