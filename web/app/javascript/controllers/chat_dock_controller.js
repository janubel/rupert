import { Controller } from "@hotwired/stimulus"

// The team chat dock: the header chat button opens a small chat window at the
// bottom of any page. Its contents are a Turbo Frame (the room list, then one
// room), so rooms open inside the dock and "expand" opens the full /chat page.
// Whether it is open and which room it shows are remembered across pages.
export default class extends Controller {
  static targets = ["panel", "frame", "badge", "trigger"]
  static values = { unreadUrl: String, dockUrl: String, fullUrl: String }
  static KEY = "rupert.chatDock"
  static POLL = 30000

  connect() {
    this.restore()
    this.refreshBadge()
    this.timer = setInterval(() => this.refreshBadge(), this.constructor.POLL)
    this.onVisible = () => { if (!document.hidden) this.refreshBadge() }
    document.addEventListener("visibilitychange", this.onVisible)
    this.onFrameLoad = (event) => { if (event.target === this.frameTarget) this.remember() }
    document.addEventListener("turbo:frame-load", this.onFrameLoad)
    this.onKey = (event) => { if (event.key === "Escape" && this.isOpen() && this.panelTarget.contains(document.activeElement)) this.close() }
    document.addEventListener("keydown", this.onKey)
  }

  disconnect() {
    clearInterval(this.timer)
    document.removeEventListener("visibilitychange", this.onVisible)
    document.removeEventListener("turbo:frame-load", this.onFrameLoad)
    document.removeEventListener("keydown", this.onKey)
  }

  // On the full team chat page there is no dock: the button goes to /chat.
  toggle(event) {
    if (!this.hasPanelTarget) return
    event.preventDefault()
    this.isOpen() ? this.close() : this.open()
  }

  open() {
    if (!this.frameTarget.getAttribute("src")) this.frameTarget.src = this.state().src || this.dockUrlValue
    this.panelTarget.hidden = false
    this.setExpanded(true)
    this.save({ open: true })
    requestAnimationFrame(() => this.panelTarget.querySelector("textarea, a, button")?.focus({ preventScroll: true }))
  }

  close() {
    if (!this.hasPanelTarget) return
    this.panelTarget.hidden = true
    this.setExpanded(false)
    this.save({ open: false })
    this.refreshBadge()
    if (this.hasTriggerTarget) this.triggerTarget.focus({ preventScroll: true })
  }

  isOpen() {
    return this.hasPanelTarget && !this.panelTarget.hidden
  }

  restore() {
    if (!this.hasPanelTarget) return
    const state = this.state()
    if (state.open && this.panelTarget.hidden) {
      if (!this.frameTarget.getAttribute("src")) this.frameTarget.src = state.src || this.dockUrlValue
      this.panelTarget.hidden = false
    }
    this.setExpanded(!this.panelTarget.hidden)
  }

  remember() {
    const src = this.frameTarget.getAttribute("src")
    if (src) this.save({ src })
  }

  async refreshBadge() {
    if (!this.hasBadgeTarget || document.hidden) return
    try {
      const response = await fetch(this.unreadUrlValue, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      if (!response.ok) return
      const data = await response.json()
      const mentions = data.mentions || 0
      const unread = data.unread || 0
      this.badgeTarget.hidden = mentions === 0 && unread === 0
      this.badgeTarget.textContent = mentions > 0 ? `@${mentions}` : unread > 99 ? "99+" : String(unread)
      this.badgeTarget.classList.toggle("is-mention", mentions > 0)
      if (this.hasTriggerTarget) {
        const label = mentions > 0 ? `Team chat, ${mentions} mention${mentions === 1 ? "" : "s"}` : unread > 0 ? `Team chat, ${unread} unread` : "Team chat"
        this.triggerTarget.setAttribute("aria-label", label)
      }
    } catch (_error) {
      // The badge is a convenience; the chat itself reports connection problems.
    }
  }

  setExpanded(open) {
    if (this.hasTriggerTarget) this.triggerTarget.setAttribute("aria-expanded", open ? "true" : "false")
  }

  state() {
    try {
      return JSON.parse(window.localStorage.getItem(this.constructor.KEY) || "{}")
    } catch (_error) {
      return {}
    }
  }

  save(patch) {
    try {
      window.localStorage.setItem(this.constructor.KEY, JSON.stringify({ ...this.state(), ...patch }))
    } catch (_error) {
      // Private windows may refuse storage; the dock still works for this page.
    }
  }
}
