import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const read = (path) => readFileSync(new URL(`../../app/javascript/${path}`, import.meta.url), 'utf8');
const capture = read('lib/feedback_capture.js').replace(/^export /gm, '');
const controllerSource = read('controllers/feedback_controller.js')
  .replace(/^import .*$/gm, '')
  .replace('export default class extends Controller', 'globalThis.Feedback = class extends Controller');
const code = `class Controller {}\n${capture}\n${controllerSource}\nglobalThis.capture = { isSensitiveControl, maskControls, buildSnapshot, pushError, errorFromEvent, MASK, MAX_ERRORS, whenStylesLoaded };`;

// A very small DOM: enough tree for the selectors the capture code uses.
class El {
  constructor(tag, attrs = {}, children = []) {
    this.tagName = tag.toUpperCase(); this.attrs = { ...attrs }; this.children = children; this.parent = null; this._value = attrs.value;
    this.children.forEach((c) => { c.parent = this; });
  }
  get type() { return this.attrs.type || ''; }
  get name() { return this.attrs.name; }
  get id() { return this.attrs.id; }
  get placeholder() { return this.attrs.placeholder; }
  get autocomplete() { return this.attrs.autocomplete; }
  get dataset() { const d = {}; Object.keys(this.attrs).filter((k) => k.startsWith('data-')).forEach((k) => { d[k.slice(5)] = this.attrs[k]; }); return d; }
  get value() { return this._value; }
  set value(v) { this._value = v; }
  set textContent(v) { this.children = []; this.text = v; }
  get textContent() { return this.text || this.children.map((c) => c.textContent).join(''); }
  get attributes() { return Object.keys(this.attrs).map((name) => ({ name, value: this.attrs[name] })); }
  getAttribute(n) { return this.attrs[n] ?? null; }
  setAttribute(n, v) { this.attrs[n] = String(v); }
  removeAttribute(n) { delete this.attrs[n]; }
  hasAttribute(n) { return n in this.attrs; }
  closest(sel) { for (let n = this; n; n = n.parent) if (n.matches(sel)) return n; return null; }
  matches(sel) { return sel.split(',').some((part) => this.matchOne(part.trim())); }
  matchOne(s) {
    if (s === '*') return true;
    if (s.startsWith('[')) return s.slice(1, -1).split('=')[0] in this.attrs;
    return this.tagName === s.toUpperCase();
  }
  descendants() { return this.children.flatMap((c) => [c, ...c.descendants()]); }
  querySelectorAll(sel) { return this.descendants().filter((n) => n.matches(sel)); }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this); }
  cloneNode() { const copy = new El(this.tagName, this.attrs, this.children.map((c) => c.cloneNode())); copy._value = this._value; copy.text = this.text; return copy; }
  get outerHTML() {
    const attrs = Object.entries(this.attrs).map(([k, v]) => ` ${k}="${v}"`).join('');
    return `<${this.tagName.toLowerCase()}${attrs}>${this.text || this.children.map((c) => c.outerHTML).join('')}</${this.tagName.toLowerCase()}>`;
  }
}

function load(extra = {}) {
  const listeners = {};
  const context = {
    window: { addEventListener: (t, f) => { listeners[t] = f; }, removeEventListener: (t) => { delete listeners[t]; }, innerWidth: 390, innerHeight: 800,
      scrollX: 0, scrollY: 0, location: { href: 'https://rupert.test/inventory?token=abc' }, screen: { width: 390, height: 844 }, devicePixelRatio: 3 },
    document: { addEventListener() {}, removeEventListener() {}, activeElement: null, body: { classList: { add() {}, remove() {} } },
      documentElement: { dataset: { theme: 'dark' } }, title: 'Inventory', querySelector: () => ({ getAttribute: () => 'csrf-token-1' }) },
    navigator: { language: 'en-US', onLine: true, maxTouchPoints: 5 },
    Intl, JSON, Promise, Date, Array, String, Object, Math, setTimeout, clearTimeout, console,
    FormData: class { constructor() { this.entries = []; } append(k, v) { this.entries.push([k, v]); } get(k) { return this.entries.find(([key]) => key === k)?.[1]; } has(k) { return this.entries.some(([key]) => key === k); } },
    getComputedStyle: () => ({ backgroundColor: 'rgb(0,0,0)' }),
    ...extra
  };
  vm.createContext(context);
  vm.runInContext(code, context);
  return { context, listeners };
}

