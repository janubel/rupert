import { Controller } from "@hotwired/stimulus"

// Drag-and-drop for the Uploads inbox. The real <input type="file" multiple> stays
// the control (keyboard, screen reader and phone pickers all use it); dropping
// files simply fills it. Limits are repeated here for quick feedback; the server
// enforces them again.
export default class extends Controller {
  static targets = ["zone", "input", "list", "submit", "message"]
  static values = { maxFiles: { type: Number, default: 10 }, maxBytes: { type: Number, default: 10485760 }, maxTotal: { type: Number, default: 26214400 } }

  over(event) {
    event.preventDefault()
    this.zoneTarget.classList.add("upload-dropzone-active")
  }

  leave() {
    this.zoneTarget.classList.remove("upload-dropzone-active")
  }

  drop(event) {
    event.preventDefault()
    this.leave()
    const files = event.dataTransfer && event.dataTransfer.files
    if (!files || files.length === 0) return
    try {
      this.inputTarget.files = files
    } catch (_error) {
      this.messageTarget.textContent = "Your browser would not accept the dropped files. Use “choose files” instead."
      return
    }
    this.changed()
  }

  changed() {
    const files = Array.from(this.inputTarget.files)
    this.listTarget.replaceChildren()
    let problem = null
    let total = 0
    if (files.length > this.maxFilesValue) problem = `Choose up to ${this.maxFilesValue} files at a time.`
    files.forEach((file) => {
      total += file.size
      const item = document.createElement("li")
      item.textContent = `${file.name} — ${this.size(file.size)}`
      if (file.size > this.maxBytesValue) {
        item.textContent += " — too large"
        item.className = "upload-file-problem"
        problem = problem || `${file.name} is larger than ${this.size(this.maxBytesValue)}.`
      }
      this.listTarget.appendChild(item)
    })
    if (!problem && total > this.maxTotalValue) problem = `Those files add up to more than ${this.size(this.maxTotalValue)}.`
    this.messageTarget.textContent = problem || (files.length ? `${files.length} file${files.length === 1 ? "" : "s"} ready to upload.` : "")
    this.messageTarget.classList.toggle("upload-file-problem", !!problem)
    this.submitTarget.disabled = files.length === 0 || !!problem
  }

  size(bytes) {
    if (bytes < 1024) return `${bytes} B`
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KiB`
    return `${(bytes / 1048576).toFixed(1)} MiB`
  }
}
