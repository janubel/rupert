import { Controller } from '@hotwired/stimulus'

const FIELDS = ['receipts', 'payments']
// Mirrors ReconciliationEvidence.cents: 1234.56, 1,234.56, $1,234.56, .50, surrounding spaces.
const AMOUNT = /^(-)?\$?(\d{1,3}(?:,\d{3})+|\d+)?(?:\.(\d{1,2}))?$/

export default class extends Controller {
  static targets = ['horizon', 'week', 'asOf', 'changed', 'output', 'baselineStatus', 'baselineChanged', 'entry', 'checklist', 'checklistSummary', 'missingDetails', 'missingSummary', 'missingList', 'nextMissing', 'nextLabel',
    'amount', 'opening', 'reserve', 'fillSelection', 'fillButton', 'fillStatus', 'totalLabel', 'totalReceipts', 'totalPayments', 'totalNet', 'totalClosing', 'blankSummary']
  static values = { calculated: Boolean, baselineDate: String }

  // null when blank, NaN when not an amount, otherwise integer cents.
  static parseCents(value) {
    const text = String(value ?? '').trim()
    if (!text) return null
    const match = text.match(AMOUNT)
    if (!match || (!match[2] && !match[3]) || (match[2] || '').replaceAll(',', '').length > 12) return NaN
    const cents = Number((match[2] || '0').replaceAll(',', '')) * 100 + Number((match[3] || '0').padEnd(2, '0'))
    return match[1] ? -cents : cents
  }

  static formatCents(cents) {
    const abs = Math.abs(cents)
    return `${cents < 0 ? '−' : ''}${Math.floor(abs / 100).toLocaleString('en-US')}.${String(abs % 100).padStart(2, '0')}`
  }

  // Valid amounts become plain units (1250.00); anything else is kept for the server to reject.
  static canonical(value) {
    const cents = this.parseCents(value)
    if (cents === null) return ''
    if (Number.isNaN(cents)) return String(value).trim()
    const abs = Math.abs(cents)
    return `${cents < 0 ? '-' : ''}${Math.floor(abs / 100)}.${String(abs % 100).padStart(2, '0')}`
  }

  connect() { this.update() }

