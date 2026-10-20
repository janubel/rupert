import { Controller } from "@hotwired/stimulus"

// The ? help drawer: this page's guide, a tour, a lesson and live search
// across lessons and definitions. Without JavaScript the header button is a
// plain link to Learn Rupert.
export default class extends Controller {
  static targets = ["panel", "backdrop", "trigger", "input", "results", "page"]

  connect() {
    this.onDocumentKeydown = (event) => this.documentKeydown(event)
    document.addEventListener("keydown", this.onDocumentKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onDocumentKeydown)
  }

  toggle(event) {
    if (event && typeof event.preventDefault === "function") event.preventDefault()
    this.isOpen ? this.close() : this.open()
  }

  open() {
    if (!this.hasPanelTarget) return
    this.returnFocus = document.activeElement
    this.panelTarget.classList.remove("hidden")
    if (this.hasBackdropTarget) this.backdropTarget.classList.remove("hidden")
    this.triggerTargets.forEach((button) => button.setAttribute("aria-expanded", "true"))
    document.body.classList.add("help-panel-open")
    if (this.hasInputTarget) this.inputTarget.focus()
  }

  close() {
    if (!this.hasPanelTarget || !this.isOpen) return
    this.panelTarget.classList.add("hidden")
    if (this.hasBackdropTarget) this.backdropTarget.classList.add("hidden")
    this.triggerTargets.forEach((button) => button.setAttribute("aria-expanded", "false"))
    document.body.classList.remove("help-panel-open")
    if (this.returnFocus && typeof this.returnFocus.focus === "function") this.returnFocus.focus()
  }

  startTour() {
    this.close()
    window.dispatchEvent(new CustomEvent("rupert:start-tour"))
  }

  openGuide() {
    this.close()
    const details = document.querySelector("details.workspace-help")
    if (details) {
      details.open = true
      details.querySelector("summary")?.focus()
      if (typeof details.scrollIntoView === "function") details.scrollIntoView({ block: "start" })
    }
  }

  search() {
    clearTimeout(this.searchTimer)
    const query = this.inputTarget.value.trim()
    if (!query) {
      this.resultsTarget.innerHTML = ""
      if (this.hasPageTarget) this.pageTarget.hidden = false
      return
    }
    this.searchTimer = setTimeout(() => this.fetchResults(query), 180)
  }

  async fetchResults(query) {
    const base = this.hasPanelTarget ? this.panelTarget.dataset.helpPanelSearchUrlValue : "/learning.json"
    const url = `${base}${base.includes("?") ? "&" : "?"}q=${encodeURIComponent(query)}`
    try {
      const response = await fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const data = await response.json()
      if (this.inputTarget.value.trim() !== query) return
      this.render(data)
    } catch (error) {
      this.resultsTarget.innerHTML = ""
      this.resultsTarget.append(this.text("p", "help-panel-empty", "Search is unavailable right now. Open Learn Rupert instead."))
    }
  }

  render(data) {
    const results = this.resultsTarget
    results.innerHTML = ""
    if (this.hasPageTarget) this.pageTarget.hidden = true
    const lessons = data.lessons || []
    const terms = data.terms || []
    const tours = data.tours || []
    if (!lessons.length && !terms.length && !tours.length) {
      results.append(this.text("p", "help-panel-empty", "No matches. Try a shorter word."))
      return
    }
    if (terms.length) {
      results.append(this.text("p", "eyebrow text-olive-deep", "Definitions"))
      const list = document.createElement("dl")
      list.className = "help-panel-terms"
      terms.forEach((term) => {
        const wrap = document.createElement("div")
        wrap.append(this.text("dt", "font-semibold", term.label), this.text("dd", "text-sm text-mocha", term.definition))
        list.append(wrap)
      })
      results.append(list)
    }
    if (lessons.length) {
      results.append(this.text("p", "eyebrow text-olive-deep", "Lessons"))
      const list = document.createElement("ul")
      list.className = "help-panel-lessons"
      lessons.forEach((lesson) => {
        const item = document.createElement("li")
        const link = document.createElement("a")
        link.href = lesson.url
        link.className = "help-panel-link"
        link.textContent = `${lesson.title} · ${lesson.minutes} min${lesson.completed ? " · Completed" : ""}`
        item.append(link, this.text("span", "block text-xs text-mocha", lesson.summary))
        list.append(item)
      })
      results.append(list)
    }
    if (tours.length) {
      results.append(this.text("p", "eyebrow text-olive-deep", "Tours"))
      const list = document.createElement("ul")
      tours.forEach((tour) => {
        const item = document.createElement("li")
        const link = document.createElement("a")
        link.href = tour.url
        link.className = "help-panel-link"
        link.textContent = `${tour.title}${tour.done ? " · Taken" : ""}`
        item.append(link)
        list.append(item)
      })
      results.append(list)
    }
  }

  keydown(event) {
    if (event.key === "Escape") { event.preventDefault(); this.close() }
  }

  documentKeydown(event) {
    if (event.key === "Escape" && this.isOpen) { this.close(); return }
    if (event.key !== "?" || event.ctrlKey || event.metaKey || event.altKey) return
    const target = event.target
    const tag = target && target.tagName ? target.tagName.toLowerCase() : ""
    if (["input", "textarea", "select"].includes(tag) || (target && target.isContentEditable)) return
    event.preventDefault()
    this.toggle()
  }

  text(tag, className, content) {
    const node = document.createElement(tag)
    node.className = className
    node.textContent = content
    return node
  }

  get isOpen() {
    return this.hasPanelTarget && !this.panelTarget.classList.contains("hidden")
  }
}
