import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "code", "token", "submit", "status", "items", "itemCount", "total"]

  async record(event) {
    event.preventDefault()
    if (this.saving) return
    const code = this.codeTarget.value.trim()
    if (!code || !this.formTarget.reportValidity()) return

    this.saving = true
    this.submitTarget.disabled = true
    this.codeTarget.readOnly = true
    this.statusTarget.textContent = "Saving…"
    try {
      const response = await fetch(this.formTarget.action, {
        method: "POST",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: new FormData(this.formTarget)
      })
      const result = await response.json()
      if (!response.ok) throw new Error(result.error || "The count could not be saved.")
      this.renderItem(result)
      this.statusTarget.textContent = `Saved ${result.sku}: ${result.quantity} counted. ${result.title}`
      this.codeTarget.value = ""
      this.tokenTarget.value = crypto.randomUUID()
    } catch (error) {
      this.statusTarget.textContent = error instanceof SyntaxError
        ? "The server response could not be confirmed. Retry this same entry to confirm it, or review the count."
        : error.message === "Failed to fetch"
          ? "Connection lost. Retry this same entry to confirm it, or review the count."
          : error.message
    } finally {
      this.saving = false
      this.submitTarget.disabled = false
      this.codeTarget.readOnly = false
      this.codeTarget.focus()
      this.codeTarget.select()
    }
  }

  renderItem(result) {
    let row = Array.from(this.itemsTarget.children).find(item => item.dataset.sku === result.sku)
    if (!row) {
      row = document.createElement("li")
      row.className = "flex justify-between gap-4 py-2"
      row.dataset.sku = result.sku
      const sku = document.createElement("span")
      sku.className = "font-mono text-sm"
      sku.textContent = result.sku
      const quantity = document.createElement("strong")
      quantity.dataset.quantity = ""
      row.append(sku, quantity)
      this.itemsTarget.append(row)
    }
    row.querySelector("[data-quantity]").textContent = result.quantity
    this.itemCountTarget.textContent = result.item_count
    this.totalTarget.textContent = result.total_quantity
  }
}
