import { Controller } from "@hotwired/stimulus"

// Collapsible "How this page works" guide panel. Auto-opens the first time a
// visitor lands on each page (remembered in localStorage per page path) so
// new users actually see the guidance; stays collapsed afterwards.
export default class extends Controller {
  static targets = ["panel", "trigger"]
  static values = { autoKey: String }

  connect() {
    // On phones the open panel fills the first screen and pushes the page's own
    // content out of sight; leave it collapsed there (the button still opens it).
    if (window.matchMedia("(max-width: 639px)").matches) return

    const seen = this.hasAutoKeyValue && localStorage.getItem(this.storageKey())
    if (!seen && !localStorage.getItem(this.dismissedKey())) {
      this.open()
      // Mark as seen so it doesn't reopen on every Turbo visit to this page.
      if (this.hasAutoKeyValue) localStorage.setItem(this.storageKey(), "1")
    }
  }

  toggle() {
    const open = this.panelTarget.classList.toggle("hidden") === false
    this.triggerTarget.setAttribute("aria-expanded", String(open))
    // A manual close counts as "seen" even without an autoKey.
    if (!open && !this.hasAutoKeyValue) return
    if (!open && this.hasAutoKeyValue) localStorage.setItem(this.dismissedKey(), "1")
  }

  open() {
    this.panelTarget.classList.remove("hidden")
    this.triggerTarget.setAttribute("aria-expanded", "true")
  }

  storageKey() {
    return `rupert-guide-seen:${this.autoKeyValue}`
  }

  dismissedKey() {
    return `rupert-guide-dismissed:${this.autoKeyValue}`
  }
}
