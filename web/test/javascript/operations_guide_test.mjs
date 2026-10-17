import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'

const source = readFileSync(new URL('../../app/javascript/controllers/page_guide_controller.js', import.meta.url), 'utf8')
  .replace('import { Controller } from "@hotwired/stimulus"', '')
  .replace('export default class', 'globalThis.Guide = class')
let opened = false
let stored = []
const context = vm.createContext({ Controller: class {}, window: { matchMedia: () => ({ matches: false }) }, localStorage: { getItem: () => null, setItem: (...args) => stored.push(args) } })
vm.runInContext(source, context)
const guide = new context.Guide()
guide.autoOpenValue = false
guide.hasAutoKeyValue = true
guide.autoKeyValue = '/sales'
guide.open = () => { opened = true }
guide.connect()
assert.equal(opened, false)
assert.deepEqual(stored, [])
guide.autoOpenValue = true
guide.connect()
assert.equal(opened, true)
assert.equal(stored[0][0], 'rupert-guide-seen:/sales')
console.log('Operations guidance remains optional; other first-visit guidance still opens and records its seen state.')
