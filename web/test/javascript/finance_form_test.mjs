import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source = readFileSync(new URL('../../app/javascript/controllers/finance_form_controller.js', import.meta.url), 'utf8')
  .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
  .replace('export default class', 'globalThis.FinanceForm = class');
const context = {};
vm.createContext(context);
vm.runInContext(source, context);
const { problems, money, fill } = vm.runInContext('({ problems, money, fill })', context);
const locks = [{ from: '2026-01-01', to: '2026-01-31', label: 'January 2026' }];

assert.equal(problems('125.50', '2026-02-01', locks).length, 0);
assert.match(problems('', '2026-02-01', locks)[0], /Enter the amount/);
assert.match(problems('1,250', '2026-02-01', locks)[0], /digits with up to two decimals/);
assert.match(problems('0.00', '2026-02-01', locks)[0], /more than \$0\.00/);
assert.match(problems('5', '', locks)[0], /Choose the date/);
assert.match(problems('5', '2026-01-10', locks)[0], /January 2026 is locked/);
assert.equal(money('1234567.89'), '$1,234,567.89');
assert.equal(money('5'), '$5.00');
assert.equal(money('0.5'), '$0.50');
assert.equal(fill('Pay {amount} to {who} on {date}', { amount: '$5.00', who: 'Acme', date: '2026-02-01' }), 'Pay $5.00 to Acme on 2026-02-01');
console.log('Expense and payment forms explain blockers, detect locked dates and build a specific confirmation.');
