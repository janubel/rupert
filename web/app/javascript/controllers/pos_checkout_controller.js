import { Controller } from "@hotwired/stimulus"
export default class extends Controller {
  static targets = ["tender", "cashFields", "cash", "submit", "status", "result"]
  static values = { url: String, displayId: Number }
  connect() { this.tenderChanged(); this.stateListener = event => this.renderCheckout(event.detail.checkout); this.element.closest('[data-controller~="pos-display"]')?.addEventListener('pos-display:state', this.stateListener) }
  disconnect() { this.element.closest('[data-controller~="pos-display"]')?.removeEventListener('pos-display:state', this.stateListener) }
  tenderChanged() { const cash = this.tenderTarget.value === "cash"; this.cashFieldsTarget.hidden = !cash; this.cashTarget.required = cash }
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
    finally { this.submitting = false; this.submitTarget.disabled = false }
  }
  renderCheckout(result) {
      if (!result) { if (this.lastReceipt) { this.resultTarget.replaceChildren(); this.statusTarget.textContent = ""; this.lastReceipt = null }; return }
      const signature = JSON.stringify(result)
      if (signature === this.lastReceipt) return
      this.lastReceipt = signature
      this.statusTarget.textContent = result.status === "paid" ? `${result.demo ? "Demo completed" : "Paid"} · ${this.money(result.total_cents)}${result.tender === "cash" ? ` · Change ${this.money(result.change_cents)}` : ""}${result.inventory_pending ? " · Stock update pending verification" : ""}` : ["processing", "unknown"].includes(result.status) ? "Payment is unresolved. Check the receipt/gateway; do not submit another charge." : "Customer can now pay privately on their screen."
      this.resultTarget.replaceChildren()
      if (result.status === "paid") { const text = document.createElement("p"); text.className = "text-xs"; text.textContent = `Receipt ${result.reference}. Clear the cart to start a new sale.`; this.resultTarget.append(text); const link = document.createElement("a"); link.href = `${this.urlValue}/${result.id}`; link.textContent = "Open receipt"; link.target = "_blank"; link.className = "btn-ghost"; this.resultTarget.append(link) }
      else if (["ready", "declined"].includes(result.status)) { const cancel = document.createElement("button"); cancel.type = "button"; cancel.className = "btn-ghost"; cancel.textContent = "Cancel unpaid checkout"; cancel.addEventListener("click", async () => { const response = await fetch(`${this.urlValue}/${result.id}/cancel`, { method: "POST", headers: { "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content } }); if (response.ok) window.location.reload(); else this.statusTarget.textContent = "Payment cannot be cancelled. Check the gateway status." }); this.resultTarget.append(cancel) }
  }
  money(cents) { return new Intl.NumberFormat(undefined, { style: "currency", currency: "USD" }).format(cents / 100) }
}
