import { Controller } from "@hotwired/stimulus"

// Live "type to narrow" filter for a table already on the page. Rows opt in
// with data-table-filter-target="row"; matching is case-insensitive substring
// over the row text. Nothing is fetched and no record is changed.
export default class extends Controller {
  static targets = ["input", "row", "count", "empty"]

  connect() { this.filter() }

  filter() {
    const query = this.inputTarget.value.trim().toLowerCase()
    let shown = 0
    this.rowTargets.forEach((row) => {
      const match = query === "" || row.textContent.toLowerCase().includes(query)
      row.hidden = !match
      if (match) shown += 1
    })
    if (this.hasCountTarget) {
      this.countTarget.textContent = query === "" ? "" : `${shown} of ${this.rowTargets.length} shown`
    }
    if (this.hasEmptyTarget) this.emptyTarget.hidden = shown > 0 || this.rowTargets.length === 0
  }

  clear() {
    this.inputTarget.value = ""
    this.filter()
    this.inputTarget.focus()
  }
}
