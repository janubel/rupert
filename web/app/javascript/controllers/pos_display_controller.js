import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  // tip, grandTotal and totalRow are the cart panel's Tip and Total rows (optional).
  static targets = ["status", "total", "tip", "grandTotal", "totalRow"]
  static values = { statusUrl: String }
  connect() { this.generation = 0; this.poll(); this.timer = setInterval(() => this.poll(), 2000) }
  disconnect() { clearInterval(this.timer); clearTimeout(this.timeout); this.abort?.abort() }
  pending() {
    this.generation = (this.generation || 0) + 1
    this.suspended = true
    this.abort?.abort()
    this.statusTarget.textContent = "Cart changing. Customer must review the checked cart."
    this.totalTarget.textContent = ""
    this.showConfirmed(null, null)
  }
  checked(event) {
    this.generation = (this.generation || 0) + 1
    this.revision = event.detail.revision
    this.suspended = false
    this.statusTarget.textContent = "Checking customer confirmation…"
    this.poll()
  }
  async poll() {
    if (this.polling || this.suspended) return
    this.polling = true
    const generation = this.generation
    try {
      this.abort = new AbortController()
      this.timeout = setTimeout(() => this.abort.abort(), 8000)
      const response = await fetch(this.statusUrlValue, { headers: { Accept: "application/json" }, cache: "no-store", signal: this.abort.signal })
      if (!response.ok) throw new Error()
      const state = await response.json()
      if (generation !== this.generation || this.suspended) return
      const current = this.revision == null || state.cart_revision === this.revision
      const confirmed = state.active && current && state.confirmed
      const totalCents = confirmed ? (state.checkout?.total_cents ?? state.subtotal_cents + (state.tax_cents || 0) + state.tip_cents) : null
      this.element.dispatchEvent(new CustomEvent("pos-display:state", { detail: { checkout: current ? state.checkout : null, totalCents }, bubbles: true }))
      this.showConfirmed(confirmed ? state.tip_cents : null, totalCents)
      this.statusTarget.textContent = !state.active ? "Customer screen closed. Pair a new screen." : !current ? "Cart changed in another window. Check this cart again." : state.checkout?.status === "paid" ? "Paid receipt created." : ["processing", "unknown"].includes(state.checkout?.status) ? "Payment is being verified. Do not collect another payment." : state.confirmed ? "Customer confirmed their tip choice." : "Customer choosing privately…"
      this.totalTarget.textContent = state.active && current && state.confirmed ? `Confirmed tip ${this.money(state.tip_cents)} · total ${this.money(state.checkout?.total_cents ?? state.subtotal_cents + (state.tax_cents || 0) + state.tip_cents)}` : ""
    } catch (error) {
      if (generation === this.generation && !this.suspended) {
        this.statusTarget.textContent = "Customer screen connection interrupted. Confirmation cannot be verified."
        this.totalTarget.textContent = ""
        this.showConfirmed(null, null)
      }
    } finally { clearTimeout(this.timeout); this.polling = false }
  }
  // The customer's confirmed tip and the total due, or "Customer chooses" until then.
  showConfirmed(tipCents, totalCents) {
    if (this.hasTipTarget) this.tipTarget.textContent = tipCents == null ? "Customer chooses" : this.money(tipCents)
    if (this.hasGrandTotalTarget) this.grandTotalTarget.textContent = totalCents == null ? "" : this.money(totalCents)
    if (this.hasTotalRowTarget) this.totalRowTarget.toggleAttribute("data-confirmed", totalCents != null)
  }
  money(cents) { return new Intl.NumberFormat(undefined, { style: "currency", currency: "USD" }).format(cents / 100) }
}
