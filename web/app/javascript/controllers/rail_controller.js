import { Controller } from "@hotwired/stimulus"

// The navigation rail. The top-bar menu button is its one control: on wide
// screens it folds the rail to icons and back (remembered per browser;
// layouts/_theme applies the saved state before first paint); under 1024px
// the rail is a drawer and the same button opens and closes it.
const STORAGE_KEY = "rupert-rail"
const WIDE = "(min-width: 1024px)"

export default class extends Controller {
  static targets = ["menu"]

  connect() {
    this.media = window.matchMedia(WIDE)
    this.onMedia = () => { this.closeDrawer() }
    this.media.addEventListener("change", this.onMedia)
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
    this.media?.removeEventListener("change", this.onMedia)
    document.removeEventListener("keydown", this.onKey)
    document.removeEventListener("turbo:before-cache", this.onCache)
  }

  get collapsed() {
    return document.documentElement.getAttribute("data-rail") === "collapsed"
  }

  get drawerOpen() {
    return document.documentElement.hasAttribute("data-rail-open")
  }

  get wide() {
    return this.media ? this.media.matches : window.matchMedia(WIDE).matches
  }

  // The menu button: fold the rail on wide screens, open the drawer on small ones.
  toggle() {
    if (this.wide) this.toggleCollapse()
    else this.toggleDrawer()
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
    if (!this.hasMenuTarget) return
    const menu = this.menuTarget
    if (this.wide) {
      const label = this.collapsed ? "Expand navigation" : "Collapse navigation"
      menu.setAttribute("aria-expanded", this.collapsed ? "false" : "true")
      menu.setAttribute("aria-label", label)
      menu.title = label
    } else {
      menu.setAttribute("aria-expanded", this.drawerOpen ? "true" : "false")
      menu.setAttribute("aria-label", "Menu")
      menu.title = "Menu"
    }
  }
}
