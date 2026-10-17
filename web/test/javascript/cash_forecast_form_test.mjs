import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source = readFileSync(new URL('../../app/javascript/controllers/cash_forecast_form_controller.js', import.meta.url), 'utf8')
  .replace("import { Controller } from '@hotwired/stimulus'", 'class Controller {}')
  .replace('export default class', 'globalThis.CashForm = class');
const context = { document: { createElement: () => ({ dataset: {} }) } };
vm.createContext(context);
vm.runInContext(source, context);
const Form = context.CashForm;

// Amount grammar mirrors ReconciliationEvidence.cents.
assert.deepEqual(['1234.56', '1,234.56', ' $1,234.56 ', '.5', '$.05', '-12', '0', '', '  '].map(v => Form.parseCents(v)), [123456, 123456, 123456, 50, 5, -1200, 0, null, null]);
['1,23', '12,34.00', '1.001', '$', '.', 'abc', '1 000', '(5)', '1234567890123'].forEach(v => assert.ok(Number.isNaN(Form.parseCents(v)), v));
assert.equal(Form.canonical('$1,250'), '1250.00');
assert.equal(Form.canonical('abc '), 'abc');
assert.equal(Form.formatCents(-123456789), '−1,234,567.89');

const form = new Form();
let focused = null;
let scrolled = null;
const attrs = el => Object.assign(el, { setAttribute(k, v) { this[k] = v; }, removeAttribute(k) { delete this[k]; } });
const entry = (id, label, value = '') => attrs({ id, value, disabled: false, dataset: { entryLabel: label }, focus() { focused = id; }, scrollIntoView() { scrolled = id; } });
const date = entry('date', 'Close date', '2026-10-15');
const currency = entry('currency', 'Currency', 'USD');
const opening = entry('opening', 'Opening cash', '');
const notes = entry('notes', 'Scenario assumptions', '   ');
const reserve = entry('reserve', 'Minimum reserve', '');
const weeks = Array.from({ length: 13 }, (_, i) => ['receipts', 'payments'].map(field => {
  const input = entry(`forecast_weeks_${i}_${field}`, `Week ${i + 1} ${field === 'receipts' ? 'bank receipts' : 'cash payments'}`);
  Object.assign(input.dataset, { weekIndex: String(i), field });
  return input;
}));
const cellsOut = weeks.map(() => ({ net: { textContent: '' }, closing: { textContent: '', dataset: {} }, dates: { textContent: '' } }));
form.entryTargets = [date, currency, opening, notes];
form.amountTargets = weeks.flat();
form.asOfTarget = date;
form.hasOpeningTarget = true; form.openingTarget = opening;
form.hasReserveTarget = true; form.reserveTarget = reserve;
form.horizonTarget = { value: '8' };
form.weekTargets = weeks.map((fields, i) => ({ dataset: { week: String(i + 1) }, hidden: false,
  querySelector: sel => ({ '[data-net]': cellsOut[i].net, '[data-closing]': cellsOut[i].closing, '[data-week-dates]': cellsOut[i].dates })[sel],
  querySelectorAll: () => fields }));
form.baselineDateValue = date.value;
form.baselineStatusTargets = [{ hidden: false }];
form.baselineChangedTargets = [{ hidden: true }];
form.changedTargets = [{ hidden: true }];
form.outputTargets = [{ disabled: false }];
form.calculatedValue = false;
form.hasChecklistTarget = true;
form.checklistTarget = { hidden: true };
form.checklistSummaryTarget = { textContent: '' };
form.nextMissingTarget = { dataset: {} };
form.nextLabelTarget = {};
form.missingDetailsTarget = {};
form.missingSummaryTarget = {};
form.missingListTarget = { replaceChildren(...buttons) { this.buttons = buttons; } };
form.hasTotalLabelTarget = true;
for (const name of ['totalLabel', 'totalReceipts', 'totalPayments', 'totalNet', 'totalClosing', 'blankSummary', 'fillSelection', 'fillStatus']) form[`${name}Target`] = { textContent: '' };
form.fillButtonTargets = [{ disabled: true }, { disabled: true }, { disabled: true }];

