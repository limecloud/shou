#!/usr/bin/env node
'use strict';

const { resolveNative, launch } = require('../lib/launcher.cjs');
const { resolve } = require('node:path');

try {
  const executable = resolveNative(resolve(__dirname, '..'));
  launch(executable, process.argv.slice(2));
} catch (error) {
  console.error(`shou: ${error.message}`);
  process.exit(1);
}
