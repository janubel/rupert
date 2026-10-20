import { Controller } from "@hotwired/stimulus"

// Guided page tour. Steps point at real elements marked data-tour="<anchor>";
// steps whose anchor is not on this page (hidden by permission or layout) are
// skipped. A tour never starts on its own: a person starts it from the help
// bar, the help panel or the welcome card (window event rupert:start-tour),
// or arrives with ?tour=1 after choosing "Show me around". Finishing or
// skipping records the tour for the account so the "New" badge goes away.
export default class extends Controller {
  static targets = ["trigger", "badge"]
  static values = {
    key: String,
    title: String,
    steps: Array,
    saveUrl: String,
    done: Boolean,
    autostart: Boolean
  }

  connect() {
    this.triggerTargets.forEach((button) => { button.hidden = false })
    this.onKeydown = (event) => this.keydown(event)
    this.onReposition = () => this.scheduleReposition()
    if (this.autostartValue && !this.doneValue) {
      this.startTimer = setTimeout(() => this.start(), 250)
    }
  }

  disconnect() {
    clearTimeout(this.startTimer)
    this.teardown()
  }

  start(event) {
    if (event && typeof event.preventDefault === "function") event.preventDefault()
    if (this.active) return
    this.steps = this.stepsValue.filter((step) => this.anchor(step.anchor))
    if (!this.steps.length) {
      this.openGuide()
      return
    }
    this.returnFocus = document.activeElement
    this.index = 0
    this.build()
    this.active = true
    document.addEventListener("keydown", this.onKeydown, true)
    window.addEventListener("resize", this.onReposition)
    window.addEventListener("scroll", this.onReposition, true)
    this.show()
  }

  next() {
    if (this.index >= this.steps.length - 1) {
      this.finish()
      return
    }
    this.index += 1
    this.show()
  }

  back() {
    if (this.index === 0) return
    this.index -= 1
    this.show()
  }

  skip() {
    this.finish()
  }

  finish() {
    this.teardown()
    this.record()
    this.badgeTargets.forEach((badge) => badge.remove())
    if (this.returnFocus && typeof this.returnFocus.focus === "function") this.returnFocus.focus()
    window.dispatchEvent(new CustomEvent("rupert:tour-finished", { detail: { key: this.keyValue } }))
  }

  // ---- rendering -------------------------------------------------------

  build() {
    this.backdrop = this.make("div", "tour-backdrop")
    this.spotlight = this.make("div", "tour-spotlight")
    this.popover = this.make("div", "tour-popover")
    this.popover.setAttribute("role", "dialog")
    this.popover.setAttribute("aria-modal", "true")
    this.popover.setAttribute("aria-labelledby", "tour-step-title")
    this.popover.innerHTML = `
      <p class="tour-progress" data-role="progress"></p>
      <h2 class="tour-title" id="tour-step-title" data-role="title"></h2>
      <p class="tour-body" data-role="body"></p>
      <div class="tour-actions">
        <button type="button" class="tour-skip" data-role="skip">Skip tour</button>
        <span class="tour-spacer"></span>
        <button type="button" class="btn-ghost btn-sm" data-role="back">Back</button>
        <button type="button" class="btn-primary btn-sm" data-role="next">Next</button>
      </div>`
    this.popover.querySelector("[data-role=skip]").addEventListener("click", () => this.skip())
    this.popover.querySelector("[data-role=back]").addEventListener("click", () => this.back())
    this.popover.querySelector("[data-role=next]").addEventListener("click", () => this.next())
    this.backdrop.addEventListener("click", () => this.skip())
    document.body.append(this.backdrop, this.spotlight, this.popover)
    document.body.classList.add("tour-active")
  }

