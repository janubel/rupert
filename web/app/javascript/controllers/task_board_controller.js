import { Controller } from "@hotwired/stimulus"

// Kanban board: drag a card to another column, or up and down within one (or
// use the card's Move menu, which also covers touch and keyboard), and the
// task's status and place are saved. The card moves right away and snaps back
// if the server refuses. After a confirmed save the page's totals (regions
// marked data-live-region) and the card itself are refreshed in place.
export default class extends Controller {
  static targets = ["column", "card", "list", "count", "empty", "status"]
  static values = { writable: Boolean }

  connect() {
    this.dragged = null
    this.pending = new WeakSet()
    this.element.addEventListener("dragstart", this.start)
    this.element.addEventListener("dragend", this.end)
  }

  disconnect() {
    this.element.removeEventListener("dragstart", this.start)
    this.element.removeEventListener("dragend", this.end)
  }

  start = (event) => {
    const card = event.target.closest?.("[data-task-id]")
    if (!card || !this.writableValue || this.pending.has(card)) return
    this.dragged = card
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", card.dataset.taskId)
    requestAnimationFrame(() => card.classList.add("opacity-40"))
  }

  end = () => {
    this.dragged?.classList.remove("opacity-40")
    this.dragged = null
    this.columnTargets.forEach((column) => this.highlight(column, false))
  }

  over(event) {
    if (!this.dragged) return
    event.preventDefault()
    this.highlight(event.currentTarget, true)
  }

  leave(event) {
    if (!event.currentTarget.contains(event.relatedTarget)) this.highlight(event.currentTarget, false)
  }

  drop(event) {
    if (!this.dragged) return
    event.preventDefault()
    const column = event.currentTarget
    this.highlight(column, false)
    this.move(this.dragged, column.dataset.status, this.cardAfter(column, this.dragged, event.clientY))
  }

  select(event) {
    const card = event.target.closest("[data-task-id]")
    const column = this.columnTargets.find((c) => c.dataset.status === event.target.value)
    if (card && column) this.move(card, column.dataset.status)
  }

  // The card in the column the dropped card should sit above, or null for the bottom.
  cardAfter(column, dragged, y) {
    const cards = [...column.querySelectorAll("[data-task-id]")].filter((c) => c !== dragged)
    return cards.find((c) => {
      const box = c.getBoundingClientRect()
      return y < box.top + box.height / 2
    }) || null
  }

  idsIn(column) {
    return [...column.querySelectorAll("[data-task-id]")].map((c) => c.dataset.taskId)
  }

  async move(card, status, before = null) {
    const from = card.dataset.status
    if (!this.writableValue || this.pending.has(card)) {
      const select = card.querySelector("select")
      if (select) select.value = from
      return
    }
    const column = this.columnTargets.find((c) => c.dataset.status === status)
    if (!column) return
    const previous = this.columnTargets.find((c) => c.dataset.status === from)
    const next = card.nextElementSibling
    const wasIds = this.idsIn(column)
    this.pending.add(card)
    this.place(card, column, status, before)
    // Dropping a card back where it was changes nothing.
    if (from === status && this.idsIn(column).join() === wasIds.join()) {
      this.pending.delete(card)
      return
    }

    try {
      const response = await fetch(card.dataset.moveUrl, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify({ status, ordered_ids: this.idsIn(column) })
      })
      if (!response.ok) throw new Error((await response.json().catch(() => ({}))).error || "Could not move the task.")
      const saved = await response.json()
      if (String(saved.id) !== card.dataset.taskId || saved.status !== status) throw new Error("Could not confirm the task move. Reload and try again.")
      this.announce(`Moved to ${column.querySelector("h3").textContent}.`)
      await this.refresh(card)
    } catch (error) {
      this.place(card, previous, from, next)
      this.announce(error.message)
      card.animate([{ transform: "translateX(-4px)" }, { transform: "translateX(4px)" }, { transform: "none" }], 200)
    } finally {
      this.pending.delete(card)
    }
  }

  place(card, column, status, before = null) {
    const list = column.querySelector("[data-task-board-target='list']")
    const anchor = before && before.parentElement === list ? before : column.querySelector("[data-task-board-target='empty']")
    list.insertBefore(card, anchor)
    card.dataset.status = status
    const select = card.querySelector("select")
    if (select) select.value = status
    const title = card.querySelector("p")
    title?.classList.toggle("line-through", status === "done")
    title?.classList.toggle("text-taupe", status === "done")
    title?.classList.toggle("font-medium", status !== "done")
    title?.classList.toggle("text-ink", status !== "done")
    this.refreshCounts()
  }

  // Reconcile project progress, overdue labels, due dates and active filters
  // with the saved record by swapping in the server's version of the totals and
  // of this card. If the page cannot be re-read, fall back to a full reload.
  async refresh(card) {
    try {
      const response = await fetch(window.location.href, { credentials: "same-origin", headers: { Accept: "text/html" } })
      if (!response.ok) throw new Error("refresh failed")
      const fresh = new DOMParser().parseFromString(await response.text(), "text/html")
      document.querySelectorAll("[data-live-region]").forEach((region) => {
        const update = fresh.querySelector(`[data-live-region="${region.dataset.liveRegion}"]`)
        if (update) region.innerHTML = update.innerHTML
      })
      const updated = fresh.querySelector(`[data-task-id="${card.dataset.taskId}"]`)
      if (updated) {
        card.replaceWith(updated)
      } else {
        // Filtered out by what changed (for example a status filter).
        card.remove()
      }
      this.refreshCounts()
    } catch {
      window.location.reload()
    }
  }

  refreshCounts() {
    this.columnTargets.forEach((column) => {
      const n = column.querySelectorAll("[data-task-id]").length
      column.querySelector("[data-task-board-target='count']").textContent = n
      column.querySelector("[data-task-board-target='empty']").classList.toggle("hidden", n > 0)
    })
  }

  highlight(column, on) {
    column.classList.toggle("ring-2", on)
    column.classList.toggle("ring-olive/40", on)
    column.classList.toggle("bg-olive/5", on)
  }

  announce(message) {
    if (this.hasStatusTarget) this.statusTarget.textContent = message
  }
}
