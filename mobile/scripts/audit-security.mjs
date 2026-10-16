import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { verifyBackports } from './security-backports.mjs';
const manifest = verifyBackports();
const result = spawnSync(process.platform === 'win32' ? 'npm.cmd' : 'npm', ['audit', '--json'], { encoding: 'utf8', shell: process.platform === 'win32', maxBuffer: 10 * 1024 * 1024 });
if (result.error || ![0, 1].includes(result.status)) throw new Error('npm audit failed; security status is unknown');
const audit = JSON.parse(result.stdout);
if (audit.error || !audit.metadata?.vulnerabilities || !audit.vulnerabilities) throw new Error('Incomplete npm audit response');
const known = new Map(Object.entries(manifest.advisories).map(([name, url]) => [url, name]));
const rootsFor = (name, path = new Set()) => {
  if (path.has(name)) return new Set();
  const vulnerability = audit.vulnerabilities[name];
  if (!vulnerability || !Array.isArray(vulnerability.via)) throw new Error(`Unknown advisory chain: ${name}`);
  const roots = new Set();
  for (const via of vulnerability.via) {
    if (typeof via === 'string') {
      for (const root of rootsFor(via, new Set([...path, name]))) roots.add(root);
    } else {
      if (known.get(via.url) !== name || via.name !== name) throw new Error(`Unremediated advisory: ${via.url || name}`);
      roots.add(via.url);
    }
  }
  return roots;
};
for (const name of Object.keys(audit.vulnerabilities)) {
  if (rootsFor(name).size === 0) throw new Error(`Unexplained audit finding: ${name}`);
}
const report = { registry_findings: audit.metadata.vulnerabilities, verified_backported_advisories: [...new Set(Object.keys(audit.vulnerabilities).flatMap(name => [...rootsFor(name)]))], unremediated_advisories: 0 };
mkdirSync(new URL('../dist/', import.meta.url), { recursive: true });
writeFileSync(new URL('../dist/dependency-security.json', import.meta.url), JSON.stringify({ ...report, raw_npm_audit: audit }, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
