import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const source = readFileSync(new URL('../../app/javascript/controllers/ask_rupert_controller.js', import.meta.url), 'utf8')
  .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
  .replace('export default class', 'globalThis.AskRupert = class');
const context = {};
vm.createContext(context);
vm.runInContext(source, context);
const Ask = context.AskRupert;
// Values built inside the vm context are from another realm; compare them as plain data.
const plain = (value) => JSON.parse(JSON.stringify(value));

test('paragraphs, lists and inline marks are parsed without any HTML', () => {
  const blocks = Ask.parseBlocks('Open **Sync** first.\nThen look at `status`.\n\n1. Pick a source\n2. Read the row\n\n- one\n- two');
  assert.deepEqual(plain(blocks.map((block) => block.type)), ['p', 'ol', 'ul']);
  assert.equal(blocks[0].items.length, 2);
  assert.deepEqual(plain(blocks[0].items[0].map((part) => part.type)), ['text', 'bold', 'text']);
  assert.deepEqual(plain(blocks[0].items[1].map((part) => part.type)), ['text', 'code', 'text']);
  assert.equal(blocks[1].items.length, 2);
  assert.equal(blocks[2].items.length, 2);
});

test('only same-site links become links; everything else stays text', () => {
  const link = Ask.parseInline('See [Sync](/syncs) now');
  assert.deepEqual(plain(link.map((part) => part.type)), ['text', 'link', 'text']);
  assert.equal(link[1].href, '/syncs');
  for (const hostile of ['[x](https://evil.example)', '[x](//evil.example/a)', '[x](javascript:alert(1))', '[x](data:text/html,hi)']) {
    assert.ok(Ask.parseInline(hostile).every((part) => part.type === 'text'), hostile);
  }
});

test('markup in a reply is kept as plain text', () => {
  const parts = Ask.parseInline('<img src=x onerror=alert(1)> and <b>bold</b>');
  assert.equal(parts.length, 1);
  assert.equal(parts[0].type, 'text');
  assert.equal(parts[0].text, '<img src=x onerror=alert(1)> and <b>bold</b>');
});

test('empty and non-string input produce no blocks', () => {
  assert.deepEqual(plain(Ask.parseBlocks('')), []);
  assert.deepEqual(plain(Ask.parseBlocks(null)), []);
  assert.deepEqual(plain(Ask.parseBlocks('\n\n  \n')), []);
});
