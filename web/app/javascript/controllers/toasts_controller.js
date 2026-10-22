import { Controller } from "@hotwired/stimulus"

// The toast stack, bottom right, above the status bar. Anything on the page can
// raise one: window.dispatchEvent(new CustomEvent("rupert:toast", { detail: { title, body, href } })).
// At most three show at once; each goes away by itself or on Dismiss. Titles
// and bodies are placed as text only.
export default class extends Controller {
  static values = { max: { type: Number, default: 3 }, seconds: { type: Number, default: 8 } }

  connect() {
    this.onToast = (event) => this.show(event.detail || {})
    window.addEventListener("rupert:toast", this.onToast)
  }

  disconnect() {
    window.removeEventListener("rupert:toast", this.onToast)
  }

  show({ title, body, href }) {
    while (this.element.children.length >= this.maxValue) this.element.firstElementChild.remove()
    const toast = document.createElement("div")
    toast.className = "toast"
    toast.setAttribute("role", "status")
    const text = document.createElement("div")
    text.className = "toast-text"
    const strong = document.createElement("p")
    strong.className = "toast-title"
    strong.textContent = String(title || "")
    text.appendChild(strong)
    if (body) {
      const p = document.createElement("p")
      p.className = "toast-body"
      p.textContent = String(body)
      text.appendChild(p)
    }
    toast.appendChild(text)
    const actions = document.createElement("div")
    actions.className = "toast-actions"
    if (href) {
      const a = document.createElement("a")
      a.className = "btn-ghost btn-sm"
      a.href = href
      a.textContent = "Open"
      actions.appendChild(a)
    }
    const close = document.createElement("button")
    close.type = "button"
    close.className = "btn-ghost btn-sm"
    close.textContent = "Dismiss"
    close.addEventListener("click", () => toast.remove())
    actions.appendChild(close)
    toast.appendChild(actions)
    this.element.appendChild(toast)
    setTimeout(() => toast.remove(), this.secondsValue * 1000)
  }
}