  show() {
    const step = this.steps[this.index]
    const target = this.anchor(step.anchor)
    if (!target) {
      this.steps.splice(this.index, 1)
      if (!this.steps.length) return this.finish()
      if (this.index >= this.steps.length) this.index = this.steps.length - 1
      return this.show()
    }
    this.current = target
    this.popover.querySelector("[data-role=progress]").textContent = `${this.index + 1} of ${this.steps.length} · ${this.titleValue}`
    this.popover.querySelector("[data-role=title]").textContent = step.title
    this.popover.querySelector("[data-role=body]").textContent = step.body
    this.popover.querySelector("[data-role=back]").disabled = this.index === 0
    this.popover.querySelector("[data-role=next]").textContent = this.index === this.steps.length - 1 ? "Done" : "Next"
    const reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches
    if (typeof target.scrollIntoView === "function") {
      target.scrollIntoView({ block: "center", inline: "nearest", behavior: reduce ? "auto" : "smooth" })
    }
    this.reposition()
    // Let smooth scrolling settle, then place the popover precisely.
    clearTimeout(this.settleTimer)
    this.settleTimer = setTimeout(() => this.reposition(), reduce ? 0 : 350)
    this.popover.querySelector("[data-role=next]").focus()
  }

  reposition() {
    if (!this.active || !this.current) return
    const pad = 8
    const rect = this.current.getBoundingClientRect()
    const top = rect.top + window.scrollY - pad
    const left = rect.left + window.scrollX - pad
    Object.assign(this.spotlight.style, {
      top: `${top}px`, left: `${left}px`,
      width: `${rect.width + pad * 2}px`, height: `${rect.height + pad * 2}px`
    })
    const popWidth = Math.min(360, window.innerWidth - 32)
    const popHeight = this.popover.offsetHeight || 180
    const spaceBelow = window.innerHeight - rect.bottom
    const placeBelow = spaceBelow >= popHeight + 24 || rect.top < popHeight + 24
    const popTop = placeBelow ? rect.bottom + window.scrollY + pad + 8 : rect.top + window.scrollY - pad - 8 - popHeight
    let popLeft = rect.left + window.scrollX
    popLeft = Math.max(16 + window.scrollX, Math.min(popLeft, window.scrollX + window.innerWidth - popWidth - 16))
    Object.assign(this.popover.style, { top: `${popTop}px`, left: `${popLeft}px`, width: `${popWidth}px` })
    this.popover.dataset.placement = placeBelow ? "below" : "above"
  }

  scheduleReposition() {
    if (this.frame) return
    this.frame = requestAnimationFrame(() => { this.frame = null; this.reposition() })
  }

  teardown() {
    if (!this.active) return
    this.active = false
    clearTimeout(this.settleTimer)
    document.removeEventListener("keydown", this.onKeydown, true)
    window.removeEventListener("resize", this.onReposition)
    window.removeEventListener("scroll", this.onReposition, true)
    ;[this.backdrop, this.spotlight, this.popover].forEach((node) => node && node.remove())
    document.body.classList.remove("tour-active")
  }

  // ---- keyboard --------------------------------------------------------

  keydown(event) {
    if (!this.active) return
    if (event.key === "Escape") { event.preventDefault(); this.skip(); return }
    if (event.key === "ArrowRight") { event.preventDefault(); this.next(); return }
    if (event.key === "ArrowLeft") { event.preventDefault(); this.back(); return }
    if (event.key === "Tab") this.trapFocus(event)
  }

  trapFocus(event) {
    const focusable = Array.from(this.popover.querySelectorAll("button:not([disabled])"))
    if (!focusable.length) return
    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus() }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus() }
    else if (!this.popover.contains(document.activeElement)) { event.preventDefault(); first.focus() }
  }

  // ---- persistence -----------------------------------------------------

  record() {
    if (this.doneValue || !this.saveUrlValue) return
    this.doneValue = true
    const token = document.querySelector('meta[name="csrf-token"]')?.content || ""
    return fetch(this.saveUrlValue, {
      method: "PATCH",
      headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": token },
      body: JSON.stringify({ tour: this.keyValue })
    }).catch(() => {})
  }

  // ---- helpers ---------------------------------------------------------

  anchor(name) {
    const nodes = Array.from(document.querySelectorAll(`[data-tour="${name}"]`))
    return nodes.find((node) => this.visible(node)) || null
  }

  visible(node) {
    if (node.hidden || node.closest("[hidden]")) return false
    if (typeof node.getClientRects === "function") return node.getClientRects().length > 0
    return true
  }

  openGuide() {
    const details = this.element.querySelector("details.workspace-help")
    if (details) { details.open = true; details.querySelector("summary")?.focus() }
  }

  make(tag, className) {
    const node = document.createElement(tag)
    node.className = className
    return node
  }
}
