import { Controller } from "@hotwired/stimulus"

// Expense and vendor-payment forms: explains in plain words why the form
// cannot be submitted yet, warns when the date falls in a locked period, and
// confirms with the amount, payee and date. The server re-checks everything.

const AMOUNT = /^\d{1,9}(\.\d{1,2})?$/

function money(text) {
  const [whole, fraction = ""] = String(text).trim().split(".")
  const grouped = String(parseInt(whole, 10)).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  return `$${grouped}.${(fraction + "00").slice(0, 2)}`
}

function lockFor(date, locks) {
  if (!date) return null
  return (locks || []).find((lock) => lock.from <= date && date <= lock.to) || null
}

function problems(amount, date, locks) {
  const reasons = []
  const typed = String(amount || "").trim()
  if (typed === "") reasons.push("Enter the amount.")
  else if (!AMOUNT.test(typed)) reasons.push("The amount must be digits with up to two decimals, with no $ sign or commas (for example 1250.50).")
  else if (parseFloat(typed) === 0) reasons.push("The amount must be more than $0.00.")
  if (!date) reasons.push("Choose the date.")
  const lock = lockFor(date, locks)
  if (lock) reasons.push(`${lock.label} is locked, so nothing dated in it can be added or changed. Choose a date outside it, or unlock the period on the Books desk first.`)
  return reasons
}

function fill(template, values) {
  return template.replace(/\{(\w+)\}/g, (_, key) => values[key] ?? "")
}

export default class extends Controller {
  static targets = ["amount", "date", "who", "submit", "reasons"]
  static values = { locks: Array, confirm: String }

  connect() {
    this.sent = false
    this.sync()
  }

  sync() {
    this.reasons = problems(this.amountTarget.value, this.dateTarget.value, this.locksValue)
    this.reasonsTarget.replaceChildren(...this.reasons.map((reason) => {
      const item = document.createElement("li")
      item.textContent = reason
      return item
    }))
    this.reasonsTarget.hidden = this.reasons.length === 0
    if (!this.hasSubmitTarget) return
    this.submitTarget.disabled = this.sent || this.reasons.length > 0
    this.submitTarget.setAttribute("aria-disabled", this.submitTarget.disabled ? "true" : "false")
  }

  who() {
    if (!this.hasWhoTarget) return "(not entered)"
    const target = this.whoTarget
    const text = target.tagName === "SELECT" ? target.options[target.selectedIndex]?.text : target.value
    return (text || "").trim() || "(not entered)"
  }

  confirm(event) {
    this.sync()
    if (this.reasons.length > 0 || this.sent) {
      event.preventDefault()
      return
    }
    const message = fill(this.confirmValue, { amount: money(this.amountTarget.value), who: this.who(), date: this.dateTarget.value })
    if (!window.confirm(message)) {
      event.preventDefault()
      return
    }
    this.sent = true
    if (this.hasSubmitTarget) this.submitTarget.disabled = true
  }
}
