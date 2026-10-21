import { Controller } from "@hotwired/stimulus"

// Ask Rupert: the help chat drawer behind the chat-bubble button. It talks to
// AskRupertController as JSON, shows replies as they are written (by polling
// the conversation while a reply is pending) and renders every reply as text:
// a small safe subset of Markdown (paragraphs, lists, bold, code and same-site
// links) is built with DOM nodes, never innerHTML. Without JavaScript the
// header button is not shown; Help (?) and Learn Rupert stay available.
export default class extends Controller {
  static targets = ["panel", "backdrop", "trigger", "log", "starters", "notice", "input", "submit", "form", "disclosure", "newButton", "clearButton", "history", "historyButton"]

  static VIA = { opencode: "cloud AI model", ollama: "model on this server" }
  static REPORT_KINDS = [["bug", "Something is broken"], ["request", "I'd like a change"], ["question", "I have a question"]]

  connect() {
    this.conversationId = null
    this.busy = false
    this.loaded = false
    this.cardCount = 0
    this.onDocumentKeydown = (event) => { if (event.key === "Escape" && this.isOpen) this.close() }
    document.addEventListener("keydown", this.onDocumentKeydown)
    // Help, the ladybug and Ask Rupert share the right edge of the screen: opening one closes the others.
    this.onPanelOpened = (event) => { if (event.detail !== "ask") this.close() }
    document.addEventListener("rupert:panel-opened", this.onPanelOpened)
    // The account menu's "Ask Rupert chats" opens the panel on the history list.
    this.onOpenAsk = async (event) => {
      if (!this.isOpen) await this.open()
      if (event.detail === "history") this.showHistory()
    }
    window.addEventListener("rupert:open-ask", this.onOpenAsk)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onDocumentKeydown)
    document.removeEventListener("rupert:panel-opened", this.onPanelOpened)
    window.removeEventListener("rupert:open-ask", this.onOpenAsk)
    this.stopPolling()
  }

  // --- opening and closing ---

  toggle(event) {
    if (event && typeof event.preventDefault === "function") event.preventDefault()
    this.isOpen ? this.close() : this.open()
  }

  async open() {
    if (!this.hasPanelTarget) return
    this.returnFocus = document.activeElement
    this.panelTarget.classList.remove("hidden")
    this.backdropTarget.classList.remove("hidden")
    this.triggerTargets.forEach((button) => button.setAttribute("aria-expanded", "true"))
    document.body.classList.add("help-panel-open")
    document.dispatchEvent(new CustomEvent("rupert:panel-opened", { detail: "ask" }))
    this.inputTarget.focus()
    await this.load()
  }

  close() {
    if (!this.isOpen) return
    if (this.historyOpen) this.setHistoryVisible(false)
    this.panelTarget.classList.add("hidden")
    this.backdropTarget.classList.add("hidden")
    this.triggerTargets.forEach((button) => button.setAttribute("aria-expanded", "false"))
    document.body.classList.remove("help-panel-open")
    this.stopPolling()
    if (this.returnFocus && typeof this.returnFocus.focus === "function") this.returnFocus.focus()
  }

  // The panel sits outside the controller's own element tree in the markup, so its
  // addresses are read from the panel itself (as the help panel does).
  get stateUrl() { return this.panelTarget.dataset.askRupertStateUrlValue }
  get conversationsUrl() { return this.panelTarget.dataset.askRupertConversationsUrlValue }
  get page() { return this.panelTarget.dataset.askRupertPageValue }

  get isOpen() {
    return this.hasPanelTarget && !this.panelTarget.classList.contains("hidden")
  }

  // Keeps Tab inside the open panel.
  trapFocus(event) {
    if (event.key !== "Tab") return
    const items = [...this.panelTarget.querySelectorAll("button:not([disabled]), a[href], textarea:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex='0']")]
      .filter((item) => item.offsetParent !== null)
    if (!items.length) return
    const first = items[0]
    const last = items[items.length - 1]
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus() }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus() }
  }

  // --- loading and polling ---

  async load() {
    try {
      const response = await fetch(this.stateUrl, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const data = await response.json()
      this.disclosureTarget.textContent = data.disclosure
      this.inputTarget.maxLength = data.limits.max_chars
      this.starters = data.starters || []
      this.loaded = true
      this.showConversation(data.conversation)
      if (data.conversation?.busy) this.startPolling()
    } catch (error) {
      this.disclosureTarget.textContent = "Ask Rupert can’t be reached right now. Help (?) and Learn Rupert still work."
      this.showNotice("Could not load the chat. Close and reopen it to try again.")
    }
  }

  showConversation(conversation) {
    this.conversationId = conversation ? conversation.id : null
    this.logTarget.replaceChildren()
    this.hideNotice()
    this.renderMessages(conversation ? conversation.messages : [])
    this.setBusy(Boolean(conversation?.busy))
    this.logTarget.scrollTop = this.logTarget.scrollHeight
  }

  startPolling() {
    this.stopPolling()
    this.pollStarted = Date.now()
    this.schedulePoll()
  }

  schedulePoll() {
    const wait = Date.now() - this.pollStarted < 30000 ? 800 : 2000
    this.pollTimer = setTimeout(() => this.poll(), wait)
  }

  stopPolling() {
    clearTimeout(this.pollTimer)
    this.pollTimer = null
  }

  async poll() {
    if (!this.conversationId || !this.isOpen) return
    try {
      const response = await fetch(`${this.conversationsUrl}/${this.conversationId}`, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const data = await response.json()
      this.renderMessages(data.messages)
      this.setBusy(data.busy)
      if (data.busy) this.schedulePoll()
    } catch (error) {
      this.showNotice("Lost the connection. Close and reopen the chat to see the reply.")
      this.setBusy(false)
    }
  }

  // --- sending ---

  async send(event) {
    if (event) event.preventDefault()
    const text = this.inputTarget.value.trim()
    if (!text || this.busy || this.sending) return
    this.sending = true
    this.submitTarget.disabled = true
    this.hideNotice()
    try {
      if (!this.conversationId) await this.createConversation()
      const response = await this.post(`${this.conversationsUrl}/${this.conversationId}/messages`, { message: text, page_path: this.page })
      if (response.status === 202) {
        const data = await response.json()
        this.inputTarget.value = ""
        this.grow()
        this.renderMessages(data.messages)
        this.setBusy(data.busy)
        this.startPolling()
      } else {
        const data = await response.json().catch(() => ({}))
        this.showNotice(data.error || "That did not send. Try again.")
      }
    } catch (error) {
      this.showNotice("Could not reach Rupert. Check your connection and try again.")
    } finally {
      this.sending = false
      this.submitTarget.disabled = this.busy
    }
  }

  async createConversation() {
    const response = await this.post(this.conversationsUrl)
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const data = await response.json()
    this.conversationId = data.conversation.id
  }

  ask(event) {
    this.inputTarget.value = event.currentTarget.dataset.question
    this.send()
  }

  keydown(event) {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault()
      this.send()
    }
  }

  grow() {
    const field = this.inputTarget
    field.style.height = "auto"
    field.style.height = `${Math.min(field.scrollHeight, 140)}px`
  }

  setBusy(busy) {
    this.busy = busy
    this.submitTarget.disabled = busy || this.sending
    this.logTarget.setAttribute("aria-busy", busy ? "true" : "false")
  }

  // --- chat history ---

  toggleHistory() {
    this.historyOpen ? this.hideHistory() : this.showHistory()
  }

  get historyOpen() {
    return !this.historyTarget.classList.contains("hidden")
  }

  async showHistory() {
    this.stopPolling()
    this.setHistoryVisible(true)
    this.historyTarget.replaceChildren(this.note("Loading your chats…", "ask-history-empty"))
    try {
      const response = await fetch(this.conversationsUrl, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const data = await response.json()
      this.renderHistory(data.conversations)
    } catch (error) {
      this.historyTarget.replaceChildren(this.note("Could not load your chats. Try again.", "ask-history-empty"))
    }
  }

  hideHistory() {
    this.setHistoryVisible(false)
    if (this.busy) this.startPolling()
    this.inputTarget.focus()
  }

  setHistoryVisible(visible) {
    this.historyTarget.classList.toggle("hidden", !visible)
    this.logTarget.classList.toggle("hidden", visible)
    this.formTarget.classList.toggle("hidden", visible)
    if (visible) this.startersTarget.classList.add("hidden")
    else this.renderStarters(!this.logTarget.querySelector(".ask-msg"))
    this.historyButtonTarget.setAttribute("aria-expanded", visible ? "true" : "false")
    this.historyButtonTarget.textContent = visible ? "Back to chat" : "History"
  }

  renderHistory(conversations) {
    this.historyTarget.replaceChildren()
    if (!conversations.length) {
      this.historyTarget.append(this.note("No saved chats yet. Ask a question and it will be saved here.", "ask-history-empty"))
      return
    }
    const list = document.createElement("ul")
    list.className = "ask-history-list"
    conversations.forEach((conversation) => {
      const item = document.createElement("li")
      const open = document.createElement("button")
      open.type = "button"
      open.className = "ask-history-open"
      const title = document.createElement("span")
      title.className = "ask-history-title"
      title.textContent = conversation.title
      const when = document.createElement("span")
      when.className = "ask-history-when"
      when.textContent = new Date(conversation.at).toLocaleString([], { dateStyle: "medium", timeStyle: "short" })
      open.append(title, when)
      open.addEventListener("click", () => this.openConversation(conversation.id))
      item.append(open)
      list.append(item)
    })
    this.historyTarget.append(list)
  }

  async openConversation(id) {
    try {
      const response = await fetch(`${this.conversationsUrl}/${id}`, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const data = await response.json()
      this.setHistoryVisible(false)
      this.showConversation(data)
      if (data.busy) this.startPolling()
      this.inputTarget.focus()
    } catch (error) {
      this.showNotice("Could not open that chat.")
    }
  }

  // --- chat management ---

  async newChat() {
    if (this.historyOpen) this.setHistoryVisible(false)
    if (this.busy) return
    const empty = !this.logTarget.querySelector(".ask-msg")
    if (!empty) {
      const response = await this.post(this.conversationsUrl)
      if (!response.ok) return this.showNotice("Could not start a new chat.")
      const data = await response.json()
      this.showConversation(data.conversation)
    }
    this.inputTarget.focus()
  }

  async clear() {
    if (!this.conversationId) return
    if (!window.confirm("Delete this chat? It cannot be brought back.")) return
    this.stopPolling()
    const response = await fetch(`${this.conversationsUrl}/${this.conversationId}`, { method: "DELETE", headers: { "X-CSRF-Token": this.csrf, Accept: "application/json" }, credentials: "same-origin" })
    if (!response.ok && response.status !== 404) return this.showNotice("Could not delete the chat.")
    this.showConversation(null)
    this.inputTarget.focus()
  }

  async reportChat() {
    if (!this.conversationId) {
      try { await this.createConversation() } catch (error) { return this.showNotice("Could not start a report.") }
    }
    this.logTarget.querySelector(".ask-report-open")?.remove()
    const card = this.reportCard({ kind: "question", summary: "", details: "" })
    card.classList.add("ask-report-open")
    this.logTarget.append(card)
    card.scrollIntoView?.({ block: "end" })
    card.querySelector("input, textarea, select")?.focus()
  }

  // --- rendering ---

  renderMessages(messages) {
    const nearBottom = this.logTarget.scrollHeight - this.logTarget.scrollTop - this.logTarget.clientHeight < 80
    messages.forEach((message) => this.renderMessage(message))
    this.renderStarters(messages.length === 0)
    this.clearButtonTarget.disabled = !this.conversationId
    if (nearBottom) this.logTarget.scrollTop = this.logTarget.scrollHeight
  }

  renderMessage(message) {
    let item = this.logTarget.querySelector(`[data-message-id="${message.id}"]`)
    if (!item) {
      item = document.createElement("div")
      item.dataset.messageId = message.id
      item.className = `ask-msg ask-msg-${message.role}`
      const who = document.createElement("span")
      who.className = "sr-only"
      who.textContent = message.role === "user" ? "You said:" : "Rupert said:"
      const bubble = document.createElement("div")
      bubble.className = "ask-bubble"
      item.append(who, bubble)
      this.logTarget.querySelector(".ask-report-open")?.remove()
      this.logTarget.append(item)
    }
    const bubble = item.querySelector(".ask-bubble")
    const signature = `${message.status}|${message.content}`
    if (item.dataset.signature !== signature) {
      item.dataset.signature = signature
      bubble.replaceChildren()
      if (message.role === "assistant" && message.status === "pending" && !message.content) {
        bubble.append(this.thinking())
      } else if (message.role === "assistant") {
        bubble.append(...this.constructor.renderBlocks(this.constructor.parseBlocks(message.content)))
      } else {
        const paragraph = document.createElement("p")
        paragraph.textContent = message.content
        bubble.append(paragraph)
      }
      item.classList.toggle("ask-msg-failed", message.status === "failed")
    }
    this.renderExtras(item, message)
  }

  renderExtras(item, message) {
    item.querySelectorAll(".ask-extra").forEach((node) => node.remove())
    if (message.role !== "assistant" || message.status === "pending") return
    if (message.links?.length) {
      const row = document.createElement("p")
      row.className = "ask-links ask-extra"
      message.links.forEach((link) => {
        const anchor = document.createElement("a")
        anchor.href = link.path
        anchor.className = "ask-chip"
        anchor.textContent = link.kind === "lesson" ? `Learn: ${link.title}` : `Open ${link.title}`
        row.append(anchor)
      })
      item.append(row)
    }
    if (message.report_draft) {
      const draft = message.report_draft
      const card = draft.filed
        ? this.note("Report sent to the Rupert team. Thank you.", "ask-extra ask-report-done")
        : this.reportCard({ kind: draft.kind, summary: draft.summary, details: draft.details, messageId: message.id })
      card.classList.add("ask-extra")
      item.append(card)
    }
    if (message.provider && this.constructor.VIA[message.provider] && message.status === "done") {
      const via = document.createElement("p")
      via.className = "ask-via ask-extra"
      via.textContent = `Answered by a ${this.constructor.VIA[message.provider]}`
      item.append(via)
    }
  }

  thinking() {
    const wrap = document.createElement("span")
    wrap.className = "ask-thinking"
    wrap.textContent = "Rupert is thinking"
    const dots = document.createElement("span")
    dots.className = "ask-dots"
    dots.setAttribute("aria-hidden", "true")
    dots.textContent = "…"
    wrap.append(dots)
    return wrap
  }

  renderStarters(show) {
    const box = this.startersTarget
    const wanted = show && this.starters && this.starters.length > 0
    box.classList.toggle("hidden", !wanted)
    if (!wanted) { box.replaceChildren(); return }
    if (box.childElementCount) return
    const lead = document.createElement("p")
    lead.className = "ask-starters-lead"
    lead.textContent = "I can show you where things are and how to do them. Try:"
    box.append(lead)
    this.starters.forEach((question) => {
      const button = document.createElement("button")
      button.type = "button"
      button.className = "ask-starter"
      button.dataset.question = question
      button.dataset.action = "ask-rupert#ask"
      button.textContent = question
      box.append(button)
    })
  }

  // --- the report card ---

  reportCard({ kind, summary, details, messageId }) {
    const id = `ask-report-${++this.cardCount}`
    const form = document.createElement("form")
    form.className = "ask-report"
    form.setAttribute("aria-label", "Report to the Rupert team")
    const heading = document.createElement("p")
    heading.className = "ask-report-title"
    heading.textContent = "Report this to the Rupert team"
    const help = document.createElement("p")
    help.className = "ask-report-help"
    help.textContent = "Read it, change anything you like, then send. This chat is attached so the team can see what you tried."
    const kindSelect = this.field(id, "kind", "What is it?", "select", kind)
    this.constructor.REPORT_KINDS.forEach(([value, label]) => {
      const option = document.createElement("option")
      option.value = value
      option.textContent = label
      kindSelect.control.append(option)
    })
    kindSelect.control.value = this.constructor.REPORT_KINDS.some(([value]) => value === kind) ? kind : "question"
    const summaryField = this.field(id, "summary", "In one line", "input", summary)
    summaryField.control.maxLength = 200
    const detailsField = this.field(id, "details", "More detail (optional)", "textarea", details)
    detailsField.control.rows = 3
    detailsField.control.maxLength = 2000
    const send = document.createElement("button")
    send.type = "submit"
    send.className = "btn-primary btn-sm"
    send.textContent = "Send report"
    const cancel = document.createElement("button")
    cancel.type = "button"
    cancel.className = "btn-ghost btn-sm"
    cancel.textContent = "Not now"
    cancel.addEventListener("click", () => form.remove())
    const status = document.createElement("p")
    status.className = "ask-report-status"
    status.setAttribute("role", "status")
    const actions = document.createElement("div")
    actions.className = "ask-report-actions"
    actions.append(send, cancel)
    form.append(heading, help, kindSelect.wrap, summaryField.wrap, detailsField.wrap, actions, status)
    form.addEventListener("submit", (event) => {
      event.preventDefault()
      this.submitReport(form, status, send, { kind: kindSelect.control.value, summary: summaryField.control.value, details: detailsField.control.value, message_id: messageId })
    })
    return form
  }

  field(id, name, label, tag, value) {
    const wrap = document.createElement("div")
    wrap.className = "ask-report-field"
    const labelNode = document.createElement("label")
    labelNode.htmlFor = `${id}-${name}`
    labelNode.className = "field-label"
    labelNode.textContent = label
    const control = document.createElement(tag)
    control.id = `${id}-${name}`
    control.className = tag === "select" ? "select" : "ask-input"
    if (tag !== "select") control.value = value || ""
    wrap.append(labelNode, control)
    return { wrap, control }
  }

  async submitReport(form, status, send, fields) {
    if (fields.summary.trim().length < 3) { status.textContent = "Add a line saying what this is about."; return }
    send.disabled = true
    status.textContent = "Sending…"
    try {
      const response = await this.post(`${this.conversationsUrl}/${this.conversationId}/report`, fields)
      const data = await response.json().catch(() => ({}))
      if (response.ok) {
        form.replaceWith(this.note(data.message || "Report sent. Thank you.", "ask-report-done"))
      } else {
        status.textContent = data.error || "Could not send the report. Try again."
        send.disabled = false
      }
    } catch (error) {
      status.textContent = "Could not reach Rupert. Try again."
      send.disabled = false
    }
  }

  note(text, className) {
    const note = document.createElement("p")
    note.className = className
    note.setAttribute("role", "status")
    note.textContent = text
    return note
  }

  // --- notices and requests ---

  showNotice(text) {
    this.noticeTarget.textContent = text
    this.noticeTarget.classList.remove("hidden")
  }

  hideNotice() {
    this.noticeTarget.textContent = ""
    this.noticeTarget.classList.add("hidden")
  }

  get csrf() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }

  post(url, body) {
    return fetch(url, {
      method: "POST", credentials: "same-origin",
      headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": this.csrf },
      body: JSON.stringify(body || {})
    })
  }

  // --- reply text: a small, safe Markdown subset ---

  // Text to blocks: [{ type: "p" | "ul" | "ol", items: [inline[]] }]. No HTML is ever parsed.
  static parseBlocks(text) {
    const blocks = []
    let current = null
    const flush = () => { if (current) blocks.push(current); current = null }
    String(text || "").replace(/\r/g, "").split("\n").forEach((line) => {
      const bullet = line.match(/^\s*[-*•]\s+(.*)$/)
      const number = line.match(/^\s*\d+[.)]\s+(.*)$/)
      if (bullet || number) {
        const type = bullet ? "ul" : "ol"
        if (!current || current.type !== type) { flush(); current = { type, items: [] } }
        current.items.push(this.parseInline((bullet || number)[1]))
      } else if (line.trim() === "") {
        flush()
      } else {
        if (!current || current.type !== "p") { flush(); current = { type: "p", items: [] } }
        current.items.push(this.parseInline(line))
      }
    })
    flush()
    return blocks
  }

  // Inline pieces: text, bold, code, and links that stay inside Rupert ("/path" only).
  static parseInline(text) {
    const parts = []
    const pattern = /\*\*([^*]+)\*\*|`([^`]+)`|\[([^\]]+)\]\((\/(?!\/)[^)\s]*)\)/g
    let last = 0
    let match
    while ((match = pattern.exec(text)) !== null) {
      if (match.index > last) parts.push({ type: "text", text: text.slice(last, match.index) })
      if (match[1] !== undefined) parts.push({ type: "bold", text: match[1] })
      else if (match[2] !== undefined) parts.push({ type: "code", text: match[2] })
      else parts.push({ type: "link", text: match[3], href: match[4] })
      last = pattern.lastIndex
    }
    if (last < text.length) parts.push({ type: "text", text: text.slice(last) })
    return parts
  }

  static renderBlocks(blocks) {
    const inline = (parts, parent) => parts.forEach((part) => {
      if (part.type === "text") { parent.append(document.createTextNode(part.text)); return }
      const node = document.createElement(part.type === "bold" ? "strong" : part.type === "code" ? "code" : "a")
      node.textContent = part.text
      if (part.type === "link") node.href = part.href
      parent.append(node)
    })
    return blocks.map((block) => {
      if (block.type === "p") {
        const paragraph = document.createElement("p")
        block.items.forEach((parts, index) => {
          if (index > 0) paragraph.append(document.createElement("br"))
          inline(parts, paragraph)
        })
        return paragraph
      }
      const list = document.createElement(block.type)
      block.items.forEach((parts) => {
        const item = document.createElement("li")
        inline(parts, item)
        list.append(item)
      })
      return list
    })
  }
}
