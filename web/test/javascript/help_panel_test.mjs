import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const source = readFileSync(new URL('../../app/javascript/controllers/help_panel_controller.js', import.meta.url), 'utf8')
  .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
  .replace('export default class', 'globalThis.HelpPanel = class');

function node(extra = {}) {
  const classes = new Set(extra.classes || []);
  return {
    classList: { add: (c) => classes.add(c), remove: (c) => classes.delete(c), contains: (c) => classes.has(c) },
    attributes: {}, setAttribute(k, v) { this.attributes[k] = v; }, focus() { globalThis.focused = this; },
    dataset: {}, children: [], append(...n) { this.children.push(...n); }, innerHTML: '', hidden: false, ...extra
  };
}

function build() {
  const requests = [];
  const events = [];
  const context = {
    document: { activeElement: null, body: node(), addEventListener() {}, removeEventListener() {}, querySelector: () => null,
      createElement(tag) { const n = node({ tag }); Object.defineProperty(n, 'textContent', { set(v) { n.text = v; }, get() { return n.text; } }); return n; } },
    window: { dispatchEvent: (event) => events.push(event.type) },
    CustomEvent: class { constructor(type) { this.type = type; } },
    setTimeout: (fn) => { fn(); return 1; }, clearTimeout() {},
    fetch: async (url) => { requests.push(url); return { ok: true, json: async () => ({ lessons: [{ key: 'alerts', title: 'Turn alerts into restock decisions', summary: 'Read cover.', minutes: 3, url: '/learning/alerts', completed: false }], terms: [{ key: 'days_of_cover', label: 'Days of cover', definition: 'Roughly how long stock lasts.' }], tours: [] }) }; }
  };
  vm.createContext(context);
  vm.runInContext(source, context);
  const controller = new context.HelpPanel();
  controller.panelTarget = node({ classes: ['hidden'], dataset: { helpPanelSearchUrlValue: '/learning.json' } });
  controller.hasPanelTarget = true;
  controller.backdropTarget = node({ classes: ['hidden'] });
  controller.hasBackdropTarget = true;
  controller.triggerTargets = [node()];
  controller.inputTarget = node({ value: '' });
  controller.hasInputTarget = true;
  controller.resultsTarget = node();
  controller.pageTarget = node();
  controller.hasPageTarget = true;
  return { controller, requests, events, context };
}

test('? opens the help panel, Escape closes it, typing in a field does not trigger it', () => {
  const { controller } = build();
  controller.connect();
  controller.documentKeydown({ key: '?', target: { tagName: 'INPUT' }, preventDefault() {} });
  assert.equal(controller.isOpen, false, 'typing ? in a field is left alone');
  controller.documentKeydown({ key: '?', target: { tagName: 'BODY' }, preventDefault() {} });
  assert.equal(controller.isOpen, true);
  assert.equal(controller.triggerTargets[0].attributes['aria-expanded'], 'true');
  assert.equal(globalThis.focused, controller.inputTarget, 'focus lands in the search box');
  controller.documentKeydown({ key: 'Escape', target: { tagName: 'BODY' }, preventDefault() {} });
  assert.equal(controller.isOpen, false);
  assert.equal(controller.triggerTargets[0].attributes['aria-expanded'], 'false');
});

test('search fetches JSON and renders definitions and lessons as text, never HTML', async () => {
  const { controller, requests } = build();
  controller.connect();
  controller.inputTarget.value = 'cover <b>x</b>';
  controller.search();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(requests[0], '/learning.json?q=cover%20%3Cb%3Ex%3C%2Fb%3E');
  const texts = [];
  const walk = (n) => { if (n.text) texts.push(n.text); (n.children || []).forEach(walk); };
  controller.resultsTarget.children.forEach(walk);
  assert.ok(texts.includes('Days of cover'));
  assert.ok(texts.some((t) => t.startsWith('Turn alerts into restock decisions · 3 min')));
  assert.equal(controller.pageTarget.hidden, true, 'results replace the page section while searching');
  controller.inputTarget.value = '';
  controller.search();
  assert.equal(controller.pageTarget.hidden, false);
});

test('Show me around closes the panel and asks the page tour to start', () => {
  const { controller, events } = build();
  controller.connect();
  controller.open();
  controller.startTour();
  assert.equal(controller.isOpen, false);
  assert.deepEqual(events, ['rupert:start-tour']);
});
