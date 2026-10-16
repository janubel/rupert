import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["due", "notes", "evidence", "chosen"]

  connect() { this.syncEvidence() }

  setDue(event) {
    this.dueTarget.value = event.currentTarget.dataset.date
    this.dueTarget.dispatchEvent(new Event("change", { bubbles: true }))
  }

  chooseEvidence(event) {
    const id = event.currentTarget.dataset.evidenceId
    if (![...this.evidenceTarget.options].some(option => option.value === id)) return
    this.evidenceTarget.value = id
    this.syncEvidence()
    this.notesTarget.focus()
  }

  syncEvidence() {
    if (!this.hasEvidenceTarget) return
    this.element.querySelectorAll("[data-evidence-id]").forEach(button => {
      button.setAttribute("aria-pressed", String(button.dataset.evidenceId === this.evidenceTarget.value))
    })
    if (this.hasChosenTarget) {
      this.chosenTarget.textContent = this.evidenceTarget.value
        ? `Selected: ${this.evidenceTarget.selectedOptions[0].textContent}. Save a progress note to link it.`
        : "No original selected. Choosing a file does not save or close this follow-up."
    }
  }
}
