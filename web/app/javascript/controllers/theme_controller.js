import { Controller } from "@hotwired/stimulus"

// Dark is the default. This flips the account-menu item between dark and light
// and remembers the choice in this browser (the layout script applies it early).
export default class extends Controller {
  static targets = ["label"]

  connect() {
    this.render()
  }

  toggle() {
    const light = document.documentElement.getAttribute("data-theme") !== "light"
    if (light) document.documentElement.setAttribute("data-theme", "light")
    else document.documentElement.removeAttribute("data-theme")
    try { localStorage.setItem("rupert-theme", light ? "light" : "dark") } catch (e) { /* private mode */ }
    document.querySelector('meta[name="theme-color"]')?.setAttribute("content", light ? "#fbf5ef" : "#171412")
    window.dispatchEvent(new Event("rupert:theme"))
    this.render()
  }

  render() {
    const light = document.documentElement.getAttribute("data-theme") === "light"
    this.element.textContent = light ? "Switch to dark mode" : "Switch to light mode"
  }
}
