import { Controller } from "@hotwired/stimulus"

// Manual journal entry: live debit/credit totals, a plain-language reason
// whenever the entry cannot be posted, and a confirmation that names the
// amount and date. The server re-checks everything; this only saves a trip.

const AMOUNT = /^\d{1,9}(\.\d{1,2})?$/

function toCents(text) {
  const value = String(text || "").trim()
  if (!AMOUNT.test(value)) return null
  const [whole, fraction = ""] = value.split(".")
  return parseInt(whole, 10) * 100 + parseInt((fraction + "00").slice(0, 2), 10)
}

function money(cents) {
  const sign = cents < 0 ? "−" : ""
  const abs = Math.abs(cents)
  const whole = Math.floor(abs / 100).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  return `${sign}$${whole}.${String(abs % 100).padStart(2, "0")}`
}

function lockFor(date, locks) {
  if (!date) return null
  return (locks || []).find((lock) => lock.from <= date && date <= lock.to) || null
}

// rows: [{ account, debit, credit }] as typed. Returns the totals and every
// reason the entry cannot be posted yet.
function evaluate(rows, date, locks) {
  const reasons = []
  let debits = 0
  let credits = 0
  let used = 0
  rows.forEach((row, index) => {
    const number = index + 1
    const typed = row.account || (row.debit || "").trim() || (row.credit || "").trim()
    if (!typed) return
    used += 1
    const debit = toCents(row.debit)
    const credit = toCents(row.credit)
    const hasDebit = (row.debit || "").trim() !== ""
    const hasCredit = (row.credit || "").trim() !== ""
    if (!row.account) reasons.push(`Line ${number}: choose an account.`)
    if (hasDebit && hasCredit) reasons.push(`Line ${number}: use either Debit or Credit, not both.`)
    else if (!hasDebit && !hasCredit) reasons.push(`Line ${number}: enter a debit or a credit amount.`)
    if (hasDebit && debit === null) reasons.push(`Line ${number}: the debit is not an amount (digits, up to two decimals, no $ or commas).`)
    if (hasCredit && credit === null) reasons.push(`Line ${number}: the credit is not an amount (digits, up to two decimals, no $ or commas).`)
    if ((debit === 0 && !hasCredit) || (credit === 0 && !hasDebit)) reasons.push(`Line ${number}: the amount must be more than $0.00.`)
    debits += debit || 0
    credits += credit || 0
  })
  if (!date) reasons.unshift("Enter the entry date.")
  const lock = lockFor(date, locks)
  if (lock) reasons.unshift(`${lock.label} is locked. Choose a date outside it, or unlock the period on the Books desk first.`)
  if (used < 2 && reasons.length === 0) reasons.push("Enter at least two lines: a debit and a credit.")
  const difference = debits - credits
  if (difference !== 0 && used >= 1) {
    reasons.push(`Out of balance by ${money(Math.abs(difference))}: ${difference > 0 ? "debits exceed credits" : "credits exceed debits"}.`)
  }
  return { debits, credits, difference, reasons, lock }
}

export default class extends Controller {
  static targets = ["row", "date", "memo", "debitTotal", "creditTotal", "difference", "status", "reasons", "submit", "lockNotice", "body", "template"]
  static values = { locks: Array }

  connect() {
    this.submitting = false
    this.sync()
  }

  rows() {
    return this.rowTargets.map((row) => ({
      account: row.querySelector("[data-field=account]").value,
      debit: row.querySelector("[data-field=debit]").value,
      credit: row.querySelector("[data-field=credit]").value
    }))
  }

  sync() {
    const date = this.hasDateTarget ? this.dateTarget.value : ""
    const result = evaluate(this.rows(), date, this.locksValue)
    this.result = result
    this.debitTotalTarget.textContent = money(result.debits)
    this.creditTotalTarget.textContent = money(result.credits)
    this.differenceTarget.textContent = money(Math.abs(result.difference))
    const balanced = result.difference === 0 && result.debits > 0
    this.statusTarget.textContent = balanced ? "Balanced: debits equal credits." : result.debits + result.credits === 0 ? "Nothing entered yet." : `Out of balance by ${money(Math.abs(result.difference))}.`
    this.statusTarget.dataset.balance = balanced ? "ok" : "bad"
    this.reasonsTarget.replaceChildren(...result.reasons.map((reason) => {
      const item = document.createElement("li")
      item.textContent = reason
      return item
    }))
    this.reasonsTarget.hidden = result.reasons.length === 0
    this.submitTarget.disabled = this.submitting || result.reasons.length > 0
    this.submitTarget.setAttribute("aria-disabled", this.submitTarget.disabled ? "true" : "false")
  }

  addLine() {
    this.bodyTarget.insertAdjacentHTML("beforeend", this.templateTarget.innerHTML)
    this.sync()
  }

  confirm(event) {
    this.sync()
    if (this.result.reasons.length > 0) {
      event.preventDefault()
      return
    }
    const memo = this.hasMemoTarget && this.memoTarget.value.trim() ? this.memoTarget.value.trim() : "(no memo)"
    const message = `Post this entry?\n\nDate: ${this.dateTarget.value}\nAmount: ${money(this.result.debits)} debits = ${money(this.result.credits)} credits\nMemo: ${memo}\n\nIt is added to the ledger now and cannot be edited. To correct it later, reverse it.`
    if (!window.confirm(message)) {
      event.preventDefault()
      return
    }
    this.submitting = true
    this.submitTarget.disabled = true
  }
}