// Checklist: only base entries are required; weeks may stay blank.
weeks[4][0].value = '555';
form.connect();
assert.equal(form.checklistSummaryTarget.textContent, '2 of 4 required entries filled · 2 missing');
assert.equal(form.nextMissingTarget.dataset.entryId, 'opening');
assert.equal(cellsOut[0].dates.textContent, 'Oct 16 – Oct 22');
assert.equal(form.totalLabelTarget.textContent, 'Total · 8 weeks');
assert.equal(form.totalClosingTarget.textContent, 'Enter opening cash');
assert.match(form.blankSummaryTarget.textContent, /^15 blank weekly entries count as 0\. You confirm them after calculating/);
notes.value = ' '; form.updateChecklist();
form.jumpMissing({ currentTarget: { dataset: { entryId: 'notes' } } });
assert.equal(focused, 'notes'); assert.equal(scrolled, 'notes');
form.horizonTarget.value = '4'; form.update();
assert.equal(weeks[4][0].disabled, true); assert.equal(weeks[4][0].value, '555');
assert.equal(weeks[4][0].required, undefined);
assert.equal(form.weekTargets[4].hidden, true);
form.horizonTarget.value = '8'; form.update();
assert.equal(weeks[4][0].disabled, false); assert.equal(weeks[4][0].value, '555');

// Running totals: blanks count as 0, net and projected closing per week, reserve flag.
opening.value = '$1,000'; reserve.value = '900';
weeks[0][0].value = '100'; weeks[0][1].value = '250.50';
form.markChanged();
assert.equal(cellsOut[0].net.textContent, '−150.50');
assert.equal(cellsOut[0].closing.textContent, '849.50');
assert.equal(cellsOut[0].closing.dataset.short, 'true');
assert.equal(cellsOut[4].net.textContent, '+555.00');
assert.equal(cellsOut[7].closing.textContent, '1,404.50');
assert.equal(form.totalReceiptsTarget.textContent, '655.00');
assert.equal(form.totalPaymentsTarget.textContent, '250.50');
assert.equal(form.totalNetTarget.textContent, '+404.50');
assert.equal(form.totalClosingTarget.textContent, '1,404.50');
assert.match(form.blankSummaryTarget.textContent, /^13 blank weekly entries/);
weeks[1][1].value = '12,34';
form.markChanged();
assert.equal(weeks[1][1]['aria-invalid'], 'true');
assert.equal(cellsOut[1].net.textContent, 'Check amount');
assert.equal(cellsOut[1].closing.textContent, '—');
assert.match(form.blankSummaryTarget.textContent, /1 weekly amount is not a valid zero-or-positive amount/);
weeks[1][1].value = ''; form.markChanged();
assert.equal(weeks[1][1]['aria-invalid'], undefined);
weeks[2][0]['aria-invalid'] = 'true'; form.markChanged();
assert.equal(weeks[2][0]['aria-invalid'], 'true', 'server field error is kept until recalculation');

// Leaving a field rewrites valid amounts in the server's plain form; invalid text is kept.
opening.value = ' $1,000 '; form.normalize({ target: opening }); assert.equal(opening.value, '1000.00');
weeks[1][1].value = '12,34'; form.normalize({ target: weeks[1][1] }); assert.equal(weeks[1][1].value, '12,34');
weeks[1][1].value = '';  form.normalize({ target: weeks[1][1] }); assert.equal(weeks[1][1].value, '');

