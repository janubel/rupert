import { Controller } from "@hotwired/stimulus"

// Cart controller for the full-screen C-Trax cashier (and the retired Shopify preview's
// lookup path). Quantities live here; prices, tax and totals always come from the server
// quote. Optional targets (tax, total, checkout) belong to the full-screen cart panel.
export default class extends Controller {
  static targets = ["form", "items", "status", "subtotal", "tip", "previewTotal", "tipType", "tipPercentage", "tipAmount", "percentageFields", "amountFields", "count", "barcode", "lookupForm", "searchInput", "tax", "total", "checkout"]
  static values = { cartKey: String, initialQuote: Object, clearUrl: String, lookupUrl: String }

  connect() {
    this.cart = new Map()
    this.sequence = 0
    this.lastPrices = new Map()
    this.lastTotals = null
    this.onKeydown = (e) => this.pageKeydown(e)
    document.addEventListener("keydown", this.onKeydown)
    const initial = this.initialQuoteValue.lines
    if (initial) {
      this.lines = initial
      this.tipTypeTarget.value = this.initialQuoteValue.tip_type || "none"
      if (this.initialQuoteValue.tip_percentage) this.setPercentage(this.initialQuoteValue.tip_percentage)
      if (this.initialQuoteValue.tip_type === "custom") this.tipAmountTarget.value = this.initialQuoteValue.tip_amount
      initial.forEach(line => this.cart.set(line.variant_id, line.quantity))
      this.rememberPrices(initial)
      this.rememberTotals(this.initialQuoteValue)
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
    document.removeEventListener("keydown", this.onKeydown)
    this.abort?.abort()
    clearTimeout(this.searchTimer)
  }

  pageKeydown(e) {
    if (this.isTyping(e.target)) return
    if (e.key === "/" && this.hasSearchInputTarget) {
      e.preventDefault()
      this.searchInputTarget.focus()
      this.searchInputTarget.select()
    } else if ((e.key === "b" || e.key === "B") && this.hasBarcodeTarget) {
      e.preventDefault()
      this.barcodeTarget.focus()
    }
  }

  isTyping(el) {
    return el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT" || el.isContentEditable)
  }

  // Instant catalog search: a short pause after typing submits the GET form so
  // results update without clicking Search or losing the input value.
  searchTyped() {
    if (!this.hasSearchInputTarget) return
    clearTimeout(this.searchTimer)
    this.searchTimer = setTimeout(() => {
      const form = this.searchInputTarget.form
      if (form) form.requestSubmit()
    }, 350)
  }

  add(event) {
    event.preventDefault()
    const form = event.target
    if (!form.reportValidity()) return
    const data = new FormData(form)
    const id = data.get("items[0][variant_id]")
    const quantity = Number(data.get("items[0][quantity]"))
    this.addVariant(id, quantity)
  }

  addVariant(id, quantity) {
    if (!id || !Number.isInteger(quantity) || quantity < 1) return
    const total = (this.cart.get(id) || 0) + quantity
    if (total > 999 || (this.cart.size >= 50 && !this.cart.has(id))) {
      this.statusTarget.textContent = "Use at most 50 different variants and 999 units per variant."
      return
    }
    this.cart.set(id, total)
    this.persist()
    this.refresh()
  }

  // Barcode / SKU quick-add. A single available match joins the cart; several
  // matches jump to catalog search; none explains what was scanned.
  async lookup(event) {
    event.preventDefault()
    if (!this.hasBarcodeTarget || !this.hasLookupUrlValue) return
    const q = this.barcodeTarget.value.trim()
    if (!q) {
      this.statusTarget.textContent = "Scan or type a barcode, SKU, product or variant."
      return
    }
    this.statusTarget.textContent = `Looking up “${q}”…`
    try {
      const response = await fetch(this.lookupUrlValue, {
        method: "POST",
        headers: {
          "Accept": "application/json", "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken()
        },
        body: JSON.stringify({ q })
      })
      const result = await response.json()
      if (!response.ok) throw new Error(result.error || "That code could not be looked up.")
      const available = result.matches.filter(match => match.available)
      if (available.length === 1) {
        const match = available[0]
        this.barcodeTarget.value = ""
        this.addVariant(match.variant_id, 1)
        const label = match.title && match.title !== "Default Title" ? `${match.product_title} · ${match.title}` : match.product_title
        this.statusTarget.textContent = `Added ${label} to the cart.`
      } else if (result.matches.length > 1) {
        if (this.hasSearchInputTarget) {
          this.searchInputTarget.value = q
          const form = this.searchInputTarget.form
          if (form) form.requestSubmit()
        }
        this.statusTarget.textContent = `${result.matches.length} items match “${q}”. Pick one from the catalog.`
      } else if (result.matches.length === 1) {
        this.statusTarget.textContent = `“${result.matches[0].product_title}” has no supported catalog price. Use the register instead.`
      } else {
        this.statusTarget.textContent = `No catalog item matches “${q}”.`
      }
    } catch (error) {
      if (error.name === "AbortError") return
      this.statusTarget.textContent = error.message === "Failed to fetch"
        ? "Connection interrupted. Try the scan again."
        : error.message
    }
  }

  tipPreset(event) {
    event.preventDefault()
    const button = event.currentTarget
    const type = button.dataset.tipTypeValue || "none"
    this.tipTypeTarget.value = type
    if (type === "percentage") this.setPercentage(button.dataset.tipPresetValue || "15")
    if (type === "custom") this.tipAmountTarget.value = "0.00"
    this.updateTipInputs()
    this.persist()
    if (this.formTarget.reportValidity()) this.refresh()
  }

  // Quote handoff: a plain-text summary the cashier can paste into the
  // register or notes, and a print of the preview. No payment is taken here.
  async copyQuote(event) {
    event.preventDefault()
    if (!this.cart.size) {
      this.statusTarget.textContent = "Add products before copying a quote."
      return
    }
    try {
      await navigator.clipboard.writeText(this.quoteText())
      this.statusTarget.textContent = "Quote copied. Paste it into your register or notes."
    } catch (_) {
      this.statusTarget.textContent = "Clipboard blocked. Select the quote and copy it manually."
    }
  }

  printQuote(event) {
    event.preventDefault()
    window.print()
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

  // − / + beside a cart line. Going below one leaves the line at one; Remove takes it out.
  step(event) {
    const id = event.currentTarget.closest("[data-variant-id]").dataset.variantId
    const current = this.cart.get(id)
    if (!current) return
    const next = Math.min(999, Math.max(1, current + Number(event.currentTarget.dataset.delta || 0)))
    if (next === current) return
    this.cart.set(id, next)
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
    this.lastPrices = new Map()
    this.lastTotals = null
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
    this.showTotals(null)
    this.statusTarget.textContent = "Checking catalog prices…"
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
    this.showTotals(null)
    if (!this.cart.size) {
      this.lastTotals = null
      this.lastPrices = new Map()
      if (this.hasClearUrlValue) {
        try {
          const cleared = await fetch(this.clearUrlValue, { method: "POST", headers: { "X-CSRF-Token": this.csrfToken() } })
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
          "X-CSRF-Token": this.csrfToken()
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
      this.rememberPrices(result.lines)
      this.rememberTotals(result)
      this.showTotals(result)
      this.render(result.lines)
      this.statusTarget.textContent = result.checkout ? "Prices and tax checked. Ask the customer to confirm their tip, then complete checkout." : "Preview checked. Complete the sale in your existing POS."
    } catch (error) {
      if (error.name === "AbortError" || sequence !== this.sequence) return
      this.statusTarget.textContent = error.message === "Failed to fetch" || error instanceof SyntaxError
        ? "Connection interrupted. Refresh the preview to check current prices."
        : error.message
    }
  }

  // Shows fresh server totals, or the last checked totals prefixed with "~"
  // while a check is in flight, so the cashier always sees an estimate.
  showTotals(result) {
    const totals = result || this.lastTotals
    const prefix = result ? "" : "~"
    const known = (value) => value !== null && value !== undefined && value !== ""
    const show = (target, value) => { target.textContent = known(value) ? prefix + this.amount(value) : "—" }
    show(this.subtotalTarget, totals?.subtotal)
    show(this.tipTarget, totals?.tip_amount ?? totals?.tip)
    show(this.previewTotalTarget, totals?.preview_total ?? totals?.total)
    // Tax and the before-tip total are server cents; unknown tax stays "Unknown", never zero.
    const cents = (value) => known(value) ? Number(value) / 100 : null
    if (this.hasTaxTarget) {
      if (totals && totals.tax_verified === false) this.taxTarget.textContent = "Unknown"
      else show(this.taxTarget, cents(totals?.tax_cents))
    }
    if (this.hasTotalTarget) show(this.totalTarget, cents(totals?.total_before_tip_cents))
  }

  rememberPrices(lines) {
    this.lastPrices = new Map((lines || []).map(line => [line.variant_id, line.unit_price]))
  }

  rememberTotals(quote) {
    if (!quote) { this.lastTotals = null; return }
    this.lastTotals = { subtotal: quote.subtotal, tip: quote.tip_amount, total: quote.preview_total,
      tax_cents: quote.tax_cents, tax_verified: quote.tax_verified, total_before_tip_cents: quote.total_before_tip_cents }
  }

  quoteText() {
    const rows = (this.lines || []).filter(line => line && line.unit_price).map(line => {
      const label = line.title && line.title !== "Default Title" ? `${line.product_title} · ${line.title}` : line.product_title
      return `${line.quantity} × ${label} — ${this.amount(line.line_total)}`
    })
    rows.push(`Subtotal — ${this.amount(this.lastTotals?.subtotal ?? this.subtotalTarget.textContent.replace(/^~/, ""))}`)
    rows.push(`Tip — ${this.amount(this.lastTotals?.tip ?? this.tipTarget.textContent.replace(/^~/, ""))}`)
    rows.push(`Preview total before tax — ${this.amount(this.lastTotals?.total ?? this.previewTotalTarget.textContent.replace(/^~/, ""))}`)
    rows.push("Preview only: creates no sale, payment, receipt or stock reservation.")
    return ["POS preview quote", ...rows].join("\n")
  }

  render(lines) {
    const units = Array.from(this.cart.values()).reduce((total, quantity) => total + quantity, 0)
    if (this.hasCountTarget) this.countTargets.forEach(target => { target.textContent = units })
    if (this.hasCheckoutTarget) this.checkoutTargets.forEach(button => { button.disabled = !this.cart.size })
    const byId = new Map(lines.map(line => [line.variant_id, line]))
    const previousPrices = this.lastPrices || new Map()
    this.itemsTarget.replaceChildren()
    if (!this.cart.size) {
      const empty = document.createElement("p")
      empty.className = "pos-cart-empty"
      empty.textContent = "The cart is empty. Search, scan or tap a product to add it."
      this.itemsTarget.append(empty)
      return
    }
    Array.from(this.cart).forEach(([id, quantity], index) => {
      const line = byId.get(id)
      const name = line ? line.product_title : "Checking item…"
      const variant = line ? this.variantLabel(line.product_title, line.title) : ""
      const row = document.createElement("div")
      row.dataset.variantId = id
      row.className = "pos-line"

      const media = document.createElement("span")
      media.className = "pos-line-thumb"
      if (line?.thumbnail_url) {
        const image = document.createElement("img")
        image.src = line.thumbnail_url
        image.alt = ""
        image.referrerPolicy = "no-referrer"
        media.append(image)
      }

      const main = document.createElement("div")
      main.className = "pos-line-main"
      const title = document.createElement("p")
      title.className = "pos-line-name"
      title.textContent = name
      const detail = document.createElement("p")
      detail.className = "pos-line-detail"
      const priceChanged = line && previousPrices.has(id) && previousPrices.get(id) !== line.unit_price
      detail.textContent = [variant, line ? `${this.amount(line.unit_price)} each` : "Price pending", priceChanged ? "price updated" : ""].filter(Boolean).join(" · ")

      const controls = document.createElement("div")
      controls.className = "pos-line-controls"
      const stepper = document.createElement("div")
      stepper.className = "pos-stepper pos-stepper-sm"
      stepper.setAttribute("role", "group")
      stepper.setAttribute("aria-label", `Quantity for ${name}`)
      const stepButton = (delta, text, label) => {
        const button = document.createElement("button")
        button.type = "button"
        button.className = "pos-step"
        button.textContent = text
        button.dataset.delta = String(delta)
        button.dataset.action = "pos-cart#step"
        button.setAttribute("aria-label", label)
        return button
      }
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
      input.inputMode = "numeric"
      input.className = "pos-step-input"
      input.setAttribute("aria-label", `Cart quantity for ${name}`)
      input.dataset.action = "change->pos-cart#change"
      stepper.append(stepButton(-1, "−", `One fewer ${name}`), input, stepButton(1, "+", `One more ${name}`))
      const remove = document.createElement("button")
      remove.type = "button"
      remove.textContent = "Remove"
      remove.setAttribute("aria-label", `Remove ${name} from cart`)
      remove.className = "pos-line-remove"
      remove.dataset.action = "pos-cart#remove"
      controls.append(stepper, remove)
      main.append(title, detail, controls)

      const total = document.createElement("strong")
      total.className = "pos-line-total retail-money"
      total.textContent = line ? this.amount(line.line_total) : "—"
      row.append(media, main, hidden, total)
      this.itemsTarget.append(row)
    })
  }

  // "Tea Tin 30ml" under "Tea Tin" reads "30ml"; a name that does not extend the product stays whole.
  variantLabel(product, title) {
    if (!title || title === "Default Title" || title === product) return ""
    if (product && title.toLowerCase().startsWith(product.toLowerCase())) {
      return title.slice(product.length).replace(/^[\s\-–—·:,|\/]+/, "").trim()
    }
    return title
  }

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }

  // Quotes on this screen are USD (C-Trax source prices); shown as $1,234.56.
  amount(value) {
    const number = Number(value)
    return Number.isFinite(number)
      ? new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(number)
      : "—"
  }
}
