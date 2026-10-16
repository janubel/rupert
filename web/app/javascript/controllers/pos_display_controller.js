import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["status", "total"]
  static values = { statusUrl: String, clearUrl: String }
  connect() { this.poll(); this.timer = setInterval(() => this.poll(), 2000) }
  disconnect() { clearInterval(this.timer); this.abort?.abort() }
  async poll() {
    if (this.polling) return
    this.polling = true
    try {
      this.abort = new AbortController()
      this.timeout = setTimeout(() => this.abort.abort(), 8000)
      const response = await fetch(this.statusUrlValue, { headers: { Accept: "application/json" }, cache: "no-store", signal: this.abort.signal })
      if (!response.ok) throw new Error()
      const state = await response.json()
      this.statusTarget.textContent = !state.active ? "Customer screen closed. Pair a new screen." : state.confirmed ? "Customer confirmed their tip choice." : "Customer choosing privately…"
      this.totalTarget.textContent = state.active && state.confirmed ? `Confirmed tip ${this.money(state.tip_cents)} · preview total before tax ${this.money(state.subtotal_cents + state.tip_cents)}` : ""
    } catch (error) {
      { this.statusTarget.textContent = "Customer screen connection interrupted. Confirmation cannot be verified."; this.totalTarget.textContent = "" }
    } finally { clearTimeout(this.timeout); this.polling = false }
  }
  async clear() {
    await fetch(this.clearUrlValue, { method: "POST", headers: { "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content } })
    this.poll()
  }
  money(cents) { return new Intl.NumberFormat(undefined, { style: "currency", currency: "USD" }).format(cents / 100) }
}
