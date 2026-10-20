import { Controller } from "@hotwired/stimulus"

// Appearance picker in the account menu. Dark is the default (no data-theme
// attribute); the other options set data-theme and are remembered per browser
// (config/layouts/_theme.html.erb applies the saved choice before first paint).
const THEMES = ["dark", "light", "mist", "sepia", "herbal"]
// Page color per theme for the browser chrome (matches --color-oat).
const PAGE_COLORS = { dark: "#121418", light: "#f5f7fa", mist: "#e6ebf2", sepia: "#efe6d4", herbal: "#f3f4f1" }

export default class extends Controller {
  static targets = ["option"]

  connect() {
    this.render()
  }

  select(event) {
    const theme = event.currentTarget.dataset.themeValue
    if (!THEMES.includes(theme)) return
    if (theme === "dark") document.documentElement.removeAttribute("data-theme")
    else document.documentElement.setAttribute("data-theme", theme)
    try { localStorage.setItem("rupert-theme", theme) } catch (e) { /* private mode */ }
    document.querySelector('meta[name="theme-color"]')?.setAttribute("content", PAGE_COLORS[theme])
    window.dispatchEvent(new Event("rupert:theme"))
    this.render()
  }

  render() {
    const current = document.documentElement.getAttribute("data-theme") || "dark"
    this.optionTargets.forEach((option) => {
      const active = option.dataset.themeValue === current
      option.setAttribute("aria-checked", active ? "true" : "false")
    })
  }
}
