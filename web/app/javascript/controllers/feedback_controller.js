import { Controller } from "@hotwired/stimulus"
import { buildSnapshot, errorFromEvent, maskControls, pushError, whenStylesLoaded } from "lib/feedback_capture"

// The ladybug: a report panel (bug, request or question) that sends the
// description with the page's address, build, recent JavaScript errors, an
// optional sanitized snapshot and an optional screenshot. Without JavaScript
// the header button is a plain link to My reports. Everything sent is cleaned
// again by the server; text typed here is only ever shown with textContent.
export default class extends Controller {
  static targets = ["panel", "backdrop", "trigger", "form", "kind", "severityField", "severity", "description", "submit",
    "status", "done", "doneMessage", "doneLink", "screenshot", "details", "count"]
  static values = { url: String, build: String, requestId: String }

  connect() {
    this.errors = []
    this.onError = (event) => pushError(this.errors, errorFromEvent(event))
    this.onKeydown = (event) => this.documentKeydown(event)
    window.addEventListener("error", this.onError)
    window.addEventListener("unhandledrejection", this.onError)
    document.addEventListener("keydown", this.onKeydown)
    this.kindChanged()
  }

  disconnect() {
    window.removeEventListener("error", this.onError)
    window.removeEventListener("unhandledrejection", this.onError)
    document.removeEventListener("keydown", this.onKeydown)
  }

  toggle(event) {
    if (event && typeof event.preventDefault === "function") event.preventDefault()
    this.isOpen ? this.close() : this.open()
  }

  open() {
    if (!this.hasPanelTarget) return
    this.returnFocus = document.activeElement
    this.panelTarget.classList.remove("hidden")
    this.backdropTarget.classList.remove("hidden")
    this.triggerTargets.forEach((button) => button.setAttribute("aria-expanded", "true"))
    document.body.classList.add("feedback-panel-open")
    this.descriptionTarget.focus()
  }

  close() {
    if (!this.isOpen) return
    this.panelTarget.classList.add("hidden")
    this.backdropTarget.classList.add("hidden")
    this.triggerTargets.forEach((button) => button.setAttribute("aria-expanded", "false"))
    document.body.classList.remove("feedback-panel-open")
    if (this.returnFocus && typeof this.returnFocus.focus === "function") this.returnFocus.focus()
  }

  // Severity only applies to bugs.
  kindChanged() {
    if (!this.hasSeverityFieldTarget) return
    this.severityFieldTarget.hidden = this.selectedKind !== "bug"
  }

  countCharacters() {
    if (this.hasCountTarget) this.countTarget.textContent = String(this.descriptionTarget.value.length)
  }

  async submit(event) {
    event.preventDefault()
    if (this.sending) return
    if (this.descriptionTarget.value.trim().length < 5) {
      this.showStatus("Tell us a little more (at least 5 characters).", true)
      this.descriptionTarget.focus()
      return
    }
    this.sending = true
    this.submitTarget.disabled = true
    this.showStatus("Sending…", false)
    try {
      const body = await this.buildBody()
      const response = await fetch(this.urlValue, { method: "POST", body, credentials: "same-origin",
        headers: { Accept: "application/json", "X-CSRF-Token": this.csrfToken() } })
      const data = await response.json().catch(() => ({}))
      if (!response.ok) throw new Error(data.error || `The report could not be sent (HTTP ${response.status}).`)
      this.finish(data)
    } catch (error) {
      this.showStatus(error && error.message ? error.message : "The report could not be sent.", true)
    } finally {
      this.sending = false
      this.submitTarget.disabled = false
    }
  }

