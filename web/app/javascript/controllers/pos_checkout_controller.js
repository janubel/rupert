import { Controller } from "@hotwired/stimulus"

// Checkout step of the cashier cart. Sends only the display, tender, register and cash
// physically received; the server takes the amount from the frozen checkout. Cash and Card
// are two big buttons over one hidden tender field; an unavailable tender stays disabled.
export default class extends Controller {
  static targets = ["tender", "tenderButton", "cashFields", "cash", "exact", "submit", "status", "result"]
  static values = { url: String, displayId: Number, demo: Boolean }

  connect() {
    this.tenderChanged()
    this.stateListener = event => {
      this.totalCents = event.detail.totalCents ?? null
      if (this.hasExactTarget) this.exactTarget.disabled = this.totalCents == null
      this.renderCheckout(event.detail.checkout)
    }
    this.element.closest('[data-controller~="pos-display"]')?.addEventListener('pos-display:state', this.stateListener)
  }

  disconnect() { this.element.closest('[data-controller~="pos-display"]')?.removeEventListener('pos-display:state', this.stateListener) }

  choose(event) {
    if (event.currentTarget.disabled) return
    this.tenderTarget.value = event.currentTarget.dataset.tender
    this.tenderChanged()
    if (this.tenderTarget.value === "cash") this.cashTarget.focus()
    else this.submitTarget.focus()
  }

  tenderChanged() {
    const tender = this.tenderTarget.value
    const cash = tender === "cash"
    const available = this.tenderButtonTargets.find(button => button.dataset.tender === tender)?.dataset.available !== "false"
    this.tenderButtonTargets.forEach(button => button.setAttribute("aria-pressed", String(button.dataset.tender === tender)))
    this.cashFieldsTarget.hidden = !cash
    this.cashTarget.required = cash
    this.submitTarget.value = this.demoValue ? (cash ? "Run demo cash checkout" : "Send demo card checkout") : (cash ? "Complete cash sale" : "Send card checkout to customer screen")
    this.submitTarget.disabled = !available
  }

  // Quick cash: the customer-confirmed total (server cents) or a common bill.
  exact() {
    if (this.totalCents == null) return
    this.cashTarget.value = (this.totalCents / 100).toFixed(2)
    this.submitTarget.focus()
  }

  quick(event) {
    this.cashTarget.value = Number(event.currentTarget.dataset.amount).toFixed(2)
    this.submitTarget.focus()
  }

  async submit(event) {
    event.preventDefault()
    if (!event.target.reportValidity() || this.submitting) return
    this.submitting = true; this.submitTarget.disabled = true; this.statusTarget.textContent = "Checking source totals and payment…"
    const form = new FormData(event.target)
    try {
      const response = await fetch(this.urlValue, { method: "POST", headers: { Accept: "application/json", "Content-Type": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" }, body: JSON.stringify({ display_id: this.displayIdValue, tender: form.get("tender"), register_id: form.get("register_id"), cash_received: form.get("cash_received") }) })
      const result = await response.json()
      if (!response.ok) throw new Error(result.error || "Checkout could not be verified. Check the receipt before retrying.")
      this.renderCheckout(result)
    } catch (error) { this.statusTarget.textContent = error.message }
    finally { this.submitting = false; this.tenderChanged() }
  }

  renderCheckout(result) {
    if (!result) { if (this.lastReceipt) { this.resultTarget.replaceChildren(); this.statusTarget.textContent = ""; this.lastReceipt = null }; return }
    const signature = JSON.stringify(result)
    if (signature === this.lastReceipt) return
    this.lastReceipt = signature
    this.statusTarget.textContent = result.status === "paid" ? `${result.sandbox ? "Sandbox completed" : (result.demo ? "Demo completed" : "Paid")} · ${this.money(result.total_cents)}${result.tender === "cash" ? ` · Change ${this.money(result.change_cents)}` : ""}${result.inventory_pending ? " · Stock update pending verification" : ""}` : ["processing", "unknown"].includes(result.status) ? "Payment is unresolved. Check the receipt/gateway; do not submit another charge." : "Customer can now pay privately on their screen."
    this.resultTarget.replaceChildren()
    if (result.status === "paid") {
      const text = document.createElement("p"); text.className = "pos-checkout-hint"; text.textContent = `Receipt ${result.reference}.`; this.resultTarget.append(text)
      if (result.tender === "cash" && result.change_cents != null) {
        const change = document.createElement("p"); change.className = "pos-change retail-money"; change.textContent = `Change due ${this.money(result.change_cents)}`; this.resultTarget.append(change)
      }
      const actions = document.createElement("div"); actions.className = "pos-checkout-actions"
      const next = document.createElement("button"); next.type = "button"; next.className = "btn-primary btn-lg"; next.textContent = "New sale"; next.dataset.action = "pos-cart#clear pos-screen#newSale"
      const link = document.createElement("a"); link.href = `${this.urlValue}/${result.id}`; link.textContent = "Open receipt"; link.target = "_blank"; link.rel = "noopener"; link.className = "btn-ghost btn-lg"
      actions.append(next, link); this.resultTarget.append(actions)
    }
    else if (["ready", "declined"].includes(result.status)) { const cancel = document.createElement("button"); cancel.type = "button"; cancel.className = "btn-ghost"; cancel.textContent = "Cancel unpaid checkout"; cancel.addEventListener("click", async () => { const response = await fetch(`${this.urlValue}/${result.id}/cancel`, { method: "POST", headers: { "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content } }); if (response.ok) window.location.reload(); else this.statusTarget.textContent = "Payment cannot be cancelled. Check the gateway status." }); this.resultTarget.append(cancel) }
  }

  money(cents) { return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(cents / 100) }
}