// Fill-down: empty weeks only by default, overwrite on request, whole week, keyboard.
form.select({ target: weeks[0][0] });
assert.equal(form.fillSelectionTarget.textContent, 'Selected: Week 1 bank receipts · 100');
assert.equal(form.fillButtonTargets.every(button => !button.disabled), true);
form.fillDown({ currentTarget: { dataset: {} } });
assert.deepEqual(weeks.slice(0, 9).map(w => w[0].value), ['100', '100.00', '100.00', '100.00', '555', '100.00', '100.00', '100.00', '']);
assert.equal(form.fillStatusTarget.textContent, 'Repeated bank receipts 100.00 into weeks 2–8 (6 entries).');
weeks[0][0].value = '$2,000';
form.fillDown({ currentTarget: { dataset: { overwrite: 'true' } } });
assert.deepEqual(weeks.slice(1, 9).map(w => w[0].value), ['2000.00', '2000.00', '2000.00', '2000.00', '2000.00', '2000.00', '2000.00', '']);
weeks[2][1].value = '7';
form.select({ target: weeks[1][1] });
form.fillDown({ currentTarget: { dataset: {} } });
assert.equal(form.fillStatusTarget.textContent, 'Week 2 cash payments is blank; enter an amount to repeat.');
form.select({ target: weeks[0][1] });
form.fillWeek();
assert.deepEqual(weeks.slice(0, 8).map(w => w[1].value), ['250.50', '250.50', '7', '250.50', '250.50', '250.50', '250.50', '250.50']);
assert.equal(form.fillStatusTarget.textContent, 'Repeated week 1 amounts into weeks 2–8 (6 entries).');
form.calculatedValue = true;
form.markChanged({ target: { dataset: { reviewOnly: 'true' } } });
assert.equal(form.outputTargets[0].disabled, false, 'ticking the blank-entry confirmation keeps download and retain enabled');
weeks.forEach(w => { w[1].value = ''; });
let prevented = false;
form.navigate({ key: 'ArrowDown', altKey: true, target: weeks[5][0], preventDefault() { prevented = true; } });
assert.equal(prevented, true);
assert.equal(form.fillStatusTarget.textContent, 'No empty weeks below to fill.');
assert.equal(form.outputTargets[0].disabled, false, 'a fill that changes nothing keeps outputs');
weeks[7][0].value = '';
form.navigate({ key: 'ArrowDown', altKey: true, target: weeks[5][0], preventDefault() {} });
assert.equal(weeks[7][0].value, '2000.00');
assert.equal(form.fillStatusTarget.textContent, 'Repeated bank receipts 2000.00 into week 8 (1 entry).');
assert.equal(form.outputTargets[0].disabled, true); assert.equal(form.changedTargets[0].hidden, false);
form.navigate({ key: 'ArrowDown', target: weeks[2][1], preventDefault() {} });
assert.equal(focused, 'forecast_weeks_3_payments');
form.navigate({ key: 'ArrowUp', target: weeks[0][1], preventDefault() {} });
assert.equal(focused, 'forecast_weeks_3_payments', 'no week above week 1');
form.navigate({ key: 'ArrowDown', target: weeks[7][0], preventDefault() {} });
assert.equal(focused, 'forecast_weeks_3_payments', 'week 9 is inactive at 8 weeks');
let ignored = true;
form.navigate({ key: 'ArrowDown', shiftKey: true, target: weeks[0][0], preventDefault() { ignored = false; } });
assert.equal(ignored, true);

// Spreadsheet paste: one column fills downward; two columns fill receipts and payments.
const paste = (target, text) => {
  let defaultPrevented = false;
  form.paste({ target, clipboardData: { getData: () => text }, preventDefault() { defaultPrevented = true; } });
  return defaultPrevented;
};
assert.equal(paste(weeks[0][0], '42.10'), false, 'single values paste natively');
assert.equal(paste(weeks[5][1], '$1,000\r\n\r\n.5\r\n'), true);
assert.deepEqual(weeks.slice(5, 8).map(w => w[1].value), ['1000.00', '', '0.50']);
assert.equal(form.fillStatusTarget.textContent, 'Pasted 3 values into weeks 6–8.');
assert.equal(paste(weeks[5][0], '1\t2\t3\n4\t5\nx\t6\n7\t8\n'), true);
assert.deepEqual(weeks.slice(5, 8).map(w => [w[0].value, w[1].value]), [['1.00', '2.00'], ['4.00', '5.00'], ['x', '6.00']]);
assert.equal(weeks[8][0].value, '');
assert.equal(form.fillStatusTarget.textContent, 'Pasted 6 values into weeks 6–8. 2 values past the last active week were not used; choose more forecast weeks to include them. 1 extra column was ignored; only receipts then payments are used. Check Week 8 bank receipts: not a valid zero-or-positive amount.');
assert.equal(paste(weeks[7][1], '9\t10\n'), true);
assert.equal(weeks[7][1].value, '9.00');
assert.equal(form.fillStatusTarget.textContent, 'Pasted 1 value into week 8. 1 extra column was ignored; only receipts then payments are used.');

// Base checklist and baseline state still track the close date.
form.entryTargets.forEach(field => { if (!field.value.trim()) field.value = field === notes ? 'Synthetic planning assumptions' : '0'; });
form.updateChecklist();
assert.match(form.checklistSummaryTarget.textContent, /Calculate to validate amounts/);
assert.equal(form.nextMissingTarget.hidden, true); assert.equal(form.missingDetailsTarget.hidden, true);
date.value = '2026-10-16'; form.markChanged();
assert.equal(form.baselineStatusTargets[0].hidden, true); assert.equal(form.baselineChangedTargets[0].hidden, false);
console.log('Cash form: amount grammar, optional weeks, running totals, fill-down, keyboard navigation, spreadsheet paste and changed-date baseline passed.');
