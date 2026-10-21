import { Controller } from "@hotwired/stimulus"

// Customizable report table. Wraps any server-rendered <table> and adds:
// choose columns, sort by a heading, narrow rows by typing, download the rows
// and columns on screen as CSV, and reset. The chosen layout is kept per table
// in this browser only (localStorage); without it the page still works and
// shows the default layout. Nothing is fetched and no record is changed.
//
// Columns come from the last header row. A <th data-col="key"> gives a stable
// key; data-default-hidden hides it until chosen. A <td data-sort-value="...">
// overrides the sort value. Rows whose cell count differs from the header (an
// "empty" message, a colspan note) are left alone: never sorted or exported.
export default class extends Controller {
  static targets = ["table", "filter", "count", "menu", "columns", "empty"]
  static values = { key: String, filename: String, sortable: { type: Boolean, default: true } }

  connect() {
    this.table = this.hasTableTarget ? this.tableTarget : this.element.querySelector("table")
    if (!this.table) return
    const headRows = this.table.tHead ? this.table.tHead.rows : []
    this.headerRow = headRows.length ? headRows[headRows.length - 1] : null
    if (!this.headerRow) return
    this.headers = Array.from(this.headerRow.cells)
    this.columns = this.headers.map((th, index) => {
      const label = this.constructor.headerLabel(th) || `Column ${index + 1}`
      return { index, label, key: th.dataset.col || this.constructor.slug(label) || `col-${index}`, defaultHidden: th.hasAttribute("data-default-hidden") }
    })
    this.rows = this.dataRows()
    this.rows.forEach((row, position) => { row.dataset.reportTableOrder = position })
    this.state = this.load()
    this.buildColumnMenu()
    if (this.sortableValue) this.addSortButtons()
    this.element.classList.add("report-table-ready")
    this.apply()
  }

  // --- pure helpers (exercised by test/javascript/report_table_test.mjs) ---

  // Heading text without inline definitions, help popovers or our sort button.
  static headerLabel(th) {
    if (th.dataset.label) return th.dataset.label.trim()
    const copy = th.cloneNode(true)
    copy.querySelectorAll("details, button, .sr-only, [data-report-table-ignore]").forEach((node) => node.remove())
    return copy.textContent.replace(/\s+/g, " ").trim()
  }

  static cellText(cell) {
    if (cell.dataset.export !== undefined) return cell.dataset.export
    return (typeof cell.innerText === "string" ? cell.innerText : cell.textContent).replace(/\s+/g, " ").trim()
  }

  static slug(text) {
    return String(text || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "")
  }

  // Numbers (money, counts, percents) sort numerically; "Unavailable", "—" and
  // blanks sort last; anything else sorts as text.
  static sortValue(raw) {
    const text = String(raw ?? "").trim()
    if (text === "" || /^(—|-|–|unavailable|unknown|n\/a)$/i.test(text)) return null
    const cleaned = text.replace(/[$,%\s]/g, "").replace(/^\((.*)\)$/, "-$1").replace(/^−/, "-")
    if (/^-?\d+(\.\d+)?$/.test(cleaned)) return Number(cleaned)
    return text.toLowerCase()
  }

  static compare(a, b, dir) {
    if (a === null && b === null) return 0
    if (a === null) return 1
    if (b === null) return -1
    let result
    if (typeof a === "number" && typeof b === "number") result = a - b
    else result = String(a).localeCompare(String(b), undefined, { numeric: true })
    return dir === "desc" ? -result : result
  }

