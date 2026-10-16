import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["status", "total"]
  static values = { statusUrl: String }
  connect() { this.generation = 0; this.poll(); this.timer = setInterval(() => this.poll(), 2000) }
  disconnect() { clearInterval(this.timer); clearTimeout(this.timeout); this.abort?.abort() }
  pending() {
    this.generation = (this.generation || 0) + 1
    this.suspended = true
    this.abort?.abort()
    this.statusTarget.textContent = "Cart changing. Customer must review the checked cart."
    this.totalTarget.textContent = ""
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
      this.statusTarget.textContent = !state.active ? "Customer screen closed. Pair a new screen." : !current ? "Cart changed in another window. Check this cart again." : state.confirmed ? "Customer confirmed their tip choice." : "Customer choosing privately…"
      this.totalTarget.textContent = state.active && current && state.confirmed ? `Confirmed tip ${this.money(state.tip_cents)} · preview total before tax ${this.money(state.subtotal_cents + state.tip_cents)}` : ""
    } catch (error) {
      if (generation === this.generation && !this.suspended) {
        this.statusTarget.textContent = "Customer screen connection interrupted. Confirmation cannot be verified."
        this.totalTarget.textContent = ""
      }
    } finally { clearTimeout(this.timeout); this.polling = false }
  }
  money(cents) { return new Intl.NumberFormat(undefined, { style: "currency", currency: "USD" }).format(cents / 100) }
}
