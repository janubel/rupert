import { Controller } from "@hotwired/stimulus"

// Shared time-report range picker (shared/_time_range_picker.html.erb).
// Choosing a named range fills Start date and End date; editing either date switches
// the dropdown to the matching range or "Custom"; Finish before Start shows a
// message and blocks submit. The server resolves the same params without JS.

// presets: [[key, from, to], ...] with ISO dates. Returns the first matching key.
function matchPreset(presets, from, to) {
  const found = presets.find(([, start, finish]) => start === from && finish === to)
  return found ? found[0] : null
}

// The dropdown value for the current dates.
function rangeKey(presets, from, to, optional) {
  if (optional && !from && !to) return "all"
  return matchPreset(presets, from, to) || "custom"
}

// [from, to] for a chosen key, or null when the key keeps the dates as they are.
function datesFor(presets, key) {
  if (key === "all") return ["", ""]
  const found = presets.find(([presetKey]) => presetKey === key)
  return found ? [found[1], found[2]] : null
}

// A message when the End date is before the Start date (ISO dates compare as strings).
function rangeProblem(from, to) {
  if (from && to && to < from) return "End date must be on or after the start date."
  return ""
}

export default class extends Controller {
  static targets = ["select", "from", "to", "error"]
  static values = { presets: Array, optional: Boolean }

  connect() {
    this.sync()
  }

  choose() {
    const dates = datesFor(this.presetsValue, this.selectTarget.value)
    if (dates) {
      this.fromTarget.value = dates[0]
      this.toTarget.value = dates[1]
    } else {
      // Custom: go straight to the Start date calendar.
      this.fromTarget.focus()
      try { this.fromTarget.showPicker?.() } catch (_error) { /* not allowed here; focus is enough */ }
    }
    this.validate()
  }

  edit() {
    this.sync()
  }

  sync() {
    this.selectTarget.value = rangeKey(this.presetsValue, this.fromTarget.value, this.toTarget.value, this.optionalValue)
    this.validate()
  }

  validate() {
    const problem = rangeProblem(this.fromTarget.value, this.toTarget.value)
    this.toTarget.setCustomValidity(problem)
    if (problem) this.toTarget.setAttribute("aria-invalid", "true")
    else this.toTarget.removeAttribute("aria-invalid")
    this.errorTarget.textContent = problem
    this.errorTarget.hidden = !problem
  }
}
