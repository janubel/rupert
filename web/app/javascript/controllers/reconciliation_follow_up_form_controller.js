import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["due", "notes", "evidence", "chosen", "status", "decision"]

  connect() { this.syncEvidence(); this.syncDecision() }

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

  chooseDecision(event) {
    const value = event.currentTarget.dataset.decision
    if (!this.hasStatusTarget || ![...this.statusTarget.options].some(option => option.value === value)) return
    this.statusTarget.value = value
    this.statusTarget.dispatchEvent(new Event("change", { bubbles: true }))
    this.notesTarget.focus()
  }

  syncDecision() {
    if (!this.hasStatusTarget || !this.hasDecisionTarget) return
    const value = this.statusTarget.value
    this.element.querySelectorAll("[data-decision]").forEach(button => {
      button.setAttribute("aria-pressed", String(button.dataset.decision === value))
    })
    const messages = {
      open: "Keep investigating: record the remaining question, assign its owner and set the next check date. Save progress to record these changes.",
      waiting: "Waiting on report: record which original or response is outstanding, who owns the next step and when to check again. Save progress to record these changes.",
      closed: "Resolve follow-up: review the selected original, or explain the documented exception. Enter a closing reason and save to record your decision."
    }
    this.decisionTarget.textContent = messages[value] || "Choose a status and add a progress note before saving."
    this.notesTarget.placeholder = value === "closed"
      ? "What did you review, or why is this a documented exception? What supports resolving this follow-up?"
      : "What is outstanding, who owns the next step, and when will you check again?"
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
