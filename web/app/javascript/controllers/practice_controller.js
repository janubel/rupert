import { Controller } from "@hotwired/stimulus"

// "Try it with your own numbers": a tiny calculator for a lesson's formula.
// Everything stays on the page; nothing is saved or sent anywhere.
export default class extends Controller {
  static targets = ["a", "b", "result", "explanation"]
  static values = { kind: String }

  connect() {
    this.compute()
  }

  compute() {
    const a = this.number(this.hasATarget ? this.aTarget.value : "")
    const b = this.number(this.hasBTarget ? this.bTarget.value : "")
    const out = this.calculate(this.kindValue, a, b)
    if (this.hasResultTarget) this.resultTarget.textContent = out.result
    if (this.hasExplanationTarget) this.explanationTarget.textContent = out.explanation
  }

  calculate(kind, a, b) {
    switch (kind) {
      case "variance": {
        if (a === null) return { result: "—", explanation: "Enter the counted quantity." }
        if (b === null) return { result: "Unknown", explanation: "An unknown comparison has no numerical variance. It stays unknown; it never becomes zero." }
        const v = a - b
        return { result: `${v > 0 ? "+" : ""}${this.format(v)} units`, explanation: `Variance = counted − comparison = ${this.format(a)} − ${this.format(b)} = ${v > 0 ? "+" : ""}${this.format(v)}. Approval records the count; it does not change platform stock.` }
      }
      case "change": {
        if (a === null || b === null) return { result: "—", explanation: "Enter the total due and the cash received." }
        const c = b - a
        if (c < 0) return { result: `${this.money(-c)} short`, explanation: `${this.money(b)} received is ${this.money(-c)} less than the ${this.money(a)} due. Collect the difference before completing the sale.` }
        return { result: this.money(c), explanation: `Change = cash received − total due = ${this.money(b)} − ${this.money(a)} = ${this.money(c)}. Cash received is not the sale amount.` }
      }
      case "average": {
        if (a === null || b === null) return { result: "—", explanation: "Enter recorded sales and the number of included sales." }
        if (b <= 0) return { result: "—", explanation: "No included sales means the average is unknown, shown as a dash. Check source coverage before treating zero as no activity." }
        return { result: this.money(a / b), explanation: `Average sale = recorded sales ÷ included sales = ${this.money(a)} ÷ ${this.format(b)} = ${this.money(a / b)}.` }
      }
      case "cover": {
        if (a === null || b === null) return { result: "—", explanation: "Enter units on hand and units sold in the last 30 days." }
        if (b <= 0) return { result: "No sales", explanation: "Without recent sales there is no pace to divide by, so cover and a suggestion cannot be estimated." }
        const pace = b / 30
        const cover = a / pace
        const suggested = Math.max(Math.ceil(pace * 30) - a, 0)
        return { result: `${this.format(Math.round(cover * 10) / 10)} days · reorder ${this.format(suggested)}`, explanation: `Pace = ${this.format(b)} ÷ 30 = ${this.format(Math.round(pace * 100) / 100)} per day. Cover = ${this.format(a)} ÷ pace = ${this.format(Math.round(cover * 10) / 10)} days. Suggested = 30 days of pace (${this.format(Math.ceil(pace * 30))}) − ${this.format(a)} on hand = ${this.format(suggested)}, never below zero. Advice only.` }
      }
      default:
        return { result: "—", explanation: "" }
    }
  }

  number(value) {
    if (value === undefined || value === null) return null
    const text = String(value).trim()
    if (text === "") return null
    const n = Number(text.replace(/[^0-9.-]/g, ""))
    return Number.isFinite(n) ? n : null
  }

  format(n) {
    return Number.isInteger(n) ? String(n) : String(Math.round(n * 100) / 100)
  }

  money(n) {
    const cents = Math.round(n * 100)
    const sign = cents < 0 ? "-" : ""
    const abs = Math.abs(cents)
    return `${sign}$${Math.floor(abs / 100)}.${String(abs % 100).padStart(2, "0")}`
  }
}
