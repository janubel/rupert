import { Controller } from "@hotwired/stimulus"

// Full window: hides the top bar, navigation rail and status bar so a wide page
// (the staff schedule, a data grid) uses the whole screen, and asks the browser
// for real fullscreen when it allows. Esc, the browser's own exit, or the
// floating "Exit full window" button all return to normal.
export default class extends Controller {
  static targets = ["toggle"]

  connect() {
    this.onFullscreen = () => { if (!document.fullscreenElement && this.active) this.exit() }
    this.onKey = (event) => { if (event.key === "Escape" && this.active && !document.fullscreenElement) this.exit() }
    this.onLeave = () => this.exit()
    document.addEventListener("fullscreenchange", this.onFullscreen)
    document.addEventListener("keydown", this.onKey)
    document.addEventListener("turbo:before-visit", this.onLeave)
    this.render()
  }

  disconnect() {
    document.removeEventListener("fullscreenchange", this.onFullscreen)
    document.removeEventListener("keydown", this.onKey)
    document.removeEventListener("turbo:before-visit", this.onLeave)
  }

  get active() {
    return document.documentElement.hasAttribute("data-full-window")
  }

  toggle() {
    if (this.active) this.exit()
    else this.enter()
  }

  enter() {
    document.documentElement.setAttribute("data-full-window", "")
    const root = document.documentElement
    if (root.requestFullscreen && !document.fullscreenElement) root.requestFullscreen().catch(() => {})
    this.render()
  }

  exit() {
    document.documentElement.removeAttribute("data-full-window")
    if (document.fullscreenElement && document.exitFullscreen) document.exitFullscreen().catch(() => {})
    this.render()
  }

  render() {
    this.toggleTargets.forEach((button) => {
      button.setAttribute("aria-pressed", this.active ? "true" : "false")
      const label = button.querySelector("[data-full-window-label]")
      if (label) label.textContent = this.active ? "Exit full window" : "Full window"
    })
  }
}
