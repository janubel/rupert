import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["token", "button", "status", "file", "text"]
  static values = { previewUrl: String, importUrl: String }

  reset() {
    this.tokenTarget.value = ""
    this.element.action = this.previewUrlValue
    this.buttonTarget.value = "Preview sales"
    this.statusTarget.textContent = "Export changed. Preview it before importing."
  }

  async submit(event) {
    if (this.tokenTarget.value && !this.previewing) return
    event.preventDefault()
    if (this.previewing || !this.element.reportValidity()) return

    this.previewing = true
    this.buttonTarget.disabled = true
    this.fileTarget.disabled = true
    this.textTarget.readOnly = true
    this.statusTarget.textContent = "Validating the export…"
    try {
      // Disabled controls are omitted from FormData. Temporarily include the
      // file while building the request, then keep edits locked until it ends.
      this.fileTarget.disabled = false
      const body = new FormData(this.element)
      this.fileTarget.disabled = true
      const response = await fetch(this.previewUrlValue, {
        method: "POST", body, credentials: "same-origin", redirect: "error",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        }
      })
      const result = await response.json()
      if (!response.ok) throw new Error(result.error || "The export could not be validated.")
      this.renderPreview(result.preview)
      this.tokenTarget.value = result.preview_token
      this.element.action = this.importUrlValue
      this.buttonTarget.value = "Import reviewed sales"
    } catch (error) {
      this.tokenTarget.value = ""
      this.statusTarget.textContent = error instanceof SyntaxError || error instanceof TypeError
        ? "The preview could not be confirmed. Check your connection and sign-in, then retry. No sales were saved."
        : error.message
    } finally {
      this.previewing = false
      this.buttonTarget.disabled = false
      this.buttonTarget.value = this.tokenTarget.value ? "Import reviewed sales" : "Preview sales"
      this.fileTarget.disabled = false
      this.textTarget.readOnly = false
    }
  }

  renderPreview(preview) {
    this.statusTarget.replaceChildren()
    const amount = new Intl.NumberFormat(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })
      .format(preview.gross_cents / 100)
    const messages = [
      `Validated preview: ${preview.orders} orders, ${preview.lines} item lines, ${preview.payments} tenders. Item sales: ${preview.currency} ${amount}.`,
      ...(preview.warnings || []),
      "Review these totals, then import the same file within 15 minutes. Existing identical orders remain intact."
    ]
    for (const message of messages) {
      const paragraph = document.createElement("p")
      paragraph.textContent = message
      this.statusTarget.append(paragraph)
    }
  }
}
