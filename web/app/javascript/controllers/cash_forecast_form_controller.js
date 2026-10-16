import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['horizon', 'week', 'asOf', 'changed', 'output', 'baselineStatus', 'baselineChanged', 'entry', 'checklist', 'checklistSummary', 'missingDetails', 'missingSummary', 'missingList', 'nextMissing', 'nextLabel']
  static values = { calculated: Boolean, baselineDate: String }

  connect() { this.update() }

  markChanged() {
    this.updateBaseline()
    this.updateChecklist()
    if (!this.calculatedValue) return
    this.changedTargets.forEach((notice) => { notice.hidden = false })
    this.outputTargets.forEach((button) => { button.disabled = true })
  }

  update() {
    this.updateBaseline()
    const horizon = Number(this.horizonTarget.value)
    const date = /^\d{4}-\d{2}-\d{2}$/.test(this.asOfTarget.value) ? new Date(`${this.asOfTarget.value}T12:00:00Z`) : null
    const format = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' })
    this.weekTargets.forEach((row) => {
      const week = Number(row.dataset.week)
      const active = week <= horizon
      row.hidden = !active
      const dates = row.querySelector('[data-week-dates]')
      if (date && !Number.isNaN(date.getTime())) {
        const from = new Date(date); from.setUTCDate(from.getUTCDate() + (week - 1) * 7 + 1)
        const to = new Date(date); to.setUTCDate(to.getUTCDate() + week * 7)
        dates.textContent = ` · ${format.format(from)} – ${format.format(to)}`
      } else { dates.textContent = '' }
      row.querySelectorAll('input').forEach((input) => {
        input.disabled = !active
        input.required = active
      })
    })
    this.updateChecklist()
  }

  updateChecklist() {
    if (!this.hasChecklistTarget) return
    const entries = this.entryTargets.filter(entry => !entry.disabled)
    const missing = entries.filter(entry => !entry.value.trim())
    this.checklistTarget.hidden = false
    const summary = missing.length
      ? `${entries.length - missing.length} of ${entries.length} required entries filled · ${missing.length} missing`
      : "All required entries contain text. Calculate to validate amounts and refresh results."
    if (this.checklistSummaryTarget.textContent !== summary) this.checklistSummaryTarget.textContent = summary
    this.nextMissingTarget.hidden = missing.length === 0
    this.nextLabelTarget.hidden = missing.length === 0
    this.missingDetailsTarget.hidden = missing.length === 0
    this.nextMissingTarget.dataset.entryId = missing[0]?.id || ""
    this.nextLabelTarget.textContent = missing.length ? `Next: ${missing[0].dataset.entryLabel}` : ""
    this.missingSummaryTarget.textContent = `Show missing entries (${missing.length})`
    this.missingListTarget.replaceChildren(...missing.map(entry => {
      const button = document.createElement("button")
      button.type = "button"
      button.className = "btn-ghost btn-sm"
      button.textContent = entry.dataset.entryLabel
      button.dataset.entryId = entry.id
      button.dataset.action = "cash-forecast-form#jumpMissing"
      return button
    }))
  }

  jumpMissing(event) {
    const entry = this.entryTargets.find(field => field.id === event.currentTarget.dataset.entryId && !field.disabled && !field.value.trim())
    if (!entry) return
    entry.focus({ preventScroll: true })
    entry.scrollIntoView({ block: "center" })
  }

  updateBaseline() {
    const changed = this.asOfTarget.value !== this.baselineDateValue
    this.baselineStatusTargets.forEach((status) => { status.hidden = changed })
    this.baselineChangedTargets.forEach((notice) => { notice.hidden = !changed })
  }
}