function node(extra = {}) {
  const classes = new Set(extra.classes || []);
  return { classList: { add: (c) => classes.add(c), remove: (c) => classes.delete(c), contains: (c) => classes.has(c), toggle: (c, on) => (on ? classes.add(c) : classes.delete(c)) },
    attributes: {}, setAttribute(k, v) { this.attributes[k] = v; }, focus() { this.focused = true; }, dataset: {}, hidden: false, textContent: '', value: '', checked: false, ...extra };
}

function controllerFor(env, options = {}) {
  const { context } = env;
  const c = new context.Feedback();
  c.panelTarget = node({ classes: ['hidden'], querySelectorAll: () => [] });
  c.hasPanelTarget = true;
  c.backdropTarget = node({ classes: ['hidden'] });
  c.triggerTargets = [node()];
  c.kindTargets = [node({ value: 'bug', checked: true }), node({ value: 'request' }), node({ value: 'question' })];
  c.severityFieldTarget = node(); c.hasSeverityFieldTarget = true;
  c.severityTarget = node({ value: 'high' }); c.hasSeverityTarget = true;
  c.descriptionTarget = node({ value: 'The total is wrong' });
  c.submitTarget = node();
  c.statusTarget = node();
  c.formTarget = node({ reset() {} });
  c.doneTarget = node({ hidden: true });
  c.doneMessageTarget = node();
  c.doneLinkTarget = node();
  c.screenshotTarget = node({ checked: false });
  c.detailsTarget = node({ checked: true });
  c.hasCountTarget = false;
  c.urlValue = '/feedback_reports'; c.buildValue = 'abc123'; c.requestIdValue = 'req-9';
  c.errors = [];
  Object.assign(c, options);
  return c;
}

test('sensitive fields are recognized by type, autocomplete, name and data-sensitive', () => {
  const { context } = load();
  const { isSensitiveControl } = context.capture;
  assert.equal(isSensitiveControl(new El('input', { type: 'password' })), true);
  assert.equal(isSensitiveControl(new El('input', { type: 'text', autocomplete: 'cc-number' })), true);
  assert.equal(isSensitiveControl(new El('input', { type: 'text', name: 'api_key' })), true);
  assert.equal(isSensitiveControl(new El('input', { type: 'text', 'data-sensitive': '' })), true);
  assert.equal(isSensitiveControl(new El('input', { type: 'hidden', name: 'authenticity_token' })), true);
  assert.equal(isSensitiveControl(new El('input', { type: 'text', name: 'sku', placeholder: 'Search' })), false);
  assert.equal(isSensitiveControl(new El('input', { type: 'text', name: 'customer_note' })), false);
});

test('the snapshot drops scripts, handlers and the panel, hides sensitive values and keeps the rest', () => {
  const { context } = load();
  const pass = new El('input', { type: 'password', value: 'hunter2', name: 'pw' });
  const sku = new El('input', { type: 'text', name: 'sku' });
  sku.value = 'TEA-50';
  const card = new El('div', { 'data-sensitive': '' }, []);
  card.text = '4111 1111 1111 1111';
  const panel = new El('aside', { 'data-feedback-ignore': '' }, [new El('textarea', { name: 'description' })]);
  const body = new El('body', {}, [new El('script', {}, []), new El('h1', { onclick: 'steal()' }), pass, sku, card, panel]);
  const root = new El('html', {}, [body]);
  const doc = { documentElement: root, querySelectorAll: (sel) => root.querySelectorAll(sel) };
  const html = context.capture.buildSnapshot(doc);
  assert.ok(!html.includes('<script'));
  assert.ok(!html.includes('onclick'));
  assert.ok(!html.includes('hunter2'));
  assert.ok(!html.includes('4111'));
  assert.ok(!html.includes('<aside'));
  assert.ok(html.includes('TEA-50'), 'ordinary field values stay');
  assert.ok(html.includes('[hidden]'));
  assert.equal(pass.value, 'hunter2', 'the live page is untouched');
});