  static csvCell(value) {
    let text = String(value ?? "").replace(/\s+/g, " ").trim()
    if (/^[=+\-@\t\r]/.test(text) && !/^-?\$?\d[\d,]*(\.\d+)?$/.test(text)) text = `'${text}`
    return /[",\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text
  }

  static toCsv(matrix) {
    return matrix.map((row) => row.map((cell) => this.csvCell(cell)).join(",")).join("\r\n") + "\r\n"
  }

  // --- state ---

  storageKey() { return `report-table:${this.keyValue || this.constructor.slug(document.title)}` }

  defaults() {
    return { hidden: this.columns.filter((c) => c.defaultHidden).map((c) => c.key), sort: null }
  }

  load() {
    try {
      const saved = JSON.parse(window.localStorage.getItem(this.storageKey()) || "null")
      if (saved && Array.isArray(saved.hidden)) {
        const keys = this.columns.map((c) => c.key)
        return { hidden: saved.hidden.filter((k) => keys.includes(k)), sort: saved.sort && keys.includes(saved.sort.key) ? saved.sort : null }
      }
    } catch (_error) { /* storage unavailable: use the default layout */ }
    return this.defaults()
  }

  save() {
    try { window.localStorage.setItem(this.storageKey(), JSON.stringify(this.state)) } catch (_error) { /* not remembered */ }
  }

  reset() {
    try { window.localStorage.removeItem(this.storageKey()) } catch (_error) { /* nothing stored */ }
    this.state = this.defaults()
    if (this.hasFilterTarget) this.filterTarget.value = ""
    this.syncColumnMenu()
    this.apply()
  }

  // --- rendering ---

  dataRows() {
    const count = this.headers.length
    return Array.from(this.table.tBodies).flatMap((body) => Array.from(body.rows))
      .filter((row) => row.cells.length === count && !row.hasAttribute("data-report-table-skip"))
  }

  buildColumnMenu() {
    if (!this.hasColumnsTarget) return
    this.columnsTarget.innerHTML = ""
    this.columns.forEach((column) => {
      const label = document.createElement("label")
      label.className = "report-table-column"
      const box = document.createElement("input")
      box.type = "checkbox"
      box.value = column.key
      box.dataset.action = "change->report-table#toggleColumn"
      const span = document.createElement("span")
      span.textContent = column.label
      label.append(box, span)
      this.columnsTarget.append(label)
    })
    this.syncColumnMenu()
  }

  syncColumnMenu() {
    if (!this.hasColumnsTarget) return
    const visible = this.columns.length - this.state.hidden.length
    this.columnsTarget.querySelectorAll("input[type=checkbox]").forEach((box) => {
      box.checked = !this.state.hidden.includes(box.value)
      box.disabled = box.checked && visible <= 1 // keep at least one column
    })
  }

  addSortButtons() {
    this.headers.forEach((th, index) => {
      if (th.hasAttribute("data-no-sort") || th.querySelector(".report-table-sort")) return
      const button = document.createElement("button")
      button.type = "button"
      button.className = "report-table-sort"
      button.dataset.index = index
      button.dataset.action = "report-table#sort"
      button.setAttribute("aria-label", `Sort by ${this.columns[index].label}`)
      button.innerHTML = '<span aria-hidden="true">↕</span>'
      th.append(button)
    })
  }

  toggleColumn(event) {
    const key = event.target.value
    const hidden = new Set(this.state.hidden)
    if (event.target.checked) hidden.delete(key)
    else if (this.columns.length - hidden.size > 1) hidden.add(key)
    this.state.hidden = this.columns.map((c) => c.key).filter((k) => hidden.has(k))
    this.save()
    this.syncColumnMenu()
    this.apply()
  }

  sort(event) {
    const index = Number(event.currentTarget.dataset.index)
    const key = this.columns[index].key
    const current = this.state.sort && this.state.sort.key === key ? this.state.sort.dir : null
    const next = current === null ? "asc" : current === "asc" ? "desc" : null
    this.state.sort = next ? { key, dir: next } : null
    this.save()
    this.apply()
  }

  filter() { this.apply() }

  clearFilter() {
    if (!this.hasFilterTarget) return
    this.filterTarget.value = ""
    this.apply()
    this.filterTarget.focus()
  }

  cellValue(row, index) {
    const cell = row.cells[index]
    return cell.dataset.sortValue !== undefined ? this.constructor.sortValue(cell.dataset.sortValue) : this.constructor.sortValue(cell.textContent)
  }

  apply() {
    const hidden = new Set(this.state.hidden)
    this.columns.forEach((column) => {
      const hide = hidden.has(column.key)
      this.headers[column.index].hidden = hide
      this.rows.forEach((row) => { row.cells[column.index].hidden = hide })
    })

    // Sort within each tbody so grouped bodies stay grouped.
    const sort = this.state.sort
    const index = sort ? this.columns.findIndex((c) => c.key === sort.key) : -1
    Array.from(this.table.tBodies).forEach((body) => {
      const rows = this.rows.filter((row) => row.parentNode === body)
      if (rows.length < 2) return
      const ordered = rows.slice().sort((a, b) => index >= 0
        ? this.constructor.compare(this.cellValue(a, index), this.cellValue(b, index), sort.dir) || (a.dataset.reportTableOrder - b.dataset.reportTableOrder)
        : a.dataset.reportTableOrder - b.dataset.reportTableOrder)
      const anchor = rows.reduce((last, row) => (row.compareDocumentPosition(last) & Node.DOCUMENT_POSITION_FOLLOWING ? last : row), rows[0]).nextSibling
      ordered.forEach((row) => body.insertBefore(row, anchor))
    })
    this.headers.forEach((th, i) => {
      const dir = index === i ? sort.dir : null
      if (dir) th.setAttribute("aria-sort", dir === "asc" ? "ascending" : "descending")
      else th.removeAttribute("aria-sort")
      const icon = th.querySelector(".report-table-sort span")
      if (icon) icon.textContent = dir === "asc" ? "▲" : dir === "desc" ? "▼" : "↕"
    })

    const query = this.hasFilterTarget ? this.filterTarget.value.trim().toLowerCase() : ""
    let shown = 0
    this.rows.forEach((row) => {
      const match = query === "" || Array.from(row.cells).some((cell) => !cell.hidden && cell.textContent.toLowerCase().includes(query))
      row.hidden = !match
      if (match) shown += 1
    })
    if (this.hasCountTarget) {
      const visibleColumns = this.columns.length - hidden.size
      const rowsText = query === "" ? `${this.rows.length} row${this.rows.length === 1 ? "" : "s"}` : `${shown} of ${this.rows.length} rows`
      this.countTarget.textContent = `${rowsText} · ${visibleColumns} of ${this.columns.length} columns`
    }
    if (this.hasEmptyTarget) this.emptyTarget.hidden = !(query !== "" && shown === 0 && this.rows.length > 0)
  }

  // Rows and columns exactly as shown, in the order shown.
  visibleMatrix() {
    const columns = this.columns.filter((c) => !this.state.hidden.includes(c.key))
    const body = this.dataRows().filter((row) => !row.hidden)
      .map((row) => columns.map((c) => this.constructor.cellText(row.cells[c.index])))
    return [columns.map((c) => c.label), ...body]
  }

  download() {
    const csv = this.constructor.toCsv(this.visibleMatrix())
    const blob = new Blob([csv], { type: "text/csv;charset=utf-8" })
    const link = document.createElement("a")
    const day = new Date().toISOString().slice(0, 10)
    link.href = URL.createObjectURL(blob)
    link.download = `${this.filenameValue || this.keyValue || "report"}-${day}.csv`
    document.body.append(link)
    link.click()
    link.remove()
    setTimeout(() => URL.revokeObjectURL(link.href), 0)
  }
}
