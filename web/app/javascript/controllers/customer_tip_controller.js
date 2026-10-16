import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["items", "subtotal", "choices", "custom", "confirm", "status"]
  static values = { stateUrl: String, tipUrl: String }
  connect() { this.revision = null; this.poll(); this.timer = setInterval(() => this.poll(), 1500) }
  disconnect() { clearInterval(this.timer); this.abort?.abort() }
  money(cents) { return new Intl.NumberFormat(undefined, { style: "currency", currency: "USD" }).format(cents / 100) }
  async poll() {
    if (this.polling) return
    this.polling = true
    try {
      this.abort = new AbortController()
      this.timeout = setTimeout(() => this.abort.abort(), 8000)
      const response = await fetch(this.stateUrlValue, { cache: "no-store", signal: this.abort.signal })
      if (!response.ok) throw new Error(response.status === 410 ? "This customer screen has closed. Ask the cashier to pair it again." : "Connection interrupted. Please wait before confirming.")
      const state = await response.json()
      if (!state.active) throw new Error("This customer screen has closed.")
      this.connected = true
      if (this.revision !== state.cart_revision) {
        this.revision = state.cart_revision
        this.element.querySelectorAll('input[name="choice"]').forEach(input => input.checked = false)
        this.customTarget.hidden = true
        this.customTarget.querySelector('input').required = false
        this.customTarget.querySelector('input').value = ''
        this.itemsTarget.replaceChildren()
        state.lines.forEach(line => {
          const row = document.createElement("div"); row.className = "flex items-center gap-3"
          if (line.thumbnail_url) { const img = document.createElement("img"); img.src = line.thumbnail_url; img.alt = line.product_title; img.referrerPolicy = "no-referrer"; img.className = "h-16 w-16 rounded-lg object-contain"; row.append(img) }
          const text = document.createElement("p"); text.className = "text-sm"; text.textContent = `${line.product_title} · ${line.quantity} × ${line.unit_price}`; row.append(text); this.itemsTarget.append(row)
        })
      }
      this.subtotalTarget.textContent = this.money(state.subtotal_cents)
      this.hasCart = state.lines.length > 0
      this.confirmed = state.confirmed
      this.choicesTarget.disabled = state.confirmed || !this.hasCart
      this.confirmTarget.disabled = state.confirmed || !this.hasCart
      this.confirmTarget.textContent = state.confirmed ? "Choice confirmed" : "Confirm my choice"
      this.statusTarget.textContent = state.confirmed ? `Thank you. Your tip choice of ${this.money(state.tip_cents)} is confirmed.` : this.hasCart ? "Your tip choice stays private until you confirm." : "Waiting for the cashier’s cart…"
    } catch (error) {
      this.connected = false; this.confirmTarget.disabled = true; this.statusTarget.textContent = error.name === "AbortError" ? "Connection interrupted. Please wait before confirming." : error.message
    } finally { clearTimeout(this.timeout); this.polling = false }
  }
  choiceChanged(event) {
    this.customTarget.hidden = event.target.value !== "custom"
    this.customTarget.querySelector("input").required = event.target.value === "custom"
    this.confirmTarget.disabled = !this.connected || !this.hasCart || this.confirmed
  }
  async confirm(event) {
    event.preventDefault()
    if (!this.connected || !event.target.reportValidity()) return
    this.confirmTarget.disabled = true
    const form = new FormData(event.target)
    try {
      const response = await fetch(this.tipUrlValue, { method: "POST", headers: { "Content-Type": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content }, body: JSON.stringify({ cart_revision: this.revision, choice: form.get("choice"), amount: form.get("amount") }) })
      const result = await response.json()
      if (!response.ok) throw new Error(result.error || "Confirmation could not be saved.")
      this.poll()
    } catch (error) { this.statusTarget.textContent = error.message; this.confirmTarget.disabled = !this.connected }
  }
}
