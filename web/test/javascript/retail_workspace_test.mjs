import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const element = () => ({ dataset: {}, children: [], setAttribute(name, value) { this[name] = value; }, append(...children) { this.children.push(...children); }, replaceChildren(...children) { this.children = children; } });
const context = { document: { createElement: element }, Intl };
vm.createContext(context);
for (const [file, name] of [['pos_cart', 'Cart'], ['pos_checkout', 'Checkout']]) {
  const source = readFileSync(new URL(`../../app/javascript/controllers/${file}_controller.js`, import.meta.url), 'utf8')
    .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
    .replace('export default class', `globalThis.${name} = class`);
  vm.runInContext(`{${source}}`, context);
}
const cart = new context.Cart();
cart.itemsTarget = element();
cart.hasCountTarget = true;
cart.countTargets = [{}, {}];
cart.cart = new Map([['tea', 2], ['coffee', 3]]);
cart.render([]);
assert.equal(cart.countTargets[0].textContent, 5);
assert.equal(cart.countTargets[1].textContent, 5);
assert.equal(cart.itemsTarget.children.length, 2);
cart.cart.clear();
cart.render([]);
assert.equal(cart.countTargets[0].textContent, 0);
cart.hasCountTarget = false;
cart.render([]); // Existing preview and embedded demos need no counter target.
const checkout = new context.Checkout();
checkout.tenderTarget = { value: 'cash' };
checkout.cashFieldsTarget = {};
checkout.cashTarget = {};
checkout.submitTarget = {};
checkout.demoValue = false;
checkout.tenderChanged();
assert.equal(checkout.submitTarget.value, 'Complete cash sale');
assert.equal(checkout.cashTarget.required, true);
checkout.tenderTarget.value = 'card';
checkout.tenderChanged();
assert.equal(checkout.submitTarget.value, 'Send card checkout');
assert.equal(checkout.cashFieldsTarget.hidden, true);
assert.equal(checkout.cashTarget.required, false);
checkout.demoValue = true;
checkout.tenderChanged();
assert.equal(checkout.submitTarget.value, 'Send demo card checkout');
console.log('Retail cart counters sum units; checkout labels track tender and demo state without submitting.');
