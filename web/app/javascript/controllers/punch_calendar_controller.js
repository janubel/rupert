import { Controller } from "@hotwired/stimulus"

// Drag across calendar days to select a reporting date range.
// Pointer down starts a selection, pointer enter while dragging extends it,
// and pointer up commits the range to the hidden from/to fields and submits.
export default class extends Controller {
  static targets = ["grid", "day", "from", "to", "label", "form"]

  connect() {
    this.dragging = false
    this.boundEnd = this.end.bind(this)
    document.addEventListener("mouseup", this.boundEnd)
    document.addEventListener("pointerup", this.boundEnd)
  }

  disconnect() {
    document.removeEventListener("mouseup", this.boundEnd)
    document.removeEventListener("pointerup", this.boundEnd)
  }

  start(event) {
    const day = event.currentTarget
    if (!day) return
    event.preventDefault()
    this.dragging = true
    this.anchor = day.dataset.date
    this.paint(day.dataset.date, day.dataset.date)
  }

  extend(event) {
    if (!this.dragging) return
    const day = event.currentTarget
    if (!day || !day.dataset.date) return
    this.paint(this.anchor, day.dataset.date)
  }

  end() {
    if (!this.dragging) return
    this.dragging = false
    if (this.hasFormTarget) this.formTarget.requestSubmit()
  }

  paint(anchor, other) {
    const [start, finish] = [anchor, other].sort()
    this.fromTarget.value = start
    this.toTarget.value = finish
    if (this.hasLabelTarget) {
      const format = (value) => new Date(`${value}T00:00:00`).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" })
      this.labelTarget.textContent = `${format(start)} – ${format(finish)}`
    }
    this.dayTargets.forEach((day) => {
      const selected = day.dataset.date >= start && day.dataset.date <= finish
      day.classList.toggle("bg-olive/20", selected)
      day.classList.toggle("border-olive", selected)
    })
  }
}
