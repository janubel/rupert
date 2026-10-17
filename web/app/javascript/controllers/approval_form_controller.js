import { Controller } from "@hotwired/stimulus"

// Book approval form: the note is required for anything other than a plain
// approval, and the submit button stays off until the person has ticked that
// they looked at the numbers. The server still enforces both rules.
export default class extends Controller {
  static targets = ["status", "notes", "label", "confirm", "submit"]

  connect() { this.sync() }

  sync() {
    const chosen = this.statusTargets.find((radio) => radio.checked)
    const needsNote = !!chosen && chosen.value !== "approved"
    this.notesTarget.required = needsNote
    this.labelTarget.textContent = needsNote ? "Note (required for this decision)" : "Note (optional for a plain approval)"
    if (this.hasSubmitTarget) this.submitTarget.disabled = !this.confirmTarget.checked
  }
}
