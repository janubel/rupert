import { Controller } from "@hotwired/stimulus"

// Appearance picker in the account menu. Herbal is the default and is the
// absence of a data-theme attribute; every other option sets data-theme. The
// choice is remembered per browser (app/views/layouts/_theme.html.erb applies
// it before first paint, so there is no flash).
const THEMES = ["herbal", "light", "mist", "sepia", "dark"]
// Page color per theme for the browser chrome (matches --color-oat).
const PAGE_COLORS = { herbal: "#e6efea", light: "#f5f7fa", mist: "#e6ebf2", sepia: "#efe6d4", dark: "#121418" }

export default class extends Controller {
  static targets = ["option"]

  connect() {
    this.render()
  }

  select(event) {
    const theme = event.currentTarget.dataset.themeValue
    if (!THEMES.includes(theme)) return
    if (theme === "herbal") document.documentElement.removeAttribute("data-theme")
    else document.documentElement.setAttribute("data-theme", theme)
    try { localStorage.setItem("rupert-theme", theme) } catch (e) { /* private mode */ }
    document.querySelector('meta[name="theme-color"]')?.setAttribute("content", PAGE_COLORS[theme])
    window.dispatchEvent(new Event("rupert:theme"))
    this.render()
  }

  render() {
    const current = document.documentElement.getAttribute("data-theme") || "herbal"
    this.optionTargets.forEach((option) => {
      option.setAttribute("aria-checked", option.dataset.themeValue === current ? "true" : "false")
    })
  }
}
