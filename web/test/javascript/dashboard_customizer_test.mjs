import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source = readFileSync(new URL('../../app/javascript/controllers/dashboard_customizer_controller.js', import.meta.url), 'utf8')
  .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
  .replace('export default class', 'globalThis.Customizer = class');
let request;
let reloads = 0;
const section = { hidden: false };
const context = {
  document: { querySelector: (selector) => selector.startsWith('meta') ? { content: 'fixture-csrf' } : section },
  window: { location: { reload() { reloads++; } } },
  fetch: async (url, options) => { request = { url, options }; return { ok: true, json: async () => ({ ok: true }) }; },
};
vm.createContext(context);
vm.runInContext(source, context);
const controller = new context.Customizer();
const classes = new Set();
controller.panelTarget = { classList: { add: name => classes.add(name), contains: name => classes.has(name), toggle(name, on) { if (on) classes.add(name); else classes.delete(name); } } };
let focusCount = 0;
controller.toggleTarget = { setAttribute(name, value) { this[name] = value; }, focus() { focusCount++; } };
controller.statusTarget = { textContent: '' };
controller.saveTarget = {};
controller.resetTarget = {};
controller.connect();
controller.toggleEditor();
assert.equal(classes.has('hidden'), false);
assert.equal(controller.toggleTarget['aria-expanded'], 'true');
controller.closeEditor();
assert.equal(classes.has('hidden'), true);
assert.equal(focusCount, 1);
controller.onChange({ target: { closest: () => ({ dataset: { visible: 'revenue' }, checked: false }) } });
assert.equal(section.hidden, true);
controller.onChange({ target: { closest: () => ({ dataset: { visible: 'revenue' }, checked: true }) } });
assert.equal(section.hidden, false);
controller.saveLayout({ widgets: ['revenue'], hidden: [] });
await new Promise(resolve => setTimeout(resolve, 0));
assert.equal(request.url, '/dashboard/customize');
assert.equal(request.options.headers['X-CSRF-Token'], 'fixture-csrf');
assert.equal(reloads, 1);
assert.equal(controller.saveTarget.disabled, false);
console.log('Dashboard layout opens, closes, changes visibility and saves with CSRF protection.');
