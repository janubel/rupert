import { Controller } from "@hotwired/stimulus"

// Bank statement review: keeps a live count of chosen lines in the save bar,
// can pre-fill the keyword suggestions (a person still presses Save), and
// warns before leaving the page with choices that were not saved.
export default class extends Controller {
  static targets = ["choice", "count", "save", "fill", "bulk"]

  connect() {
    this.submitting = false
    this.beforeUnload = (event) => {
      if (this.submitting || this.chosen().length === 0) return
      event.preventDefault()
      event.returnValue = ""
    }
    window.addEventListener("beforeunload", this.beforeUnload)
    this.buildBulk()
    this.sync()
  }

  disconnect() {
    window.removeEventListener("beforeunload", this.beforeUnload)
  }

  // The bulk picker offers the choices of the fullest line picker (a deposit's
  // picker only has "ignore", a withdrawal's also has expenses and vendors).
  buildBulk() {
    if (!this.hasBulkTarget || this.choiceTargets.length === 0) return
    const source = this.choiceTargets.reduce((best, select) => (select.querySelectorAll("optgroup").length > best.querySelectorAll("optgroup").length ? select : best))
    source.querySelectorAll("optgroup").forEach((group) => {
      if (group.label) this.bulkTarget.appendChild(group.cloneNode(true))
    })
  }

  // Applies one choice to the waiting lines currently shown by the filter.
  // Lines the person already chose, and lines that cannot take it (a deposit
  // cannot become an expense), are left alone. Nothing is saved until Save.
  applyBulk() {
    const value = this.bulkTarget.value
    if (!value) return
    let applied = 0
    this.choiceTargets.forEach((select) => {
      const row = select.closest("tr")
      if (row?.hidden) return
      if (select.value && select.value !== "leave") return
      if (![...select.options].some((option) => option.value === value)) return
      select.value = value
      row.classList.remove("bank-line-suggested")
      applied += 1
    })
    this.sync()
    if (this.hasCountTarget) this.countTarget.textContent += ` · applied to ${applied}`
  }

  chosen() {
    return this.choiceTargets.filter((select) => select.value && select.value !== "leave")
  }

  // Only fills lines still set to "Decide later" whose description matched a
  // known keyword. Never overwrites a choice the person already made.
  fillSuggestions() {
    let filled = 0
    this.choiceTargets.forEach((select) => {
      const suggestion = select.dataset.suggestion
      if (!suggestion || (select.value && select.value !== "leave")) return
      if (![...select.options].some((option) => option.value === suggestion)) return
      select.value = suggestion
      select.closest("tr")?.classList.add("bank-line-suggested")
      filled += 1
    })
    this.sync()
    if (this.hasFillTarget) this.fillTarget.textContent = filled === 0 ? "No more suggestions to fill" : `Filled ${filled} suggestion${filled === 1 ? "" : "s"} · review, then save`
  }

  clear() {
    this.choiceTargets.forEach((select) => {
      select.value = "leave"
      select.closest("tr")?.classList.remove("bank-line-suggested")
    })
    if (this.hasFillTarget) this.fillTarget.textContent = "Use suggestions"
    this.sync()
  }

  change(event) {
    event.target.closest("tr")?.classList.remove("bank-line-suggested")
    this.sync()
  }

  submit() {
    this.submitting = true
  }

  sync() {
    const n = this.chosen().length
    if (this.hasCountTarget) this.countTarget.textContent = n === 0 ? "No lines chosen yet" : `${n} of ${this.choiceTargets.length} line${this.choiceTargets.length === 1 ? "" : "s"} chosen`
    if (this.hasSaveTarget) this.saveTarget.disabled = n === 0
  }
}
