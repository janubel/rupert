import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const source = readFileSync(new URL('../../app/javascript/controllers/report_table_controller.js', import.meta.url), 'utf8')
  .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
  .replace('export default class', 'globalThis.ReportTable = class');
const context = {};
vm.createContext(context);
vm.runInContext(source, context);
const Table = context.ReportTable;

// Money, counts and percents sort as numbers; unknown amounts sort as null.
assert.equal(Table.sortValue('$1,234.50'), 1234.5);
assert.equal(Table.sortValue(' 12 '), 12);
assert.equal(Table.sortValue('45.5%'), 45.5);
assert.equal(Table.sortValue('($20.00)'), -20);
assert.equal(Table.sortValue('−3'), -3);
['', '—', 'Unavailable', 'unknown', 'n/a'].forEach(v => assert.equal(Table.sortValue(v), null, v));
assert.equal(Table.sortValue('Shopify'), 'shopify');
assert.equal(Table.sortValue('2026-10-01'), '2026-10-01');

// Unknowns stay last in both directions; numbers compare numerically.
const values = [10, null, 2, 33].map(v => v);
assert.deepEqual(values.slice().sort((a, b) => Table.compare(a, b, 'asc')), [2, 10, 33, null]);
assert.deepEqual(values.slice().sort((a, b) => Table.compare(a, b, 'desc')), [33, 10, 2, null]);
assert.deepEqual(['b', 'a10', 'a2'].sort((a, b) => Table.compare(a, b, 'asc')), ['a10', 'a2', 'b'].sort((a, b) => a.localeCompare(b, undefined, { numeric: true })));

// CSV quoting and spreadsheet formula guard; negative numbers stay numbers.
assert.equal(Table.csvCell('a,b'), '"a,b"');
assert.equal(Table.csvCell('say "hi"'), '"say ""hi"""');
assert.equal(Table.csvCell('=SUM(A1)'), "'=SUM(A1)");
assert.equal(Table.csvCell('@cmd'), "'@cmd");
assert.equal(Table.csvCell('-12.50'), '-12.50');
assert.equal(Table.csvCell('-$1,200'), '"-$1,200"');
assert.equal(Table.csvCell('  two\n lines '), 'two lines');
assert.equal(Table.toCsv([['Source', 'Tax'], ['C-Trax', '1,000.00']]), 'Source,Tax\r\nC-Trax,"1,000.00"\r\n');

assert.equal(Table.slug('Tax collected (6.35%)'), 'tax-collected-6-35');

// Header labels drop inline definitions and the sort button.
const removed = [];
const th = {
  dataset: {},
  cloneNode() {
    return {
      querySelectorAll(selector) { assert.match(selector, /details/); return [{ remove() { removed.push('details'); } }]; },
      get textContent() { return removed.length ? '  Recorded   tax ' : 'Recorded tax What does tax mean??'; },
    };
  },
};
assert.equal(Table.headerLabel(th), 'Recorded tax');
assert.equal(Table.headerLabel({ dataset: { label: ' Net tax ' } }), 'Net tax');
console.log('report table ok');