test('the snapshot is capped', () => {
  const { context } = load();
  const root = new El('html', {}, [new El('body', {}, [])]);
  root.children[0].text = 'x'.repeat(500);
  const html = context.capture.buildSnapshot({ documentElement: root, querySelectorAll: () => [] }, 100);
  assert.equal(html.length, 100);
});

test('only the last ten errors are kept and long text is cut', () => {
  const { context } = load();
  const list = [];
  for (let i = 0; i < 15; i += 1) context.capture.pushError(list, { message: `boom ${i}`, stack: 's'.repeat(5000) });
  assert.equal(list.length, 10);
  assert.equal(list[0].message, 'boom 5');
  assert.equal(list[9].stack.length, 1000);
  const fromRejection = context.capture.errorFromEvent({ reason: new Error('nope') });
  assert.equal(fromRejection.message, 'nope');
  assert.equal(context.capture.errorFromEvent({ message: 'x', filename: '/a.js', lineno: 2, colno: 3 }).line, 2);
});

test('connect listens for errors and disconnect stops', () => {
  const env = load();
  const c = controllerFor(env);
  c.kindTargets = c.kindTargets;
  c.connect();
  env.listeners.error({ message: 'kaboom', filename: '/x.js', lineno: 1, colno: 2 });
  assert.equal(c.errors[0].message, 'kaboom');
  c.disconnect();
  assert.equal(env.listeners.error, undefined);
});

test('opening focuses the description, Escape closes and returns focus; severity only for bugs', () => {
  const env = load();
  const c = controllerFor(env);
  const opener = node();
  env.context.document.activeElement = opener;
  c.open();
  assert.equal(c.isOpen, true);
  assert.equal(c.descriptionTarget.focused, true);
  assert.equal(c.triggerTargets[0].attributes['aria-expanded'], 'true');
  c.keydown({ key: 'Escape', preventDefault() {} });
  assert.equal(c.isOpen, false);
  assert.equal(c.triggerTargets[0].attributes['aria-expanded'], 'false');
  assert.equal(opener.focused, true);
  c.kindTargets[0].checked = false; c.kindTargets[1].checked = true;
  c.kindChanged();
  assert.equal(c.severityFieldTarget.hidden, true);
  c.kindTargets[1].checked = false; c.kindTargets[0].checked = true;
  c.kindChanged();
  assert.equal(c.severityFieldTarget.hidden, false);
});

test('Tab wraps inside the panel', () => {
  const env = load();
  const c = controllerFor(env);
  const first = node(); const last = node();
  [first, last].forEach((n) => { n.closest = () => null; });
  c.panelTarget.querySelectorAll = () => [first, last];
  env.context.document.activeElement = last;
  let prevented = false;
  c.trapFocus({ shiftKey: false, preventDefault() { prevented = true; } });
  assert.equal(prevented, true);
  assert.equal(first.focused, true);
});

test('submitting posts the description with the page, build request id, details and errors, then shows the thanks', async () => {
  const requests = [];
  const env = load({ fetch: async (url, init) => { requests.push({ url, init }); return { ok: true, json: async () => ({ id: 7, url: '/feedback_reports/7', message: 'Thank you. Report #7 was sent to the team.' }) }; } });
  const c = controllerFor(env);
  c.errors = [{ message: 'boom' }];
  c.snapshot = () => '<html></html>';
  await c.submit({ preventDefault() {} });
  assert.equal(requests.length, 1);
  const { url, init } = requests[0];
  assert.equal(url, '/feedback_reports');
  assert.equal(init.method, 'POST');
  assert.equal(init.headers['X-CSRF-Token'], 'csrf-token-1');
  assert.equal(init.credentials, 'same-origin');
  const body = init.body;
  assert.equal(body.get('feedback_report[kind]'), 'bug');
  assert.equal(body.get('feedback_report[severity]'), 'high');
  assert.equal(body.get('feedback_report[description]'), 'The total is wrong');
  assert.equal(body.get('feedback_report[page_url]'), 'https://rupert.test/inventory?token=abc');
  assert.equal(body.get('feedback_report[page_request_id]'), 'req-9');
  assert.equal(JSON.parse(body.get('feedback_report[client]')).viewport, '390x800');
  assert.equal(JSON.parse(body.get('feedback_report[js_errors]'))[0].message, 'boom');
  assert.equal(body.get('feedback_report[dom_snapshot]'), '<html></html>');
  assert.equal(body.has('feedback_report[screenshot]'), false);
  assert.equal(c.doneTarget.hidden, false);
  assert.equal(c.formTarget.hidden, true);
  assert.equal(c.doneMessageTarget.textContent, 'Thank you. Report #7 was sent to the team.');
  assert.equal(c.doneLinkTarget.href, '/feedback_reports/7');
  assert.equal(c.submitTarget.disabled, false);
});

