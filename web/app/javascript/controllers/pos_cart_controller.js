import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "items", "status", "subtotal", "tip", "previewTotal", "tipType", "tipPercentage", "tipAmount", "percentageFields", "amountFields", "count"]
  static values = { cartKey: String, initialQuote: Object, clearUrl: String }

  connect() {
    this.cart = new Map()
    this.sequence = 0
    const initial = this.initialQuoteValue.lines
    if (initial) {
      this.lines = initial
      this.tipTypeTarget.value = this.initialQuoteValue.tip_type || "none"
      if (this.initialQuoteValue.tip_percentage) this.setPercentage(this.initialQuoteValue.tip_percentage)
      if (this.initialQuoteValue.tip_type === "custom") this.tipAmountTarget.value = this.initialQuoteValue.tip_amount
      initial.forEach(line => this.cart.set(line.variant_id, line.quantity))
      this.updateTipInputs()
      this.persist()
      this.render(initial)
      if (this.hasClearUrlValue && this.cart.size) this.refresh()
    } else {
      try {
        const saved = JSON.parse(sessionStorage.getItem(this.cartKeyValue) || "[]")
        if (Array.isArray(saved)) saved.slice(0, 50).forEach(([id, quantity]) => {
          if (typeof id === "string" && Number.isInteger(quantity) && quantity > 0 && quantity <= 999) this.cart.set(id, quantity)
        })
        const tip = JSON.parse(sessionStorage.getItem(`${this.cartKeyValue}:tip`) || "null")
        if (tip && ["none", "percentage", "custom"].includes(tip.type)) {
          this.tipTypeTarget.value = tip.type
          this.setPercentage(tip.percentage || "15")
          this.tipAmountTarget.value = tip.amount || "0.00"
        }
      } catch (_) { /* Storage is optional; the preview still works in memory. */ }
      this.updateTipInputs()
      this.render([])
      if (this.cart.size) this.refresh()
    }
  }

  disconnect() {
    this.abort?.abort()
  }

  add(event) {
    event.preventDefault()
    const form = event.target
    if (!form.reportValidity()) return
    const data = new FormData(form)
    const id = data.get("items[0][variant_id]")
    const quantity = Number(data.get("items[0][quantity]"))
    const total = (this.cart.get(id) || 0) + quantity
    if (total > 999 || (this.cart.size >= 50 && !this.cart.has(id))) {
      this.statusTarget.textContent = "Use at most 50 different variants and 999 units per variant."
      return
    }
    this.cart.set(id, total)
    this.persist()
    this.refresh()
  }

  quote(event) {
    event.preventDefault()
    if (this.formTarget.reportValidity()) this.refresh()
    else this.invalidate()
  }

  change(event) {
    const id = event.target.closest("[data-variant-id]").dataset.variantId
    const quantity = Number(event.target.value)
    if (!Number.isInteger(quantity) || quantity < 1 || quantity > 999) {
      this.invalidate()
      this.statusTarget.textContent = "Each quantity must be a whole number from 1 to 999."
      return
    }
    this.cart.set(id, quantity)
    this.persist()
    this.refresh()
  }

  remove(event) {
    const id = event.target.closest("[data-variant-id]").dataset.variantId
    this.cart.delete(id)
    this.persist()
    this.refresh()
  }

  clear() {
    this.cart.clear()
    this.tipTypeTarget.value = "none"
    this.tipPercentageTarget.value = "15"
    this.tipAmountTarget.value = "0.00"
    this.updateTipInputs()
    this.persist()
    this.refresh()
  }

  persist() {
    try {
      sessionStorage.setItem(this.cartKeyValue, JSON.stringify(Array.from(this.cart)))
      sessionStorage.setItem(`${this.cartKeyValue}:tip`, JSON.stringify({ type: this.tipTypeTarget.value, percentage: this.tipPercentageTarget.value, amount: this.tipAmountTarget.value }))
    } catch (_) { /* Optional tab storage. */ }
  }

  tipChanged() {
    this.invalidate()
    this.updateTipInputs()
    this.persist()
    if (this.formTarget.reportValidity()) this.refresh()
  }

  invalidate() {
    this.dispatch("changing")
    this.abort?.abort()
    ++this.sequence
    this.subtotalTarget.textContent = "—"
    this.tipTarget.textContent = "—"
    this.previewTotalTarget.textContent = "—"
    this.statusTarget.textContent = "Refresh the preview after correcting the cart."
  }

  setPercentage(raw) {
    const value = String(Number(raw))
    if (!/^\d{1,3}(\.\d{1,6})?$/.test(value) || Number(value) > 100) return
    if (!Array.from(this.tipPercentageTarget.options).some(option => option.value === value)) {
      const option = document.createElement("option")
      option.value = value
      option.textContent = `${value}%`
      this.tipPercentageTarget.append(option)
    }
    this.tipPercentageTarget.value = value
  }

  updateTipInputs() {
    const percentage = this.tipTypeTarget.value === "percentage"
    const custom = this.tipTypeTarget.value === "custom"
    this.percentageFieldsTarget.hidden = !percentage
    this.amountFieldsTarget.hidden = !custom
    this.tipPercentageTarget.disabled = !percentage
    this.tipAmountTarget.disabled = !custom
    this.tipAmountTarget.required = custom
  }

  async refresh() {
    this.dispatch("changing")
    this.abort?.abort()
    const sequence = ++this.sequence
    this.subtotalTarget.textContent = "—"
    this.tipTarget.textContent = "—"
    this.previewTotalTarget.textContent = "—"
    if (!this.cart.size) {
      if (this.hasClearUrlValue) {
        try {
          const cleared = await fetch(this.clearUrlValue, { method: "POST", headers: { "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" } })
          if (!cleared.ok) throw new Error()
        } catch (_) {
          this.statusTarget.textContent = "Customer cart could not be cleared. Close the customer screen before proceeding."
          return
        }
      }
      this.dispatch("checked", { detail: { revision: null } })
      this.render([])
      this.statusTarget.textContent = "Choose products to build a preview."
      return
    }
    this.render(this.lines || [])
    this.statusTarget.textContent = "Checking catalog prices…"
    this.abort = new AbortController()
    try {
      const response = await fetch(this.formTarget.action, {
        method: "POST", signal: this.abort.signal,
        headers: {
          "Accept": "application/json", "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify({
          items: Array.from(this.cart, ([variant_id, quantity]) => ({ variant_id, quantity })),
          tip_type: this.tipTypeTarget.value, tip_percentage: this.tipPercentageTarget.value, tip_amount: this.tipAmountTarget.value
        })
      })
      const result = await response.json()
      if (sequence !== this.sequence) return
      if (!response.ok) throw new Error(result.error || "The preview could not be checked.")
      this.dispatch("checked", { detail: { revision: result.display_revision } })
      this.lines = result.lines
      this.render(result.lines)
      this.subtotalTarget.textContent = this.amount(result.subtotal)
      this.tipTarget.textContent = this.amount(result.tip_amount)
      this.previewTotalTarget.textContent = this.amount(result.preview_total)
      this.statusTarget.textContent = result.checkout ? "Prices and tax checked. Ask the customer to confirm their tip, then complete checkout." : "Preview checked. Complete the sale in your existing POS."
    } catch (error) {
      if (error.name === "AbortError" || sequence !== this.sequence) return
      this.statusTarget.textContent = error.message === "Failed to fetch" || error instanceof SyntaxError
        ? "Connection interrupted. Refresh the preview to check current prices."
        : error.message
    }
  }

  render(lines) {
    if (this.hasCountTarget) this.countTargets.forEach(target => { target.textContent = Array.from(this.cart.values()).reduce((total, quantity) => total + quantity, 0) })
    const byId = new Map(lines.map(line => [line.variant_id, line]))
    this.itemsTarget.replaceChildren()
    if (!this.cart.size) {
      const empty = document.createElement("p")
      empty.className = "text-sm text-taupe"
      empty.textContent = "Your cart is empty. Add a product to begin."
      this.itemsTarget.append(empty)
      return
    }
    Array.from(this.cart).forEach(([id, quantity], index) => {
      const line = byId.get(id)
      const row = document.createElement("div")
      row.dataset.variantId = id
      row.className = "rounded-xl border border-fog p-3 space-y-2"
      if (line?.thumbnail_url) {
        const image = document.createElement("img")
        image.src = line.thumbnail_url
        image.alt = line.product_title
        image.className = "h-16 w-16 rounded-lg object-contain"
        row.append(image)
      }
      const title = document.createElement("p")
      title.className = "text-sm font-medium"
      title.textContent = line ? `${line.product_title} · ${line.title}` : "Catalog item awaiting validation"
      const hidden = document.createElement("input")
      hidden.type = "hidden"
      hidden.name = `items[${index}][variant_id]`
      hidden.value = id
      const input = document.createElement("input")
      input.type = "number"
      input.name = `items[${index}][quantity]`
      input.value = quantity
      input.min = "1"
      input.max = "999"
      input.step = "1"
      input.required = true
      input.className = "input w-24"
      input.setAttribute("aria-label", `Cart quantity for ${line?.product_title || "item"}`)
      input.dataset.action = "change->pos-cart#change"
      const price = document.createElement("p")
      price.className = "text-sm text-mocha"
      price.textContent = line ? `${this.amount(line.unit_price)} each · ${this.amount(line.line_total)} previously checked` : "Price pending"
      const remove = document.createElement("button")
      remove.type = "button"
      remove.textContent = "Remove"
      remove.setAttribute("aria-label", `Remove ${line?.product_title || "item"} from cart`)
      remove.className = "btn-ghost btn-sm"
      remove.dataset.action = "pos-cart#remove"
      row.append(title, hidden, input, price, remove)
      this.itemsTarget.append(row)
    })
  }

  amount(value) {
    return new Intl.NumberFormat(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(Number(value))
  }
}
