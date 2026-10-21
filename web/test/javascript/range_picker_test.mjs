import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const source = readFileSync(new URL('../../app/javascript/controllers/range_picker_controller.js', import.meta.url), 'utf8')
  .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
  .replace('export default class', 'globalThis.RangePicker = class');
const context = {};
vm.createContext(context);
vm.runInContext(source, context);
const { matchPreset, rangeKey, datesFor, rangeProblem, RangePicker } =
  vm.runInContext('({ matchPreset, rangeKey, datesFor, rangeProblem, RangePicker })', context);

// As rendered for Tuesday 2026-10-20: pay weeks run Thursday–Wednesday.
const presets = [
  ['today', '2026-10-20', '2026-10-20'],
  ['this_pay_week', '2026-10-15', '2026-10-21'],
  ['last_pay_week', '2026-10-08', '2026-10-14'],
  ['this_month', '2026-10-01', '2026-10-31'],
];

assert.equal(matchPreset(presets, '2026-10-08', '2026-10-14'), 'last_pay_week');
assert.equal(matchPreset(presets, '2026-10-08', '2026-10-15'), null);
assert.equal(rangeKey(presets, '2026-10-15', '2026-10-21', false), 'this_pay_week');
assert.equal(rangeKey(presets, '2026-10-02', '2026-10-21', false), 'custom');
assert.equal(rangeKey(presets, '', '', false), 'custom');
assert.equal(rangeKey(presets, '', '', true), 'all');
assert.equal(rangeKey(presets, '2026-10-02', '', true), 'custom');
assert.deepEqual([...datesFor(presets, 'this_month')], ['2026-10-01', '2026-10-31']);
assert.deepEqual([...datesFor(presets, 'all')], ['', '']);
assert.equal(datesFor(presets, 'custom'), null);
assert.equal(rangeProblem('2026-10-08', '2026-10-14'), '');
assert.equal(rangeProblem('2026-10-08', '2026-10-08'), '');
assert.equal(rangeProblem('2026-10-14', '2026-10-08'), 'End date must be on or after the start date.');
assert.equal(rangeProblem('', '2026-10-08'), '');

// The controller wires those rules to the select, the date inputs and the error.
const input = (value) => ({
  value,
  validity: '',
  attributes: {},
  focused: false,
  setCustomValidity(message) { this.validity = message; },
  setAttribute(name, value) { this.attributes[name] = value; },
  removeAttribute(name) { delete this.attributes[name]; },
  focus() { this.focused = true; },
});
const picker = new RangePicker();
Object.assign(picker, {
  presetsValue: presets,
  optionalValue: false,
  selectTarget: { value: 'this_month' },
  fromTarget: input('2026-10-01'),
  toTarget: input('2026-10-31'),
  errorTarget: { textContent: '', hidden: true },
});

picker.connect();
assert.equal(picker.selectTarget.value, 'this_month');

picker.selectTarget.value = 'last_pay_week';
picker.choose();
assert.equal(picker.fromTarget.value, '2026-10-08');
assert.equal(picker.toTarget.value, '2026-10-14');

picker.toTarget.value = '2026-10-13';
picker.edit();
assert.equal(picker.selectTarget.value, 'custom');

picker.fromTarget.value = '2026-10-15';
picker.edit();
assert.equal(picker.errorTarget.hidden, false);
assert.equal(picker.errorTarget.textContent, 'End date must be on or after the start date.');
assert.equal(picker.toTarget.validity, 'End date must be on or after the start date.');
assert.equal(picker.toTarget.attributes['aria-invalid'], 'true');

picker.toTarget.value = '2026-10-21';
picker.edit();
assert.equal(picker.selectTarget.value, 'this_pay_week');
assert.equal(picker.errorTarget.hidden, true);
assert.equal(picker.toTarget.validity, '');
assert.equal(picker.toTarget.attributes['aria-invalid'], undefined);

picker.selectTarget.value = 'custom';
picker.choose();
assert.equal(picker.fromTarget.value, '2026-10-15');
assert.equal(picker.fromTarget.focused, true);

console.log('Range picker fills Start/Finish from named ranges, switches to Custom on edits and blocks Finish before Start.');
