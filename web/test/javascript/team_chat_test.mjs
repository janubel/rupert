import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const source = readFileSync(new URL('../../app/javascript/controllers/team_chat_controller.js', import.meta.url), 'utf8')
  .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
  .replace('export default class', 'globalThis.TeamChat = class');
const context = { URL, document: { hidden: false } };
vm.createContext(context);
vm.runInContext(source, context);
const Chat = context.TeamChat;
const plain = (value) => JSON.parse(JSON.stringify(value));
const types = (parts) => plain(parts.map((part) => part.type));

test('paragraphs and lists', () => {
  const blocks = Chat.parseBlocks('Sales were up.\nCard was most of it.\n\n- Shopify: $120\n- Square: $80\n\n1. Open Sales\n2. Pick a day');
  assert.deepEqual(plain(blocks.map((block) => block.type)), ['p', 'ul', 'ol']);
  assert.equal(blocks[0].lines.length, 2);
  assert.deepEqual(plain(blocks[1].items), ['Shopify: $120', 'Square: $80']);
});

test('inline marks, mentions and links', () => {
  assert.deepEqual(types(Chat.parseInline('Ask **@rupert** or `sync`')), ['text', 'bold', 'text', 'code']);
  assert.deepEqual(types(Chat.parseInline('hey @rupert, sales?')), ['text', 'mention', 'text']);
  assert.deepEqual(types(Chat.parseInline('mail me@rupert.com')), ['text']);
  const same = Chat.parseInline('Open [Timesheets](/people/timesheets).');
  assert.equal(same[1].type, 'link');
  assert.equal(same[1].href, '/people/timesheets');
  assert.equal(same[1].external, undefined);
  const outside = Chat.parseInline('See https://example.com/a.');
  assert.equal(outside[1].href, 'https://example.com/a');
  assert.equal(outside[1].external, true);
  assert.equal(outside[2].text, '.');
});

test('a label never hides an outside address, and unsafe schemes stay text', () => {
  for (const hostile of ['[x](https://evil.example)', '[x](//evil.example/a)', '[x](javascript:alert(1))', 'javascript:alert(1)']) {
    for (const part of Chat.parseInline(hostile).filter((candidate) => candidate.type === 'link')) {
      // Same-site links may carry a label; an outside link always shows its own address.
      assert.ok(part.href.startsWith('/') ? !part.href.startsWith('//') : part.href === new URL(part.text).href, hostile);
    }
  }
  assert.equal(Chat.safeUrl('https://user:pw@evil.example'), null);
  assert.equal(Chat.safeUrl('javascript:alert(1)'), null);
});

test('local model @agents are highlighted as mentions when listed', () => {
  assert.deepEqual(types(Chat.parseInline('hey @gemma and @rupert', [], ['rupert', 'gemma'])), ['text', 'mention', 'text', 'mention']);
  assert.deepEqual(types(Chat.parseInline('hey @gemma', [])), ['text'], 'not a mention unless the agent exists');
  assert.deepEqual(types(Chat.parseInline('mail me@gemma.com', [], ['rupert', 'gemma'])), ['text']);
});

async function pollChange(before, after) {
  const chat = new Chat();
  chat.byId = new Map([[before.id, before]]);
  chat.since = '2026-10-22T12:00:00.000000Z';
  chat.query = () => '/messages';
  chat.fetchJson = async () => ({ now: '2026-10-22T12:00:01.000000Z', messages: [after] });
  chat.renderRooms = chat.setPins = chat.renderTyping = chat.applyPresence = () => {};
  const rendered = [];
  chat.render = () => rendered.push(chat.byId.get(after.id));
  await chat.poll();
  return rendered;
}

test('polling renders an action decision even when text and timestamps are unchanged', async () => {
  const before = { id: 1, body: 'Proposed.', status: 'pending', updated_at: '2026-10-22T12:00:00Z',
    actions: [{ id: 'a', status: 'proposed' }] };
  const after = { ...before, actions: [{ id: 'a', status: 'done', result: 'Created task #1' }] };
  const rendered = await pollChange(before, after);
  assert.equal(rendered.length, 1);
  assert.equal(rendered[0].actions[0].status, 'done');
});

test('polling renders completion even when the final text was already streamed', async () => {
  const before = { id: 1, body: 'Ready for approval.', status: 'pending', activity: null, updated_at: '2026-10-22T12:00:00Z' };
  const rendered = await pollChange(before, { ...before, status: 'done' });
  assert.equal(rendered.length, 1);
  assert.equal(rendered[0].status, 'done');
});

test('after a finished bot answer the bubbles become its Next questions, and go back otherwise', () => {
  const node = (tag) => ({ tag, children: [], dataset: {}, attrs: {}, className: '', textContent: '',
    setAttribute(name, value) { this.attrs[name] = value }, replaceChildren(...kids) { this.children = kids } });
  context.document.createElement = node;
  const row = node('div');
  const original = node('button');
  original.textContent = 'How did yesterday go?';
  row.children = [original];
  row.dataset.prefix = '@rupert ';
  const chat = Object.create(Chat.prototype);
  Object.defineProperty(chat, 'hasSuggestionsTarget', { value: true });
  Object.defineProperty(chat, 'suggestionsTarget', { value: row });
  const answer = { id: 7, kind: 'assistant', status: 'done', follow_ups: ['Which source sold the most?'] };

  chat.renderFollowUps([{ id: 6, kind: 'person' }, answer]);
  assert.equal(row.children[0].textContent, 'Next:');
  assert.equal(row.children[1].textContent, 'Which source sold the most?');
  assert.equal(row.children[1].dataset.text, '@rupert Which source sold the most?');
  assert.equal(row.attrs['aria-label'], 'Suggested next questions');

  chat.renderFollowUps([answer, { id: 8, kind: 'assistant', status: 'pending' }]);
  assert.equal(row.children.length, 1);
  assert.equal(row.children[0], original);
});

test('side panel: Rupert pages open in panel mode; chat pages and other sites stay normal links', () => {
  assert.equal(Chat.panelPath('/reports/sales?from=2026-10-01', 'https://rupert.test'), '/reports/sales?from=2026-10-01&panel=1');
  assert.equal(Chat.panelPath('/chat/admins', 'https://rupert.test'), null);
  assert.equal(Chat.panelPath('//evil.test/x', 'https://rupert.test'), null);
  assert.equal(Chat.panelPath('https://evil.test/x', 'https://rupert.test'), null);
});

test('side panel: CSV files become rows, with quoted commas and quotes', () => {
  assert.deepEqual(plain(Chat.parseCsv('\uFEFFItem,Note\r\n"Tea, green","He said ""hi"""\r\nMug,')),
    [['Item', 'Note'], ['Tea, green', 'He said "hi"'], ['Mug', '']]);
  assert.equal(Chat.parseCsv('a\nb\nc\n', 2).length, 2);
});

test('side panel: charts draw one bar per row and series, labels from the first column', () => {
  const spec = Chat.chartSpec(['Day', 'Store', 'Online'], [['Mon', '$10.00', 5], ['Tue', 20, '7']], 'bar_chart');
  assert.deepEqual(plain(spec.series), ['Store', 'Online']);
  assert.equal(spec.marks.filter((mark) => mark.tag === 'rect').length, 4);
  assert.equal(Chat.chartSpec(['Day', 'Sales'], [['Mon', 1], ['Tue', 2]], 'line_chart').marks.filter((mark) => mark.tag === 'polyline').length, 1);
  assert.equal(Chat.numberOf('−$1,200.50'), -1200.5);
  assert.equal(Chat.numberOf('n/a'), null);
});
