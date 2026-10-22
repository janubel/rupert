import { Controller } from "@hotwired/stimulus"

// The navigation rail. On wide screens it is always there and can fold to icons
// (remembered per browser; layouts/_theme applies the saved state before first
// paint). Under 1024px it is a drawer behind the top-bar menu button.
const STORAGE_KEY = "rupert-rail"

export default class extends Controller {
  static targets = ["collapse", "menu"]

  connect() {
    this.onKey = (event) => {
      if (event.key === "Escape" && this.drawerOpen) {
        this.closeDrawer()
        this.menuTarget.focus()
      }
    }
    this.onCache = () => this.closeDrawer()
    document.addEventListener("keydown", this.onKey)
    document.addEventListener("turbo:before-cache", this.onCache)
    this.render()
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKey)
    document.removeEventListener("turbo:before-cache", this.onCache)
  }

  get collapsed() {
    return document.documentElement.getAttribute("data-rail") === "collapsed"
  }

  get drawerOpen() {
    return document.documentElement.hasAttribute("data-rail-open")
  }

  toggleCollapse() {
    const next = !this.collapsed
    if (next) document.documentElement.setAttribute("data-rail", "collapsed")
    else document.documentElement.removeAttribute("data-rail")
    try { localStorage.setItem(STORAGE_KEY, next ? "collapsed" : "open") } catch (e) { /* private mode */ }
    this.render()
  }

  toggleDrawer() {
    if (this.drawerOpen) this.closeDrawer()
    else this.openDrawer()
  }

  openDrawer() {
    document.documentElement.setAttribute("data-rail-open", "")
    this.render()
    this.element.querySelector(".app-rail a[aria-current], .app-rail a")?.focus()
  }

  closeDrawer() {
    document.documentElement.removeAttribute("data-rail-open")
    this.render()
  }

  render() {
    if (this.hasCollapseTarget) {
      this.collapseTarget.setAttribute("aria-expanded", this.collapsed ? "false" : "true")
      this.collapseTarget.setAttribute("aria-label", this.collapsed ? "Expand navigation" : "Collapse navigation")
      this.collapseTarget.title = this.collapsed ? "Expand navigation" : "Collapse navigation"
    }
    if (this.hasMenuTarget) this.menuTarget.setAttribute("aria-expanded", this.drawerOpen ? "true" : "false")
  }
}
