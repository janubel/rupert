import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["kind", "scope", "currency", "location", "from", "to"]

  connect() { this.update() }

  update() {
    const control = this.kindTarget.value === "register_control"
    this.currencyTarget.required = control
    this.currencyTarget.disabled = !control
    this.locationTarget.disabled = !control
    if (control) this.scopeTarget.open = true
    this.toTarget.readOnly = control
    this.toTarget.min = this.fromTarget.value
    if (control) this.toTarget.value = this.fromTarget.value
  }
}
