import { Controller } from "@hotwired/stimulus"

// Inline definition popover. The native <details> works on its own; when
// JavaScript is available the open panel is pinned to the viewport so it is
// never clipped by a scrolling table or card, and it closes on scroll so it
// cannot drift away from its label.
export default class extends Controller {
  connect() {
    this.onToggle = () => this.toggle()
    this.onScroll = () => { if (this.element.open) this.element.open = false }
    this.element.addEventListener("toggle", this.onToggle)
  }

  disconnect() {
    this.element.removeEventListener("toggle", this.onToggle)
    this.unpin()
  }

  toggle() {
    if (this.element.open) this.pin()
    else this.unpin()
  }

  pin() {
    const panel = this.element.querySelector(".term-panel, .term-list-panel")
    const summary = this.element.querySelector("summary")
    if (!panel || !summary) return
    const rect = summary.getBoundingClientRect()
    const width = Math.min(320, window.innerWidth - 32)
    const left = Math.max(16, Math.min(rect.left, window.innerWidth - width - 16))
    const height = panel.offsetHeight || 160
    const below = rect.bottom + 8 + height <= window.innerHeight || rect.top < height + 8
    Object.assign(panel.style, {
      position: "fixed", width: `${width}px`, left: `${left}px`, right: "auto",
      top: below ? `${rect.bottom + 8}px` : "auto",
      bottom: below ? "auto" : `${window.innerHeight - rect.top + 8}px`
    })
    window.addEventListener("scroll", this.onScroll, true)
    window.addEventListener("resize", this.onScroll)
  }

  unpin() {
    const panel = this.element.querySelector(".term-panel, .term-list-panel")
    if (panel) ["position", "width", "left", "right", "top", "bottom"].forEach((key) => { panel.style[key] = "" })
    window.removeEventListener("scroll", this.onScroll, true)
    window.removeEventListener("resize", this.onScroll)
  }
}
