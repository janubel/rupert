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
    column.list = { insertBefore(item) {
      item.parentElement?.column.cards.splice(item.parentElement.column.cards.indexOf(item), 1);
      column.cards.push(item); item.parentElement = column.list;
    }, column };
    column.querySelector = selector => ({
      "[data-task-board-target='list']": column.list,
      "[data-task-board-target='empty']": column.empty,
      "[data-task-board-target='count']": column.count,
      h3: { textContent: status }
    })[selector];
    column.querySelectorAll = () => column.cards;
    return column;
  });
  columns[0].list.insertBefore(card);
  controller.columnTargets = columns;
  return { controller, card, columns, select, classes, navigation };
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
    return new Promise(resolve => { finish = resolve; });
  });
  const saving = controller.move(card, 'done');
  await controller.move(card, 'todo');
  assert.equal(requests, 1);
  finish({ ok: true, json: async () => ({ id: 42, status: 'done' }) });
  await saving;
  assert.equal(card.dataset.status, 'done');
  assert.deepEqual(columns.map(c => c.cards.length), [0, 1]);
  assert.equal(navigation.reloads, 1);
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
