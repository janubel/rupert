import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const source = readFileSync(new URL('../../app/javascript/controllers/task_board_controller.js', import.meta.url), 'utf8')
  .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
  .replace('export default class', 'globalThis.TaskBoard = class');

function board(fetch) {
  const navigation = { reloads: 0, reload() { this.reloads++; } };
  const context = { fetch, window: { location: navigation }, document: { querySelector: () => ({ content: 'csrf' }) } };
  vm.createContext(context);
  vm.runInContext(source, context);
  const controller = new context.TaskBoard();
  controller.element = { addEventListener() {} };
  controller.connect();
  controller.writableValue = true;
  controller.hasStatusTarget = true;
  controller.statusTarget = {};
  const select = { value: 'todo' };
  const classes = new Set(['font-medium', 'text-ink']);
  const title = { classList: { toggle(name, enabled) { enabled ? classes.add(name) : classes.delete(name); } } };
  const card = { dataset: { taskId: '42', status: 'todo', moveUrl: '/projects/tasks/42/move' },
    querySelector: selector => selector === 'select' ? select : title, animate() {} };
  const columns = ['todo', 'done'].map(status => {
    const column = { dataset: { status }, cards: [], count: {}, empty: { classList: { toggle() {} } } };
    column.list = { insertBefore(item, anchor) {
      item.parentElement?.column.cards.splice(item.parentElement.column.cards.indexOf(item), 1);
      const at = column.cards.indexOf(anchor);
      if (at >= 0) column.cards.splice(at, 0, item); else column.cards.push(item);
      item.parentElement = column.list;
    }, column };
    column.querySelector = selector => ({
      "[data-task-board-target='list']": column.list,
      "[data-task-board-target='empty']": column.empty,
      "[data-task-board-target='count']": column.count,
      h3: { textContent: status }
    })[selector];
    column.querySelectorAll = () => column.cards;
    column.cards.forEach = column.cards.forEach.bind(column.cards);
    return column;
  });
  columns[0].list.insertBefore(card);
  controller.columnTargets = columns;
  return { controller, card, columns, select, classes, navigation, context };
}

test('failed save restores column, selector, counts and completion styling', async () => {
  const { controller, card, columns, select, classes, navigation } = board(async () => ({ ok: false, json: async () => ({ error: 'Forbidden' }) }));
  await controller.move(card, 'done');
  assert.equal(card.dataset.status, 'todo');
  assert.equal(select.value, 'todo');
  assert.deepEqual(columns.map(c => c.cards.length), [1, 0]);
  assert.deepEqual(columns.map(c => c.count.textContent), [1, 0]);
  assert.equal(classes.has('line-through'), false);
  assert.equal(classes.has('text-taupe'), false);
  assert.equal(classes.has('font-medium'), true);
  assert.equal(controller.statusTarget.textContent, 'Forbidden');
  assert.equal(navigation.reloads, 0);
});

test('only one request for a card can be in flight', async () => {
  let finish;
  let requests = 0;
  const { controller, card, columns, navigation } = board(() => {
    requests++;
    if (requests > 1) return Promise.resolve({ ok: false });
    return new Promise(resolve => { finish = resolve; });
  });
  const saving = controller.move(card, 'done');
  await controller.move(card, 'todo');
  assert.equal(requests, 1);
  finish({ ok: true, json: async () => ({ id: 42, status: 'done' }) });
  await saving;
  assert.equal(requests, 2);
  assert.equal(card.dataset.status, 'done');
  assert.deepEqual(columns.map(c => c.cards.length), [0, 1]);
  // The page could not be re-read, so it falls back to a full reload.
  assert.equal(navigation.reloads, 1);
});

test('a confirmed move refreshes totals and the card in place without reloading', async () => {
  const requests = [];
  const { controller, card, columns, navigation, context } = board(async (url, options) => {
    requests.push({ url, body: options.body && JSON.parse(options.body) });
    if (options.method === 'POST') return { ok: true, json: async () => ({ id: 42, status: 'done' }) };
    return { ok: true, text: async () => 'page' };
  });
  const region = { dataset: { liveRegion: 'progress' }, innerHTML: 'old' };
  const updatedCard = { dataset: { taskId: '42', status: 'done' }, parentElement: null };
  context.document.querySelectorAll = selector => selector === '[data-live-region]' ? [region] : [];
  context.DOMParser = class {
    parseFromString() {
      return { querySelector: selector => selector.includes('live-region') ? { innerHTML: 'new totals' } : updatedCard };
    }
  };
  let replaced;
  card.replaceWith = node => { replaced = node; };
  await controller.move(card, 'done');
  assert.equal(region.innerHTML, 'new totals');
  assert.equal(replaced, updatedCard);
  assert.equal(navigation.reloads, 0);
  assert.deepEqual(requests[0].body, { status: 'done', ordered_ids: ['42'] });
  assert.deepEqual(columns.map(c => c.cards.length), [0, 1]);
});

test('dropping a card where it already sits sends nothing', async () => {
  let requests = 0;
  const { controller, card } = board(async () => { requests++; });
  await controller.move(card, 'todo');
  assert.equal(requests, 0);
});

test('reordering inside a column saves the new order', async () => {
  const bodies = [];
  const { controller, card, columns } = board(async (url, options) => {
    if (options.method === 'POST') { bodies.push(JSON.parse(options.body)); return { ok: true, json: async () => ({ id: 42, status: 'todo' }) }; }
    return { ok: false };
  });
  const other = { dataset: { taskId: '7', status: 'todo' }, querySelector: () => null, animate() {} };
  columns[0].list.insertBefore(other);
  await controller.move(card, 'todo');
  assert.deepEqual(bodies[0], { status: 'todo', ordered_ids: ['7', '42'] });
});

test('expired login returning HTML cannot be treated as a successful move', async () => {
  const { controller, card } = board(async () => ({ ok: true, json: async () => { throw new Error('Invalid JSON'); } }));
  await controller.move(card, 'done');
  assert.equal(card.dataset.status, 'todo');
});

test('read only boards send no mutation request', async () => {
  let requests = 0;
  const { controller, card } = board(() => { requests++; });
  controller.writableValue = false;
  await controller.move(card, 'done');
  assert.equal(requests, 0);
  assert.equal(card.dataset.status, 'todo');
});