  async buildBody() {
    const body = new FormData()
    body.append("feedback_report[kind]", this.selectedKind)
    if (this.selectedKind === "bug" && this.hasSeverityTarget) body.append("feedback_report[severity]", this.severityTarget.value)
    body.append("feedback_report[description]", this.descriptionTarget.value)
    body.append("feedback_report[page_url]", window.location.href)
    if (this.requestIdValue) body.append("feedback_report[page_request_id]", this.requestIdValue)
    if (this.detailsTarget.checked) {
      body.append("feedback_report[client]", JSON.stringify(this.clientDetails()))
      body.append("feedback_report[js_errors]", JSON.stringify(this.errors))
      body.append("feedback_report[dom_snapshot]", this.snapshot())
    }
    if (this.screenshotTarget.checked) {
      const blob = await this.captureScreenshot()
      if (blob) body.append("feedback_report[screenshot]", blob, "screenshot.jpg")
    }
    return body
  }

  clientDetails() {
    const theme = document.documentElement.dataset ? document.documentElement.dataset.theme : ""
    return {
      viewport: `${window.innerWidth}x${window.innerHeight}`,
      screen: window.screen ? `${window.screen.width}x${window.screen.height}` : "",
      pixel_ratio: window.devicePixelRatio || 1,
      language: navigator.language || "",
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || "",
      theme: theme || "herbal",
      online: navigator.onLine,
      touch: (navigator.maxTouchPoints || 0) > 0,
      page_title: document.title || ""
    }
  }

  snapshot() {
    try { return buildSnapshot(document) } catch (error) { return "" }
  }

  // A screenshot of what is on screen. The panel is left out. If the library
  // cannot load or draw (offline, an old browser) the report is sent without it.
  async captureScreenshot() {
    try {
      await import("html2canvas-pro")
      const html2canvas = window.html2canvas
      const canvas = await Promise.race([
        html2canvas(document.documentElement, {
          x: window.scrollX, y: window.scrollY, width: window.innerWidth, height: window.innerHeight,
          windowWidth: window.innerWidth, windowHeight: window.innerHeight, scale: 1, logging: false, imageTimeout: 3000,
          backgroundColor: getComputedStyle(document.body).backgroundColor,
          ignoreElements: (element) => element.hasAttribute && element.hasAttribute("data-feedback-ignore"),
          onclone: async (doc) => { await whenStylesLoaded(doc); maskControls(doc) }
        }),
        new Promise((_, reject) => setTimeout(() => reject(new Error("screenshot timed out")), 10000))
      ])
      for (const quality of [0.7, 0.45]) {
        const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", quality))
        if (blob && blob.size <= 1400000) return blob
      }
    } catch (error) {
      // Fall through: no screenshot.
    }
    return null
  }

  finish(data) {
    this.formTarget.hidden = true
    this.doneTarget.hidden = false
    this.doneMessageTarget.textContent = data.message || "Thank you. Your report was sent."
    this.doneLinkTarget.href = data.url || "/feedback_reports"
    this.formTarget.reset()
    this.kindChanged()
    this.countCharacters()
    this.showStatus("", false)
    this.doneMessageTarget.focus()
  }

  another() {
    this.doneTarget.hidden = true
    this.formTarget.hidden = false
    this.descriptionTarget.focus()
  }

  showStatus(message, isError) {
    this.statusTarget.textContent = message
    this.statusTarget.classList.toggle("text-rose", Boolean(isError))
  }

  csrfToken() {
    const meta = document.querySelector("meta[name='csrf-token']")
    return meta ? meta.getAttribute("content") : ""
  }

  keydown(event) {
    if (event.key === "Escape") { event.preventDefault(); this.close(); return }
    if (event.key === "Tab") this.trapFocus(event)
  }

  documentKeydown(event) {
    if (event.key === "Escape" && this.isOpen) this.close()
  }

  // Keeps Tab inside the open panel.
  trapFocus(event) {
    const focusable = Array.from(this.panelTarget.querySelectorAll("a[href], button:not([disabled]), input:not([disabled]), select, textarea"))
      .filter((node) => !node.hidden && !node.closest("[hidden]"))
    if (!focusable.length) return
    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus() }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus() }
  }

  get selectedKind() {
    const checked = this.kindTargets.find((radio) => radio.checked)
    return checked ? checked.value : "bug"
  }

  get isOpen() {
    return this.hasPanelTarget && !this.panelTarget.classList.contains("hidden")
  }
}
