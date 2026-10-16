#!/usr/bin/env node
// Validate the locked build against its installed SDK, not a mutable latest-patch feed.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(fileURLToPath(new URL('../mobile/', import.meta.url)));
const require = createRequire(resolve(root, 'package.json'));
const { satisfies, validRange } = require('semver');

export function validateSdk(declared, installed, bundled) {
  const failures = [];
  for (const [name, range] of Object.entries(declared)) {
    const version = installed[name];
    if (!validRange(range) || !version || !satisfies(version, range)) {
      failures.push(`${name}: installed ${version ?? 'missing'} does not satisfy manifest ${range}`);
    }
    if (name !== 'expo' && bundled[name] && !satisfies(version ?? '', bundled[name])) {
      failures.push(`${name}: installed ${version ?? 'missing'} does not satisfy pinned SDK ${bundled[name]}`);
    }
  }
  return failures;
}

const pkg = JSON.parse(readFileSync(resolve(root, 'package.json'), 'utf8'));
const bundled = require('expo/bundledNativeModules.json');
assert(Object.keys(bundled).length > 0, 'Installed Expo SDK compatibility map is empty');
const declared = { ...pkg.dependencies, ...pkg.devDependencies };
const installed = Object.fromEntries(Object.keys(declared).map(name => [name, require(`${name}/package.json`).version]));
if (process.argv.includes('--self-test')) {
  assert.deepEqual(validateSdk({ 'expo-crypto': '~58.0.6' }, { 'expo-crypto': '58.0.6' }, { 'expo-crypto': '~58.0.6' }), []);
  assert(validateSdk({ 'expo-crypto': '~58.0.6' }, { 'expo-crypto': '58.0.6' }, { 'expo-crypto': '~58.0.7' }).length > 0, 'SDK mismatch must fail');
  assert(validateSdk({ 'expo-crypto': '~58.0.6' }, {}, { 'expo-crypto': '~58.0.6' }).length > 0, 'Missing dependency must fail');
  console.log('Pinned SDK validation regressions passed');
} else {
  const failures = validateSdk(declared, installed, bundled);
  assert.equal(failures.length, 0, failures.join('\n'));
  console.log(`Pinned Expo ${installed.expo}: ${Object.keys(declared).length} declared packages validated`);
}
