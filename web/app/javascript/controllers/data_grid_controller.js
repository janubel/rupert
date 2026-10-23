import { Controller } from "@hotwired/stimulus"

// Spreadsheet view on top of the report-table controller (which owns columns,
// sort and the remembered layout). This adds what makes a table feel like a
// sheet: arrow-key movement between cells, Enter to open the cell's link, and
// a server "Download CSV" link that follows the columns on screen.
//
// Read-only: no cell is editable and nothing is fetched. Without JavaScript
// the grid is a plain table with a sticky header and first column, and the
// CSV link downloads every column.
//
// <th data-csv="key"> names the server CSV column for that grid column; the
// csv target's href gets columns=key1,key2,… for the visible ones, in order.
export default class extends Controller {
  static targets = ["csv"]

  connect() {
    this.table = this.element.querySelector("table")
    if (!this.table) return
    this.table.setAttribute("role", "grid")
    this.table.setAttribute("aria-readonly", "true")
    this.onKey = this.navigate.bind(this)
    this.onFocus = this.focusCell.bind(this)
    this.table.addEventListener("keydown", this.onKey)
    this.table.addEventListener("focusin", this.onFocus)
    this.resetTabStops()
    this.sync()
  }

  disconnect() {
    if (!this.table) return
    this.table.removeEventListener("keydown", this.onKey)
    this.table.removeEventListener("focusin", this.onFocus)
  }

  // --- pure helpers (exercised by test/javascript/data_grid_test.mjs) ---

  // Next [row, column] for a key, clamped to the grid; null for other keys.
  static step(key, row, col, rows, cols, ctrl = false) {
    const clamp = (value, max) => Math.max(0, Math.min(value, max - 1))
    switch (key) {
      case "ArrowUp": return [clamp(row - 1, rows), col]
      case "ArrowDown": return [clamp(row + 1, rows), col]
      case "ArrowLeft": return [row, clamp(col - 1, cols)]
      case "ArrowRight": return [row, clamp(col + 1, cols)]
      case "Home": return ctrl ? [0, 0] : [row, 0]
      case "End": return ctrl ? [rows - 1, cols - 1] : [row, cols - 1]
      case "PageUp": return [clamp(row - 10, rows), col]
      case "PageDown": return [clamp(row + 10, rows), col]
      default: return null
    }
  }

  static withColumns(href, keys) {
    const url = new URL(href, "http://grid.local")
    if (keys.length) url.searchParams.set("columns", keys.join(","))
    else url.searchParams.delete("columns")
    return url.origin === "http://grid.local" ? url.pathname + url.search + url.hash : url.toString()
  }

  // --- cells ---

  // Visible rows (header row first) as arrays of visible cells. Rows whose
  // cell count differs from the header (an empty-state row) are skipped.
  matrix() {
    const head = this.table.tHead ? Array.from(this.table.tHead.rows).slice(-1) : []
    const width = head.length ? head[0].cells.length : 0
    const body = Array.from(this.table.tBodies).flatMap((tbody) => Array.from(tbody.rows))
      .filter((row) => !row.hidden && row.cells.length === width)
    return [...head, ...body].map((row) => Array.from(row.cells).filter((cell) => !cell.hidden))
      .filter((cells) => cells.length)
  }

  resetTabStops() {
    const cells = this.table.querySelectorAll("th, td")
    cells.forEach((cell) => cell.setAttribute("tabindex", "-1"))
    const grid = this.matrix()
    const first = (grid[1] || grid[0] || [])[0]
    if (first) first.setAttribute("tabindex", "0")
  }

  focusCell(event) {
    const cell = event.target.closest("th, td")
    if (!cell || !this.table.contains(cell)) return
    this.table.querySelectorAll("[tabindex='0']").forEach((other) => { if (other !== cell) other.setAttribute("tabindex", "-1") })
    cell.setAttribute("tabindex", "0")
  }

  navigate(event) {
    const cell = event.target.closest("th, td")
    if (!cell || event.target.matches("input, select, textarea")) return
    if (event.key === "Enter" && event.target === cell) {
      const action = cell.querySelector("a[href], button")
      if (action) { event.preventDefault(); action.click() }
      return
    }
    const grid = this.matrix()
    const row = grid.findIndex((cells) => cells.includes(cell))
    if (row < 0) return
    const col = grid[row].indexOf(cell)
    const next = this.constructor.step(event.key, row, col, grid.length, grid[row].length, event.ctrlKey || event.metaKey)
    if (!next) return
    event.preventDefault()
    const target = grid[next[0]][Math.min(next[1], grid[next[0]].length - 1)]
    if (target) target.focus({ preventScroll: false })
  }

  // Called on connect and after report-table re-applies columns or sort.
  sync() {
    if (!this.table) return
    this.resetTabStops()
    if (!this.hasCsvTarget) return
    const head = this.table.tHead ? Array.from(this.table.tHead.rows).slice(-1)[0] : null
    if (!head) return
    const keys = Array.from(head.cells).filter((th) => !th.hidden && th.dataset.csv).map((th) => th.dataset.csv)
    this.csvTargets.forEach((link) => { link.setAttribute("href", this.constructor.withColumns(link.getAttribute("href"), keys)) })
  }
}
