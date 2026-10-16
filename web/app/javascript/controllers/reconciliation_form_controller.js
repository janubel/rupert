import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["kind", "totals", "currency"]

  connect() { this.update() }

  update() {
    const comparing = this.kindTarget.value === "register_control"
    this.currencyTarget.required = comparing
    if (comparing) this.totalsTarget.open = true
  }
}
