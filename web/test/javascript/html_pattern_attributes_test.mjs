// Every HTML `pattern` attribute in the views must be a regular expression that
// browsers accept. Browsers compile `pattern` with the `v` flag (unicodeSets),
// which is stricter than classic JavaScript regexes: an unescaped `-` inside a
// character class is a SyntaxError, so the constraint is silently dropped and
// the console logs an error. Node supports the same flag, so compile each one.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import assert from 'node:assert/strict';

const viewsDir = new URL('../../app/views/', import.meta.url).pathname;

function* erbFiles(dir) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) yield* erbFiles(path);
    else if (name.endsWith('.erb')) yield path;
  }
}

// Matches `pattern: 'x'`, `pattern: "x"`, `pattern="x"` and `pattern='x'`.
const attribute = /pattern(?:=|:\s*)(["'])((?:\\.|(?!\1).)*)\1/g;

const found = [];
for (const file of erbFiles(viewsDir)) {
  const source = readFileSync(file, 'utf8');
  for (const match of source.matchAll(attribute)) {
    // Ruby single-quoted strings keep `\-` literally, which is what we want;
    // double-quoted ones turn `\-` into `-`, so mirror that before compiling.
    const raw = match[2];
    const value = match[1] === '"' ? raw.replace(/\\(.)/g, '$1') : raw;
    found.push({ file: file.replace(viewsDir, ''), value });
  }
}

assert.ok(found.length >= 4, `expected to find pattern attributes in the views, found ${found.length}`);

for (const { file, value } of found) {
  assert.doesNotThrow(() => new RegExp(value, 'v'), `${file}: pattern "${value}" is not a valid v-flag regular expression`);
}

// Regression: an unescaped hyphen inside a class is exactly the mistake that
// shipped in the subdomain fields; make sure the check would catch it again.
assert.throws(() => new RegExp('[a-z0-9][a-z0-9-]*[a-z0-9]', 'v'));
assert.doesNotThrow(() => new RegExp('[a-z0-9][a-z0-9\\-]*[a-z0-9]', 'v'));
