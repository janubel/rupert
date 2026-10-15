import { Controller } from "@hotwired/stimulus"

// Native disclosure works without JavaScript; add predictable dismiss behavior.
export default class extends Controller {
  connect() {
    this.dismissOutside = (event) => {
      if (!this.element.contains(event.target)) this.element.open = false
    }
    this.dismissEscape = (event) => {
      if (event.key === "Escape" && this.element.open && this.element.contains(event.target)) {
        event.preventDefault()
        this.element.open = false
        this.element.querySelector("summary").focus()
      }
    }
    this.dismissCached = () => { this.element.open = false }
    document.addEventListener("pointerdown", this.dismissOutside)
    document.addEventListener("keydown", this.dismissEscape)
    document.addEventListener("turbo:before-cache", this.dismissCached)
  }

  disconnect() {
    document.removeEventListener("pointerdown", this.dismissOutside)
    document.removeEventListener("keydown", this.dismissEscape)
    document.removeEventListener("turbo:before-cache", this.dismissCached)
  }
}
