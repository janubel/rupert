import { Controller } from "@hotwired/stimulus"

// Per-employee show/hide for the timesheet week grid. Choices are remembered in
// this browser only; nothing about the employee record changes.
export default class extends Controller {
  static targets = ["toggle", "block", "count", "scroller"]
  static values = { key: { type: String, default: "timesheet-calendar-hidden" } }

  connect() {
    this.hidden = new Set(this.load())
    this.apply()
    if (this.hasScrollerTarget) this.scrollerTarget.scrollTop = this.scrollerTarget.scrollHeight * (6.5 / 24)
  }

  toggle(event) {
    const id = event.currentTarget.dataset.employeeId
    this.hidden.has(id) ? this.hidden.delete(id) : this.hidden.add(id)
    this.save()
    this.apply()
  }

  showAll() { this.hidden.clear(); this.save(); this.apply() }

  hideAll() {
    this.toggleTargets.forEach((t) => this.hidden.add(t.dataset.employeeId))
    this.save()
    this.apply()
  }

  apply() {
    this.toggleTargets.forEach((t) => {
      const off = this.hidden.has(t.dataset.employeeId)
      t.setAttribute("aria-pressed", String(!off))
      t.classList.toggle("opacity-40", off)
      t.classList.toggle("line-through", off)
    })
    let shown = 0
    this.blockTargets.forEach((b) => {
      const off = this.hidden.has(b.dataset.employeeId)
      b.hidden = off
      if (!off) shown += 1
    })
    if (this.hasCountTarget) this.countTarget.textContent = `${shown} shift${shown === 1 ? "" : "s"} shown`
  }

  load() {
    try { return JSON.parse(localStorage.getItem(this.keyValue) || "[]") } catch { return [] }
  }

  save() {
    try { localStorage.setItem(this.keyValue, JSON.stringify([...this.hidden])) } catch { /* private mode */ }
  }
}
