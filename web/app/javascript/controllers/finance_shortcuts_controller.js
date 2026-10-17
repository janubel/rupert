import { Controller } from "@hotwired/stimulus"

// "g then a letter" jumps between Finance pages. Pressing g reveals the letter
// on each link for a moment. Ignored while typing in a field, with modifier
// keys held, or when a dialog is open. Links do the navigating, so Turbo,
// permissions and active-page state all behave as they do for a click.
export default class extends Controller {
  connect() {
    this.armed = false
    this.onKeydown = (event) => this.keydown(event)
    document.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
    this.disarm()
  }

  keydown(event) {
    if (event.metaKey || event.ctrlKey || event.altKey || event.isComposing) return
    const el = event.target
    if (el && (["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName) || el.isContentEditable)) return
    if (document.querySelector("dialog[open]")) return
    const key = event.key.toLowerCase()
    if (!this.armed) {
      if (key === "g") { this.arm(); event.preventDefault() }
      return
    }
    const link = this.element.querySelector(`a[data-shortcut="${key}"]`)
    this.disarm()
    if (link) { event.preventDefault(); link.click() }
  }

  arm() {
    this.armed = true
    this.element.classList.add("keys-armed")
    this.timer = setTimeout(() => this.disarm(), 2500)
  }

  disarm() {
    this.armed = false
    clearTimeout(this.timer)
    this.element.classList.remove("keys-armed")
  }
}
