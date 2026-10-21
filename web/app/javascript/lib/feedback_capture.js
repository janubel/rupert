// Page diagnostics for the ladybug report: which form fields to hide, a
// sanitized page snapshot, and a small buffer of recent JavaScript errors.
// Pure functions over DOM-like objects so the controller test can exercise
// them without a browser.

export const MAX_ERRORS = 10
export const SNAPSHOT_LIMIT = 200000
export const MASK = "[hidden]"

const SENSITIVE_NAME = /pass(word|wd)?|secret|token|card|cvv|cvc|ccnum|ssn|social|\bpin\b|api[-_ ]?key|routing|account[-_ ]?num|iban/i
const SENSITIVE_AUTOCOMPLETE = /cc-|one-time-code|password/i
const HIDDEN_TYPES = ["password", "hidden", "file"]

// True for a field whose value must never leave the browser: passwords, card
// and account numbers, tokens, or anything inside [data-sensitive].
export function isSensitiveControl(control) {
  if (!control) return false
  const type = String(control.type || "").toLowerCase()
  if (HIDDEN_TYPES.includes(type)) return true
  if (control.dataset && control.dataset.sensitive !== undefined) return true
  if (typeof control.closest === "function" && control.closest("[data-sensitive]")) return true
  if (SENSITIVE_AUTOCOMPLETE.test(String(control.autocomplete || ""))) return true
  return [control.name, control.id, control.placeholder, control.getAttribute && control.getAttribute("aria-label")]
    .some((text) => SENSITIVE_NAME.test(String(text || "")))
}

// Applies the mask to every sensitive field of a cloned document, and shows
// the current value of the others (a clone only carries the original attribute).
export function maskControls(root) {
  root.querySelectorAll("input, textarea, select").forEach((control) => {
    if (isSensitiveControl(control)) {
      if ("value" in control) control.value = MASK
      control.setAttribute("value", MASK)
      if (control.tagName === "TEXTAREA") control.textContent = MASK
      return
    }
    const type = String(control.type || "").toLowerCase()
    if (type === "checkbox" || type === "radio") return
    if (control.tagName === "TEXTAREA") control.textContent = control.value || ""
    else control.setAttribute("value", control.value || "")
  })
  root.querySelectorAll("[data-sensitive]").forEach((node) => { node.textContent = MASK })
}

// Serializes a copy of the page: no scripts, styles, frames or the report panel
// itself, with sensitive fields hidden.
export function buildSnapshot(doc, limit = SNAPSHOT_LIMIT) {
  const copy = doc.documentElement.cloneNode(true)
  copy.querySelectorAll("script, style, link, noscript, iframe, object, embed, template, [data-feedback-ignore]").forEach((node) => node.remove())
  copy.querySelectorAll("*").forEach((node) => {
    Array.from(node.attributes || []).forEach((attribute) => {
      if (/^on/i.test(attribute.name)) node.removeAttribute(attribute.name)
    })
  })
  // Field values are read from the live page, because a clone carries only the
  // original attributes; the clone's values are matched by position.
  const live = Array.from(doc.querySelectorAll("input, textarea, select"))
  const cloned = Array.from(copy.querySelectorAll("input, textarea, select"))
  cloned.forEach((control, index) => {
    const source = live[index]
    if (source && "value" in source) control.value = source.value
  })
  maskControls(copy)
  const html = String(copy.outerHTML || "")
  return html.length > limit ? html.slice(0, limit) : html
}

// Keeps the last few errors, newest last. Text is cut so one noisy error
// cannot crowd out the rest.
export function pushError(list, entry) {
  list.push({
    message: String(entry.message || "").slice(0, 500),
    source: String(entry.source || "").slice(0, 300),
    line: entry.line || 0,
    column: entry.column || 0,
    stack: String(entry.stack || "").slice(0, 1000),
    at: new Date().toISOString()
  })
  while (list.length > MAX_ERRORS) list.shift()
  return list
}

export function errorFromEvent(event) {
  if (event && event.reason !== undefined) {
    const reason = event.reason
    return { message: reason && reason.message ? reason.message : String(reason), stack: reason && reason.stack, source: "unhandledrejection" }
  }
  const error = event && event.error
  return { message: (event && event.message) || (error && error.message), source: event && event.filename, line: event && event.lineno, column: event && event.colno, stack: error && error.stack }
}

// The screenshot library draws a copy of the page in a hidden frame; on a cold
// load that copy can be drawn before its stylesheets arrive. Waits (briefly)
// for any that are still loading.
export function whenStylesLoaded(doc, timeout = 2500) {
  const pending = Array.from(doc.querySelectorAll('link[rel="stylesheet"]')).filter((link) => !link.sheet)
  if (!pending.length) return Promise.resolve()
  const loaded = pending.map((link) => new Promise((resolve) => {
    link.addEventListener("load", resolve)
    link.addEventListener("error", resolve)
  }))
  return Promise.race([Promise.all(loaded), new Promise((resolve) => setTimeout(resolve, timeout))])
}
