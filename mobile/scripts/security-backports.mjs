import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
const require = createRequire(new URL('../package.json', import.meta.url));
const manifest = JSON.parse(readFileSync(new URL('../security/backports.json', import.meta.url), 'utf8'));
const hash = text => createHash('sha256').update(text).digest('hex');
export function verifyBackports({ apply = false } = {}) {
  const writes = [];
  for (const change of manifest.changes) {
    const packageFile = require.resolve(`${change.package}/package.json`);
    const packageRoot = dirname(packageFile);
    if (JSON.parse(readFileSync(packageFile, 'utf8')).version !== change.version) throw new Error(`Review ${change.package} backport before using a different upstream version`);
    const target = resolve(packageRoot, change.path);
    if (!target.startsWith(packageRoot + sep)) throw new Error('Invalid security patch path');
    const current = existsSync(target) ? readFileSync(target, 'utf8') : null;
    if (current !== null && hash(current) === change.after_sha256) continue;
    if (!apply) throw new Error(`Security backport missing or altered: ${change.package}/${change.path}`);
    if ((current === null ? null : hash(current)) !== change.before_sha256) throw new Error(`Unrecognized upstream source: ${change.package}/${change.path}`);
    let patched = change.content;
    if (patched === undefined) {
      if (current.split(change.find).length !== 2) throw new Error('Patch context is not unique');
      patched = current.replace(change.find, change.replace);
    }
    if (hash(patched) !== change.after_sha256) throw new Error('Security patch checksum mismatch');
    writes.push([target, patched]);
  }
  for (const [target, content] of writes) writeFileSync(target, content);
  return manifest;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  verifyBackports({ apply: process.argv.includes('--apply') });
  console.log('Pinned braces/node-forge security backports verified.');
}
