import { Controller } from "@hotwired/stimulus"

// Bank statement review: keeps a live count of chosen lines in the save bar,
// can pre-fill the keyword suggestions (a person still presses Save), and
// warns before leaving the page with choices that were not saved.
export default class extends Controller {
  static targets = ["choice", "count", "save", "fill"]

  connect() {
    this.submitting = false
    this.beforeUnload = (event) => {
      if (this.submitting || this.chosen().length === 0) return
      event.preventDefault()
      event.returnValue = ""
    }
    window.addEventListener("beforeunload", this.beforeUnload)
    this.sync()
  }

  disconnect() {
    window.removeEventListener("beforeunload", this.beforeUnload)
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
