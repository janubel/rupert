import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['horizon', 'week', 'asOf']

  connect() { this.update() }

  update() {
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
  }
}
