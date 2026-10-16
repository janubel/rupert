import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static values = { start: String }
  static targets = ['duration']

  connect() {
    this.render()
    this.timer = setInterval(() => this.render(), 1000)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  render() {
    const start = Date.parse(this.startValue)
    if (!Number.isFinite(start)) return
    const seconds = Math.max(0, Math.floor((Date.now() - start) / 1000))
    const parts = [Math.floor(seconds / 3600), Math.floor(seconds / 60) % 60, seconds % 60]
    this.durationTarget.textContent = parts.map(part => String(part).padStart(2, '0')).join(':')
  }
}