  markChanged(event) {
    // Confirming blank entries reviews the calculated plan; it does not change it.
    if (event?.target?.dataset?.reviewOnly) return
    this.updateBaseline()
    this.updateChecklist()
    this.totals()
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
        dates.textContent = `${format.format(from)} – ${format.format(to)}`
      } else { dates.textContent = '' }
      row.querySelectorAll('input').forEach((input) => { input.disabled = !active })
    })
    this.updateChecklist()
    this.totals()
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

  // Active week inputs by field, in week order.
  cells(field) {
    return this.amountTargets.filter(input => !input.disabled && input.dataset.field === field)
      .sort((a, b) => Number(a.dataset.weekIndex) - Number(b.dataset.weekIndex))
  }

  cell(index, field) { return this.cells(field).find(input => Number(input.dataset.weekIndex) === index) }

  // Running net and projected closing per week; blanks count as 0 and are reported.
  totals() {
    if (!this.hasTotalLabelTarget) return
    const Form = this.constructor
    const opening = this.hasOpeningTarget ? Form.parseCents(this.openingTarget.value) : null
    const reserve = this.hasReserveTarget ? Form.parseCents(this.reserveTarget.value) : null
    const sums = { receipts: 0, payments: 0 }
    let balance = opening, blanks = 0, invalid = 0, weeks = 0
    this.weekTargets.filter(row => !row.hidden).forEach((row) => {
      weeks += 1
      const index = Number(row.dataset.week) - 1
      const [receipts, payments] = FIELDS.map((field) => {
        const input = this.cell(index, field)
        const cents = input ? Form.parseCents(input.value) : null
        const bad = Number.isNaN(cents) || cents < 0
        if (input) this.flag(input, bad)
        if (bad) { invalid += 1; return NaN }
        if (cents === null) blanks += 1
        sums[field] += cents || 0
        return cents || 0
      })
      const net = receipts - payments
      balance = balance === null || Number.isNaN(balance) ? NaN : balance + net
      row.querySelector('[data-net]').textContent = Number.isNaN(net) ? 'Check amount' : this.difference(net)
      const closing = row.querySelector('[data-closing]')
      closing.textContent = Number.isNaN(balance) ? '—' : Form.formatCents(balance)
      closing.dataset.short = String(!Number.isNaN(balance) && balance < (Number.isNaN(reserve) ? 0 : reserve || 0))
      closing.className = `td text-right whitespace-nowrap${closing.dataset.short === 'true' ? ' font-semibold text-amber-950' : ''}`
    })
    this.totalLabelTarget.textContent = `Total · ${weeks} weeks`
    this.totalReceiptsTarget.textContent = Form.formatCents(sums.receipts)
    this.totalPaymentsTarget.textContent = Form.formatCents(sums.payments)
    this.totalNetTarget.textContent = this.difference(sums.receipts - sums.payments)
    this.totalClosingTarget.textContent = Number.isNaN(balance) || balance === null ? (opening === null ? 'Enter opening cash' : '—') : Form.formatCents(balance)
    if (invalid) this.totalNetTarget.textContent += ' (excludes invalid amounts)'
    this.blankSummaryTarget.textContent = [
      blanks ? `${blanks} blank weekly ${blanks === 1 ? 'entry counts' : 'entries count'} as 0. You confirm ${blanks === 1 ? 'it' : 'them'} after calculating, before any download or retained version.` : '',
      invalid ? `${invalid} weekly ${invalid === 1 ? 'amount is' : 'amounts are'} not a valid zero-or-positive amount.` : ''
    ].filter(Boolean).join(' ')
  }

  // Marks format errors without clearing a server error on the same field.
  flag(input, bad) {
    if (bad) {
      input.setAttribute('aria-invalid', 'true')
      input.dataset.clientInvalid = 'true'
    } else if (input.dataset.clientInvalid) {
      input.removeAttribute('aria-invalid')
      delete input.dataset.clientInvalid
    }
  }

  difference(cents) { return cents === 0 ? '0.00' : `${cents > 0 ? '+' : ''}${this.constructor.formatCents(cents)}` }

  // Rewrites a valid amount such as $1,250 as 1250.00 when the field is left.
  normalize(event) {
    const input = event.target
    const cents = this.constructor.parseCents(input.value)
    if (cents === null || Number.isNaN(cents)) return
    const value = this.constructor.canonical(input.value)
    if (value !== input.value) input.value = value
  }

  select(event) {
    this.selected = event.target
    const value = this.selected.value.trim()
    this.fillSelectionTarget.textContent = `Selected: ${this.selected.dataset.entryLabel}${value ? ` · ${value}` : ' · blank'}`
    this.fillButtonTargets.forEach((button) => { button.disabled = false })
  }

  navigate(event) {
    if (!['ArrowDown', 'ArrowUp'].includes(event.key) || event.ctrlKey || event.metaKey || event.shiftKey) return
    const input = event.target
    event.preventDefault()
    if (event.altKey) {
      if (event.key === 'ArrowDown') { this.selected = input; this.fillDown() }
      return
    }
    const next = this.cell(Number(input.dataset.weekIndex) + (event.key === 'ArrowDown' ? 1 : -1), input.dataset.field)
    if (next) next.focus()
  }

  // Repeats the selected amount into later active weeks of the same column.
  fillDown(event) {
    const source = this.selected
    if (!source || source.disabled) return this.announce('Select a weekly amount first.')
    const overwrite = event?.currentTarget?.dataset?.overwrite === 'true'
    const value = this.fillValue(source)
    if (value === null) return
    const index = Number(source.dataset.weekIndex)
    const targets = this.cells(source.dataset.field).filter(input => Number(input.dataset.weekIndex) > index && (overwrite || !input.value.trim()))
    targets.forEach((input) => { input.value = value })
    this.announceFill(targets, `${source.dataset.entryLabel.replace(/^Week \d+ /, '')} ${value}`, overwrite)
  }

  // Repeats both amounts of the selected week into later weeks where each is empty.
  fillWeek() {
    const source = this.selected
    if (!source || source.disabled) return this.announce('Select a weekly amount first.')
    const index = Number(source.dataset.weekIndex)
    const filled = []
    for (const field of FIELDS) {
      const from = this.cell(index, field)
      const value = from && from.value.trim() ? this.fillValue(from) : ''
      if (value === null) return
      if (!value) continue
      this.cells(field).filter(input => Number(input.dataset.weekIndex) > index && !input.value.trim())
        .forEach((input) => { input.value = value; filled.push(input) })
    }
    if (!filled.length && FIELDS.every(field => !this.cell(index, field)?.value.trim())) return this.announce(`Week ${index + 1} is blank; enter an amount to repeat.`)
    this.announceFill(filled, `week ${index + 1} amounts`, false)
  }

  fillValue(input) {
    const cents = this.constructor.parseCents(input.value)
    if (cents === null) { this.announce(`${input.dataset.entryLabel} is blank; enter an amount to repeat.`); return null }
    if (Number.isNaN(cents) || cents < 0) { this.announce(`${input.dataset.entryLabel} is not a valid amount; fix it before repeating.`); return null }
    return this.constructor.canonical(input.value)
  }

  announceFill(targets, what, overwrite) {
    if (!targets.length) return this.announce(overwrite ? 'No later weeks to fill.' : 'No empty weeks below to fill.')
    const weeks = [...new Set(targets.map(input => Number(input.dataset.weekIndex) + 1))]
    this.announce(`Repeated ${what} into ${weeks.length === 1 ? `week ${weeks[0]}` : `weeks ${weeks[0]}–${weeks.at(-1)}`} (${targets.length} ${targets.length === 1 ? 'entry' : 'entries'}).`)
    this.markChanged()
  }

  announce(message) { this.fillStatusTarget.textContent = message }

  // Spreadsheet paste: rows fill downward from this week; a second column fills payments.
  paste(event) {
    const text = event.clipboardData?.getData('text/plain') ?? ''
    if (!/[\t\n\r]/.test(text.trim())) return
    event.preventDefault()
    const input = event.target
    const start = Number(input.dataset.weekIndex)
    const column = FIELDS.indexOf(input.dataset.field)
    const rows = text.replace(/\r\n?/g, '\n').replace(/\n+$/, '').split('\n').map(line => line.split('\t'))
    let used = 0, unplaced = 0, extra = 0
    const invalid = [], weeks = new Set()
    rows.forEach((cells, offset) => {
      extra = Math.max(extra, cells.length - (FIELDS.length - column))
      cells.slice(0, FIELDS.length - column).forEach((value, j) => {
        const target = this.cell(start + offset, FIELDS[column + j])
        if (!target) { unplaced += 1; return }
        target.value = this.constructor.canonical(value)
        const cents = this.constructor.parseCents(value)
        if (Number.isNaN(cents) || cents < 0) invalid.push(target.dataset.entryLabel)
        weeks.add(start + offset + 1)
        used += 1
      })
    })
    const last = Math.max(...weeks)
    this.announce([
      used ? `Pasted ${used} ${used === 1 ? 'value' : 'values'} into ${weeks.size === 1 ? `week ${last}` : `weeks ${start + 1}–${last}`}.` : 'Nothing was pasted.',
      unplaced ? `${unplaced} ${unplaced === 1 ? 'value' : 'values'} past the last active week ${unplaced === 1 ? 'was' : 'were'} not used; choose more forecast weeks to include ${unplaced === 1 ? 'it' : 'them'}.` : '',
      extra > 0 ? `${extra} extra ${extra === 1 ? 'column was' : 'columns were'} ignored; only receipts then payments are used.` : '',
      invalid.length ? `Check ${invalid.join(', ')}: not a valid zero-or-positive amount.` : ''
    ].filter(Boolean).join(' '))
    this.markChanged()
  }
}
