import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { constants, generateKeyPairSync, privateEncrypt } from 'node:crypto';
import { createRequire } from 'node:module';
import { verifyBackports } from '../scripts/security-backports.mjs';
const require = createRequire(import.meta.url);
const braces = require('braces');
const forge = require('node-forge');

test('backports match the reviewed upstream versions and source hashes', () => {
  verifyBackports();
});

test('brace walkers reject adversarial nesting and cycles without stack exhaustion', () => {
  let ast = { type: 'text', value: 'a' };
  for (let i = 0; i < 2000; i++) ast = { type: 'root', nodes: [ast] };
  const cycle = { type: 'root', nodes: [] };
  cycle.nodes.push(cycle);
  for (const method of ['compile', 'expand', 'stringify']) {
    for (const input of [ast, cycle, '{'.repeat(2000) + 'a,b' + '}'.repeat(2000), '{'.repeat(2000) + 'a,b']) {
      assert.throws(() => braces[method](input), error => error instanceof SyntaxError && /nesting depth|Cyclic/.test(error.message), method);
    }
  }
});

test('normal Expo glob patterns still compile, expand and stringify', () => {
  assert.deepEqual(braces.expand('src/{ios,android}/{a,b}.ts'), ['src/ios/a.ts', 'src/ios/b.ts', 'src/android/a.ts', 'src/android/b.ts']);
  assert.equal(braces.compile('src/{ios,android}/*.ts'), 'src/(ios|android)/*.ts');
  assert.equal(braces.stringify(braces.parse('src/{ios,android}/*.ts')), 'src/{ios,android}/*.ts');
  assert.deepEqual(require('micromatch')(['src/a.ts', 'src/b.tsx', 'src/c.js'], 'src/*.{ts,tsx}'), ['src/a.ts', 'src/b.tsx']);
});

test('RSA verification accepts valid signatures and rejects hidden DigestAlgorithm data', () => {
  const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const key = forge.pki.publicKeyFromPem(publicKey.export({ type: 'spki', format: 'pem' }).toString());
  const signingKey = forge.pki.privateKeyFromPem(privateKey.export({ type: 'pkcs1', format: 'pem' }).toString());
  const md = forge.md.sha256.create().update('Rupert employee mobile verification', 'utf8');
  const digest = md.digest().getBytes();
  assert.equal(key.verify(digest, signingKey.sign(md)), true);
  assert.equal(key.verify(forge.md.sha256.create().update('different message').digest().getBytes(), signingKey.sign(md)), false);
  const { asn1 } = forge;
  const node = (type, constructed, value) => asn1.create(asn1.Class.UNIVERSAL, type, constructed, value);
  const oid = () => node(asn1.Type.OID, false, asn1.oidToDer(forge.pki.oids.sha256).getBytes());
  const nullNode = value => node(asn1.Type.NULL, false, value);
  const signedInfo = algorithmChildren => {
    const info = node(asn1.Type.SEQUENCE, true, [node(asn1.Type.SEQUENCE, true, algorithmChildren), node(asn1.Type.OCTETSTRING, false, digest)]);
    return privateEncrypt({ key: privateKey, padding: constants.RSA_PKCS1_PADDING }, Buffer.from(asn1.toDer(info).getBytes(), 'binary')).toString('binary');
  };
  assert.equal(key.verify(digest, signedInfo([oid()])), true, 'SHA-256 permits absent NULL');
  assert.equal(key.verify(digest, signedInfo([oid(), nullNode('')])), true);
  for (const children of [
    [oid(), nullNode(''), node(asn1.Type.OCTETSTRING, false, 'hidden bytes')],
    [oid(), nullNode('hidden bytes')]
  ]) {
    assert.throws(() => key.verify(digest, signedInfo(children)), /ASN\.1 object|DigestInfo/);
  }
});

test('Xcode generates unique project identifiers without the retired UUID dependency', () => {
  const xcode = require('xcode');
  assert.equal(require('xcode/package.json').dependencies.uuid, undefined);
  const project = xcode.project('/unused/test.pbxproj');
  project.hash = { project: { objects: {} } };
  const identifiers = Array.from({ length: 20 }, () => project.generateUuid());
  identifiers.forEach(id => assert.match(id, /^[A-F0-9]{24}$/));
  assert.equal(new Set(identifiers).size, identifiers.length);
});


test('installer fails closed on skipped, tampered or unknown upstream source', () => {
  const root = mkdtempSync(join(tmpdir(), 'rupert-security-'));
  try {
    const put = (relative, data) => { const path = join(root, relative); mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, data); };
    const manifest = JSON.parse(readFileSync(new URL('../security/backports.json', import.meta.url), 'utf8'));
    put('package.json', '{}');
    put('scripts/security-backports.mjs', readFileSync(new URL('../scripts/security-backports.mjs', import.meta.url)));
    put('security/backports.json', JSON.stringify(manifest));
    for (const change of manifest.changes) {
      put(`node_modules/${change.package}/package.json`, JSON.stringify({ version: change.version }));
      if (change.before_sha256 !== null) {
        const patched = readFileSync(require.resolve(`${change.package}/${change.path}`), 'utf8');
        put(`node_modules/${change.package}/${change.path}`, patched.replace(change.replace, change.find));
      }
    }
    const run = (...args) => spawnSync(process.execPath, [join(root, 'scripts/security-backports.mjs'), ...args], { encoding: 'utf8' });
    assert.notEqual(run().status, 0, 'skipping postinstall cannot pass verification');
    assert.equal(run('--apply').status, 0);
    assert.equal(run('--apply').status, 0, 'application is idempotent');
    assert.equal(run().status, 0);
    put('node_modules/braces/lib/compile.js', 'unrecognized source');
    assert.notEqual(run().status, 0, 'tampering cannot pass verification');
    assert.notEqual(run('--apply').status, 0, 'unknown source is never overwritten');
    assert.equal(readFileSync(join(root, 'node_modules/braces/lib/compile.js'), 'utf8'), 'unrecognized source');
  } finally { rmSync(root, { recursive: true, force: true }); }
});
