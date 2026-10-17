import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source = readFileSync(new URL('../../app/javascript/controllers/journal_form_controller.js', import.meta.url), 'utf8')
  .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
  .replace('export default class', 'globalThis.JournalForm = class');
const context = {};
vm.createContext(context);
vm.runInContext(source, context);
const { evaluate, toCents, money } = vm.runInContext('({ evaluate, toCents, money })', context);
const locks = [{ from: '2026-01-01', to: '2026-01-31', label: 'January 2026' }];

assert.equal(toCents('1234567.89'), 123456789);
assert.equal(toCents('1,234'), null);
assert.equal(toCents('$5'), null);
assert.equal(money(123456789), '$1,234,567.89');
assert.equal(money(-1), '−$0.01');

let r = evaluate([{ account: '1', debit: '100.00', credit: '' }, { account: '2', debit: '', credit: '100.00' }], '2026-02-01', locks);
assert.equal(r.reasons.length, 0);
assert.equal(r.difference, 0);

r = evaluate([{ account: '1', debit: '100.00', credit: '' }, { account: '2', debit: '', credit: '99.99' }], '2026-02-01', locks);
assert.match(r.reasons.join(' '), /Out of balance by \$0\.01: debits exceed credits/);

r = evaluate([{ account: '1', debit: '5', credit: '5' }, { account: '', debit: '', credit: '5' }], '2026-02-01', locks);
assert.match(r.reasons.join(' '), /Line 1: use either Debit or Credit/);
assert.match(r.reasons.join(' '), /Line 2: choose an account/);

r = evaluate([{ account: '1', debit: '1,000', credit: '' }, { account: '2', debit: '', credit: '1000' }], '2026-02-01', locks);
assert.match(r.reasons.join(' '), /Line 1: the debit is not an amount/);

r = evaluate([{ account: '1', debit: '10', credit: '' }, { account: '2', debit: '', credit: '10' }], '2026-01-15', locks);
assert.match(r.reasons[0], /January 2026 is locked/);

r = evaluate([{ account: '1', debit: '10', credit: '' }], '2026-02-01', locks);
assert.match(r.reasons.join(' '), /Out of balance/);

r = evaluate([{ account: '', debit: '', credit: '' }], '2026-02-01', locks);
assert.match(r.reasons[0], /at least two lines/);
r = evaluate([], '', locks);
assert.match(r.reasons[0], /Enter the entry date/);
console.log('Journal form totals, balance state, lock detection and plain-language reasons are correct.');
