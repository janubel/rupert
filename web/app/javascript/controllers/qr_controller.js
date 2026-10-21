import { Controller } from "@hotwired/stimulus"
import qrcode from "lib/qrcode"

// Draws a QR code for data-qr-text-value as inline SVG, entirely in the
// browser: the text never leaves the page. Modules are always dark on a white
// quiet zone so the code scans in any appearance theme.
export default class extends Controller {
  static values = { text: String, label: String }
  static targets = ["canvas"]

  connect() {
    if (!this.textValue || !this.hasCanvasTarget) return
    try {
      const qr = qrcode(0, "M")
      qr.addData(this.textValue)
      qr.make()
      this.canvasTarget.replaceChildren(this.svg(qr))
    } catch (_error) {
      this.canvasTarget.textContent = "The QR code could not be drawn. Use the copy buttons instead."
    }
  }

  svg(qr) {
    const quiet = 4
    const count = qr.getModuleCount()
    const size = count + quiet * 2
    let path = ""
    for (let row = 0; row < count; row++) {
      for (let col = 0; col < count; col++) {
        if (qr.isDark(row, col)) path += `M${col + quiet} ${row + quiet}h1v1h-1z`
      }
    }
    const ns = "http://www.w3.org/2000/svg"
    const svg = document.createElementNS(ns, "svg")
    svg.setAttribute("viewBox", `0 0 ${size} ${size}`)
    svg.setAttribute("role", "img")
    svg.setAttribute("aria-label", this.labelValue || "QR code")
    svg.setAttribute("shape-rendering", "crispEdges")
    svg.classList.add("buzz-qr")
    const bg = document.createElementNS(ns, "rect")
    bg.setAttribute("width", size)
    bg.setAttribute("height", size)
    bg.setAttribute("fill", "#fff")
    const fg = document.createElementNS(ns, "path")
    fg.setAttribute("d", path)
    fg.setAttribute("fill", "#000")
    svg.append(bg, fg)
    return svg
  }
}
