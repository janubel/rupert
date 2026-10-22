import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const source = readFileSync(new URL('../../app/javascript/controllers/buzz_chat_controller.js', import.meta.url), 'utf8')
  .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
  .replace('export default class', 'globalThis.BuzzChat = class');
const context = { URL };
vm.createContext(context);
vm.runInContext(source, context);
const Chat = context.BuzzChat;
// Values built inside the vm context are from another realm; compare them as plain data.
const plain = (value) => JSON.parse(JSON.stringify(value));

test('bold, code and links are parsed without any HTML', () => {
  const parts = Chat.parseLine('See **this** and `that` at https://example.com/a?b=1.');
  assert.deepEqual(plain(parts.map((part) => part.type)), ['text', 'bold', 'text', 'code', 'text', 'link', 'text']);
  assert.equal(parts[5].href, 'https://example.com/a?b=1');
  assert.equal(parts[5].text, 'https://example.com/a?b=1');
  assert.equal(parts[6].text, '.');
});

test('only http and https links become links', () => {
  for (const hostile of ['javascript:alert(1)', 'data:text/html,hi', 'ftp://example.com/x', 'file:///etc/passwd']) {
    assert.ok(Chat.parseLine(hostile).every((part) => part.type === 'text'), hostile);
  }
  assert.equal(Chat.parseLine('https://user:pass@example.com/').every((part) => part.type === 'text'), true);
});

test('markup in a message stays plain text', () => {
  const parts = Chat.parseLine('<img src=x onerror=alert(1)> and <b>bold</b> [x](javascript:alert(1))');
  assert.equal(parts.length, 1);
  assert.equal(parts[0].type, 'text');
  assert.equal(parts[0].text, '<img src=x onerror=alert(1)> and <b>bold</b> [x](javascript:alert(1))');
});

test('trailing punctuation is not part of a link but balanced brackets are', () => {
  const wrapped = Chat.parseLine('(see https://example.com/x)');
  assert.equal(wrapped.find((part) => part.type === 'link').href, 'https://example.com/x');
  const wiki = Chat.parseLine('https://en.wikipedia.org/wiki/Rupert_(name)');
  assert.equal(wiki.find((part) => part.type === 'link').href, 'https://en.wikipedia.org/wiki/Rupert_(name)');
});

test('standalone image links are recognised, other links are not images', () => {
  assert.equal(Chat.imageUrl('https://example.com/a.png'), 'https://example.com/a.png');
  assert.equal(Chat.imageUrl('https://example.com/a.JPG?x=1'), 'https://example.com/a.JPG?x=1');
  assert.equal(Chat.imageUrl('https://example.com/a.svg'), null);
  assert.equal(Chat.imageUrl('javascript:alert(1)'), null);
  assert.equal(Chat.imageUrl('data:image/png;base64,abc'), null);
});

test('the typing row names people and says when Rupert is working', () => {
  assert.equal(Chat.typingLabel([]), '');
  assert.equal(Chat.typingLabel([{ name: 'Sam', agent: false }]), 'Sam is typing');
  assert.equal(Chat.typingLabel([{ name: 'Sam', agent: false }, { name: 'Ana', agent: false }]), 'Sam and Ana are typing');
  assert.equal(Chat.typingLabel([{ name: 'A' }, { name: 'B' }, { name: 'C' }, { name: 'D' }]), 'A, B and 2 more are typing');
  assert.equal(Chat.typingLabel([{ name: 'Rupert', agent: true }]), 'Rupert is working on a reply');
  assert.equal(Chat.typingLabel([{ name: 'Sam', agent: false }, { name: 'Rupert', agent: true }]), 'Sam is typing · Rupert is working on a reply');
  assert.equal(Chat.typingLabel([], true), 'Rupert is working on a reply', 'waiting for an answer after an @rupert mention');
  assert.equal(Chat.typingLabel(null), '');
});
