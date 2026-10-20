import { Controller } from "@hotwired/stimulus"

// Kanban board: drag a card to another column (or use the card's Move menu,
// which also covers touch and keyboard) and the task's status is saved through
// its state machine. The card moves right away and snaps back if the server
// refuses.
export default class extends Controller {
  static targets = ["column", "card", "list", "count", "empty", "status"]
  static values = { writable: Boolean }

  connect() {
    this.dragged = null
    this.element.addEventListener("dragstart", this.start)
    this.element.addEventListener("dragend", this.end)
  }

  disconnect() {
    this.element.removeEventListener("dragstart", this.start)
    this.element.removeEventListener("dragend", this.end)
  }

  start = (event) => {
    const card = event.target.closest?.("[data-task-id]")
    if (!card || !this.writableValue) return
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
    this.move(this.dragged, column.dataset.status)
  }

  select(event) {
    const card = event.target.closest("[data-task-id]")
    const column = this.columnTargets.find((c) => c.dataset.status === event.target.value)
    if (card && column) this.move(card, column.dataset.status)
  }

  async move(card, status) {
    const from = card.dataset.status
    if (from === status) return
    const column = this.columnTargets.find((c) => c.dataset.status === status)
    const previous = card.parentElement
    this.place(card, column, status)

    try {
      const response = await fetch(card.dataset.moveUrl, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify({ status })
      })
      if (!response.ok) throw new Error((await response.json().catch(() => ({}))).error || "Could not move the task.")
      this.announce(`Moved to ${column.querySelector("h3").textContent}.`)
    } catch (error) {
      previous.append(card)
      card.dataset.status = from
      const select = card.querySelector("select")
      if (select) select.value = from
      this.refresh()
      this.announce(error.message)
      card.animate([{ transform: "translateX(-4px)" }, { transform: "translateX(4px)" }, { transform: "none" }], 200)
    }
  }

  place(card, column, status) {
    column.querySelector("[data-task-board-target='list']").insertBefore(card, column.querySelector("[data-task-board-target='empty']"))
    card.dataset.status = status
    const select = card.querySelector("select")
    if (select) select.value = status
    const title = card.querySelector("p")
    title?.classList.toggle("line-through", status === "done")
    title?.classList.toggle("text-taupe", status === "done")
    this.refresh()
  }

  refresh() {
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
