import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const source = readFileSync(new URL('../../app/javascript/controllers/data_grid_controller.js', import.meta.url), 'utf8')
  .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
  .replace('export default class', 'globalThis.DataGrid = class');
const context = { URL };
vm.createContext(context);
vm.runInContext(source, context);
const Grid = context.DataGrid;

// Arrow keys move one cell and stop at the edges; Home/End go to the row ends,
// Ctrl+Home/End to the corners; Page keys jump ten rows.
assert.deepEqual(Array.from(Grid.step('ArrowDown', 0, 2, 5, 4)), [1, 2]);
assert.deepEqual(Array.from(Grid.step('ArrowUp', 0, 2, 5, 4)), [0, 2]);
assert.deepEqual(Array.from(Grid.step('ArrowRight', 1, 3, 5, 4)), [1, 3]);
assert.deepEqual(Array.from(Grid.step('ArrowLeft', 1, 0, 5, 4)), [1, 0]);
assert.deepEqual(Array.from(Grid.step('Home', 3, 2, 5, 4)), [3, 0]);
assert.deepEqual(Array.from(Grid.step('End', 3, 0, 5, 4)), [3, 3]);
assert.deepEqual(Array.from(Grid.step('Home', 3, 2, 5, 4, true)), [0, 0]);
assert.deepEqual(Array.from(Grid.step('End', 0, 0, 5, 4, true)), [4, 3]);
assert.deepEqual(Array.from(Grid.step('PageDown', 1, 1, 50, 4)), [11, 1]);
assert.deepEqual(Array.from(Grid.step('PageUp', 3, 1, 50, 4)), [0, 1]);
assert.equal(Grid.step('a', 0, 0, 5, 4), null);

// The CSV link keeps its filters and follows the visible columns, in order.
assert.equal(Grid.withColumns('/inventory/workspace.csv?q=tea&source=shopify', ['item', 'promise']),
  '/inventory/workspace.csv?q=tea&source=shopify&columns=item%2Cpromise');
assert.equal(Grid.withColumns('/inventory/workspace.csv?q=tea&columns=item', ['location']),
  '/inventory/workspace.csv?q=tea&columns=location');
assert.equal(Grid.withColumns('/inventory/workspace.csv?q=tea&columns=item', []), '/inventory/workspace.csv?q=tea');

console.log('data grid ok');