test('unchecked details are not sent; a failed screenshot does not block the report', async () => {
  const requests = [];
  const env = load({ fetch: async (url, init) => { requests.push(init); return { ok: true, json: async () => ({ id: 8, url: '/feedback_reports/8' }) }; } });
  const c = controllerFor(env);
  c.detailsTarget.checked = false;
  c.screenshotTarget.checked = true;
  c.captureScreenshot = async () => null;
  await c.submit({ preventDefault() {} });
  assert.equal(requests.length, 1);
  assert.equal(requests[0].body.has('feedback_report[dom_snapshot]'), false);
  assert.equal(requests[0].body.has('feedback_report[js_errors]'), false);
  assert.equal(requests[0].body.has('feedback_report[screenshot]'), false);
  assert.equal(c.doneTarget.hidden, false);
});

test('a server refusal is shown as text and the form stays usable', async () => {
  const env = load({ fetch: async () => ({ ok: false, status: 422, json: async () => ({ error: 'You have sent 30 reports today. Please try again tomorrow.' }) }) });
  const c = controllerFor(env);
  await c.submit({ preventDefault() {} });
  assert.equal(c.statusTarget.textContent, 'You have sent 30 reports today. Please try again tomorrow.');
  assert.equal(c.statusTarget.classList.contains('text-rose'), true);
  assert.equal(c.submitTarget.disabled, false);
  assert.equal(c.formTarget.hidden, false);
});

test('a network failure is reported without throwing', async () => {
  const env = load({ fetch: async () => { throw new Error('offline'); } });
  const c = controllerFor(env);
  await c.submit({ preventDefault() {} });
  assert.equal(c.statusTarget.textContent, 'offline');
  assert.equal(c.submitTarget.disabled, false);
});

test('a too-short description is refused before anything is sent', async () => {
  let called = false;
  const env = load({ fetch: async () => { called = true; return { ok: true, json: async () => ({}) }; } });
  const c = controllerFor(env);
  c.descriptionTarget.value = 'hi';
  await c.submit({ preventDefault() {} });
  assert.equal(called, false);
  assert.match(c.statusTarget.textContent, /at least 5/);
  assert.equal(c.descriptionTarget.focused, true);
});

test('text from the server is only ever written with textContent', () => {
  const source = read('controllers/feedback_controller.js');
  assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML/.test(source), 'no HTML injection in the controller');
});

test('the screenshot waits for stylesheets that are still loading, but not forever', async () => {
  const { context } = load();
  const listeners = {};
  const loading = { sheet: null, addEventListener: (type, fn) => { listeners[type] = fn; } };
  const loaded = { sheet: {}, addEventListener() { throw new Error('should not wait'); } };
  const doc = { querySelectorAll: () => [loading, loaded] };
  let done = false;
  const waiting = context.capture.whenStylesLoaded(doc, 1000).then(() => { done = true; });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(done, false, 'still waiting for the stylesheet');
  listeners.load();
  await waiting;
  assert.equal(done, true);
  await context.capture.whenStylesLoaded({ querySelectorAll: () => [] });
  const stuck = { sheet: null, addEventListener() {} };
  const started = Date.now();
  await context.capture.whenStylesLoaded({ querySelectorAll: () => [stuck] }, 30);
  assert.ok(Date.now() - started < 1000, 'gives up after the timeout');
});
