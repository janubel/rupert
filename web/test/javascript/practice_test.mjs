import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const source = readFileSync(new URL('../../app/javascript/controllers/practice_controller.js', import.meta.url), 'utf8')
  .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
  .replace('export default class', 'globalThis.Practice = class');
const context = {};
vm.createContext(context);
vm.runInContext(source, context);

function run(kind, a, b) {
  const c = new context.Practice();
  c.kindValue = kind;
  c.aTarget = { value: a }; c.hasATarget = true;
  c.bTarget = { value: b }; c.hasBTarget = true;
  c.resultTarget = {}; c.hasResultTarget = true;
  c.explanationTarget = {}; c.hasExplanationTarget = true;
  c.compute();
  return [c.resultTarget.textContent, c.explanationTarget.textContent];
}

test('variance is counted minus comparison and unknown stays unknown', () => {
  assert.equal(run('variance', '8', '10')[0], '-2 units');
  assert.equal(run('variance', '12', '10')[0], '+2 units');
  assert.equal(run('variance', '5', '')[0], 'Unknown');
});

test('change is cash received minus total due, with a shortfall called out', () => {
  assert.equal(run('change', '43.16', '50')[0], '$6.84');
  assert.equal(run('change', '43.16', '40')[0], '$3.16 short');
});

test('average sale is recorded sales over included sales and a dash with none', () => {
  assert.equal(run('average', '50', '2')[0], '$25.00');
  assert.equal(run('average', '50', '0')[0], '—');
});

test('cover and suggested reorder follow the restock advisor formula', () => {
  const [result, explanation] = run('cover', '6', '30');
  assert.equal(result, '6 days · reorder 24');
  assert.match(explanation, /never below zero/);
  assert.equal(run('cover', '6', '0')[0], 'No sales');
  assert.equal(run('cover', '40', '30')[0], '40 days · reorder 0');
});
