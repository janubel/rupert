import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["kind", "totals", "currency", "from", "to", "file", "fileStatus"]

  connect() { this.update() }

  update() {
    const comparing = this.kindTarget.value === "register_control"
    this.currencyTarget.required = comparing
    if (comparing) this.totalsTarget.open = true
    this.toTarget.min = this.fromTarget.value
    this.toTarget.readOnly = comparing
    if (comparing) this.toTarget.value = this.fromTarget.value
  }

  fileChanged() {
    const file = this.fileTarget.files[0]
    let error = ""
    if (file && file.size > 8 * 1024 * 1024) error = "Choose a file no larger than 8 MiB."
    if (file && !/\.(csv|pdf|png|jpe?g|json|txt)$/i.test(file.name)) error = "Choose a CSV, PDF, PNG, JPEG, JSON or TXT original."
    this.fileTarget.setCustomValidity(error)
    const size = file && (file.size < 1024 ? `${file.size} bytes` : `${(file.size / 1024).toFixed(1)} KiB`)
    this.fileStatusTarget.textContent = error || (file ? `${file.name} · ${size} · ready to retain` : "Choose one original file, up to 8 MiB.")
  }
}
