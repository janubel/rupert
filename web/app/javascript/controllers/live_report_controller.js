import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { interval: { type: Number, default: 30000 } }

  connect() {
    this.timer = setInterval(() => {
      const frame = this.element.querySelector("turbo-frame")
      if (!document.hidden && frame && frame.complete && !frame.hasAttribute("busy")) frame.reload()
    }, this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }
}
