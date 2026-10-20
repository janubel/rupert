import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const source = readFileSync(new URL('../../app/javascript/controllers/tour_controller.js', import.meta.url), 'utf8')
  .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
  .replace('export default class', 'globalThis.Tour = class');

function element(name, extra = {}) {
  const node = {
    name, hidden: false, children: [], listeners: {}, style: {}, dataset: {}, attributes: {}, textContent: '', disabled: false, className: '',
    classList: { add() {}, remove() {}, contains: () => false },
    addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); },
    removeEventListener() {},
    setAttribute(key, value) { this.attributes[key] = value; },
    append(...nodes) { this.children.push(...nodes); },
    remove() { this.removed = true; },
    focus() { globalThis.focused = this; },
    getBoundingClientRect: () => ({ top: 100, left: 20, bottom: 140, right: 220, width: 200, height: 40 }),
    getClientRects: () => [{}],
    scrollIntoView(options) { this.scrolled = options; },
    closest: () => null,
    querySelector(selector) { return this.lookup?.[selector] || null; },
    querySelectorAll: () => [],
    ...extra
  };
  return node;
}

function harness(anchors) {
  const anchorNodes = Object.fromEntries(Object.entries(anchors).map(([key, visible]) => [key, element(key, { getClientRects: () => (visible ? [{}] : []) })]));
  const roles = {};
  const popover = element('popover');
  popover.lookup = roles;
  const makeRole = (role) => {
    const node = element(role, { focus() { globalThis.focused = this; } });
    roles[`[data-role=${role}]`] = node;
    return node;
  };
  ['progress', 'title', 'body', 'skip', 'back', 'next'].forEach(makeRole);
  const created = [];
  const body = element('body', { classList: { add() {}, remove() {}, contains: () => false } });
  const requests = [];
  const context = {
    document: {
      body,
      activeElement: null,
      addEventListener() {}, removeEventListener() {},
      createElement(tag) { const node = created.length === 2 ? popover : element(tag); node.lookup = roles; created.push(node); return node; },
      querySelector: (selector) => selector.startsWith('meta') ? { content: 'csrf-fixture' } : null,
      querySelectorAll(selector) { const key = selector.match(/"([^"]+)"/)[1]; return anchorNodes[key] ? [anchorNodes[key]] : []; }
    },
    window: { scrollX: 0, scrollY: 0, innerWidth: 1200, innerHeight: 800, addEventListener() {}, removeEventListener() {}, dispatchEvent() {}, matchMedia: () => ({ matches: true }) },
    CustomEvent: class { constructor(type, init) { this.type = type; this.detail = init?.detail; } },
    requestAnimationFrame: (fn) => fn(),
    setTimeout: (fn) => { fn(); return 1; },
    clearTimeout() {},
    fetch: async (url, options) => { requests.push({ url, options }); return { ok: true }; }
  };
  vm.createContext(context);
  vm.runInContext(source, context);
  const controller = new context.Tour();
  controller.element = element('bar');
  controller.triggerTargets = [element('trigger', { hidden: true })];
  controller.badgeTargets = [element('badge')];
  controller.keyValue = 'sales';
  controller.titleValue = 'Reading the sales page';
  controller.saveUrlValue = '/learning/preferences';
  controller.doneValue = false;
  controller.autostartValue = false;
  controller.stepsValue = [
    { anchor: 'filters', title: 'Filters', body: 'Pick a day.' },
    { anchor: 'missing', title: 'Not here', body: 'Hidden by permission.' },
    { anchor: 'journal', title: 'Journal', body: 'Every order.' }
  ];
  return { controller, roles, requests, body, popover };
}

test('tour skips missing anchors, steps through, and records completion once', async () => {
  const { controller, roles, requests, popover } = harness({ filters: true, missing: false, journal: true });
  controller.connect();
  assert.equal(controller.triggerTargets[0].hidden, false, 'the Show me around button appears once JavaScript runs');
  controller.start();
  assert.equal(controller.steps.length, 2, 'steps without an anchor on this page are dropped');
  assert.equal(roles['[data-role=progress]'].textContent, '1 of 2 · Reading the sales page');
  assert.equal(roles['[data-role=title]'].textContent, 'Filters');
  assert.equal(roles['[data-role=back]'].disabled, true);
  assert.equal(popover.attributes.role, 'dialog');
  controller.next();
  assert.equal(roles['[data-role=title]'].textContent, 'Journal');
  assert.equal(roles['[data-role=next]'].textContent, 'Done');
  controller.next();
  assert.equal(controller.active, false, 'finishing tears the tour down');
  await Promise.resolve();
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, '/learning/preferences');
  assert.equal(requests[0].options.method, 'PATCH');
  assert.equal(requests[0].options.headers['X-CSRF-Token'], 'csrf-fixture');
  assert.equal(JSON.parse(requests[0].options.body).tour, 'sales');
  assert.equal(controller.badgeTargets[0].removed, true, 'the New badge goes away');
  controller.start();
  controller.skip();
  assert.equal(requests.length, 1, 'a tour already recorded is not recorded again');
});

test('keyboard: Escape skips, arrows move, and a tour with no anchors opens the written guide instead', () => {
  const { controller, roles } = harness({ filters: true, missing: false, journal: true });
  controller.connect();
  controller.start();
  controller.keydown({ key: 'ArrowRight', preventDefault() {} });
  assert.equal(roles['[data-role=title]'].textContent, 'Journal');
  controller.keydown({ key: 'ArrowLeft', preventDefault() {} });
  assert.equal(roles['[data-role=title]'].textContent, 'Filters');
  controller.keydown({ key: 'Escape', preventDefault() {} });
  assert.equal(controller.active, false);

  const empty = harness({ filters: false, missing: false, journal: false });
  let opened = false;
  const details = { open: false, querySelector: () => ({ focus() {} }) };
  empty.controller.element = { querySelector: () => details };
  empty.controller.connect();
  empty.controller.start();
  opened = details.open;
  assert.equal(opened, true, 'without anchors the help disclosure opens');
  assert.equal(empty.controller.active, undefined);
});
