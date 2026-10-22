import { Controller } from "@hotwired/stimulus"

// Team chat tab on the Buzz page. Shows the channel's recent messages from
// BuzzChatController as JSON, keeps them current by polling, loads earlier
// messages on request and posts through the same controller.
//
// Every message is other people's text: it is only ever put on the page with
// textContent / DOM nodes, never innerHTML. A small safe subset of formatting
// (**bold**, `code`, http(s) links, line breaks) is built from DOM nodes, and a
// link is plain text plus an href. Nothing linked is fetched or previewed.
export default class extends Controller {
  static targets = ["log", "more", "status", "notice", "form", "input", "send", "count", "jump", "empty", "loading", "search"]
  static values = { url: String, channel: String, canPost: Boolean, postMax: { type: Number, default: 1500 }, interval: { type: Number, default: 4000 } }

  static GROUP_SECONDS = 5 * 60

  connect() {
    this.messages = []
    this.ids = new Set()
    this.hasMore = false
    this.status = null
    this.sending = false
    this.busy = false
    this.loadFailed = false
    this.fetchFailed = false
    this.load()
    this.timer = setInterval(() => this.poll(), this.intervalValue)
    this.onVisible = () => { if (!document.hidden) this.poll() }
    document.addEventListener("visibilitychange", this.onVisible)
    this.ticker = setInterval(() => this.renderStatus(), 15000)
  }

  disconnect() {
    clearInterval(this.timer)
    clearInterval(this.ticker)
    document.removeEventListener("visibilitychange", this.onVisible)
  }

  // --- parsing (pure; also used by the tests) ---

  // Splits one line of text into parts: text, bold, code and link. Markup the
  // person typed stays text; only http(s) URLs become links.
  static parseLine(line) {
    const parts = []
    const pattern = /`([^`\n]+)`|\*\*([^*\n]+)\*\*|(https?:\/\/[^\s<>"'`]+)/g
    let last = 0
    let match
    const push = (type, value, extra = {}) => { if (value) parts.push({ type, text: value, ...extra }) }
    while ((match = pattern.exec(line)) !== null) {
      push("text", line.slice(last, match.index))
      last = match.index + match[0].length
      if (match[1] !== undefined) push("code", match[1])
      else if (match[2] !== undefined) push("bold", match[2])
      else {
        let url = match[3]
        let trailing = ""
        while (/[.,;:!?)\]}'"]$/.test(url) && !(url.endsWith(")") && url.includes("("))) {
          trailing = url.slice(-1) + trailing
          url = url.slice(0, -1)
        }
        const safe = this.safeUrl(url)
        if (safe) push("link", url, { href: safe })
        else push("text", url)
        push("text", trailing)
      }
    }
    push("text", line.slice(last))
    return parts
  }

  static safeUrl(value) {
    try {
      const url = new URL(value)
      if (url.protocol !== "http:" && url.protocol !== "https:") return null
      if (url.username || url.password) return null
      return url.href
    } catch (_error) {
      return null
    }
  }

  // --- loading ---

  async load() {
    this.showLoading(true)
    await this.fetchMessages({ initial: true })
    this.showLoading(false)
  }

  async poll() {
    if (document.hidden || this.busy || this.sending) return
    const last = this.messages[this.messages.length - 1]
    await this.fetchMessages({ after: last ? last.cursor : null })
  }

  async fetchMessages({ initial = false, after = null, before = null } = {}) {
    this.busy = true
    try {
      const params = new URLSearchParams()
      if (this.channelValue) params.set("channel", this.channelValue)
      if (after) params.set("after", after)
      if (before) params.set("before", before)
      const query = params.toString()
      const response = await fetch(`${this.urlValue}${query ? `?${query}` : ""}`, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      if (response.status === 403 || response.status === 404) throw new Error("denied")
      if (!response.ok) throw new Error("failed")
      const data = await response.json()
      this.fetchFailed = false
      this.status = data.status
      if (before) {
        this.prependMessages(data.messages)
        this.hasMore = data.has_more
        this.loadFailed = data.older_failed
      } else if (initial) {
        this.messages = []
        this.ids = new Set()
        this.appendMessages(data.messages, { stick: true })
        this.hasMore = data.has_more
      } else {
        this.appendMessages(data.messages, { stick: false })
      }
      this.renderMore()
    } catch (_error) {
      this.fetchFailed = true
    } finally {
      this.busy = false
      this.renderStatus()
    }
  }

  async loadEarlier() {
    if (this.busy || !this.messages.length) return
    this.moreTarget.disabled = true
    this.moreTarget.textContent = "Loading…"
    await this.fetchMessages({ before: this.messages[0].cursor })
  }

  // --- rendering ---

  appendMessages(list, { stick }) {
    const fresh = list.filter((message) => !this.ids.has(message.id))
    if (!fresh.length) {
      this.renderEmpty()
      return
    }
    const log = this.logTarget
    const atBottom = stick || log.scrollHeight - log.scrollTop - log.clientHeight < 80
    fresh.forEach((message) => { this.ids.add(message.id) })
    this.messages = this.messages.concat(fresh)
    this.renderAll()
    if (atBottom) {
      this.jumpTo(log.scrollHeight)
      this.hideJump()
    } else {
      this.showJump()
    }
  }

  prependMessages(list) {
    const fresh = list.filter((message) => !this.ids.has(message.id))
    const log = this.logTarget
    const before = log.scrollHeight
    fresh.forEach((message) => { this.ids.add(message.id) })
    this.messages = fresh.concat(this.messages)
    this.renderAll()
    this.jumpTo(log.scrollTop + log.scrollHeight - before)
  }

  // The log scrolls smoothly for people; loading and restoring positions must not animate.
  jumpTo(top) {
    this.logTarget.scrollTo({ top, behavior: "instant" })
  }

  renderAll() {
    const holder = this.logTarget.querySelector("[data-buzz-chat-list]")
    holder.replaceChildren()
    let previous = null
    this.messages.forEach((message) => {
      const day = new Date(message.at)
      if (!previous || !this.sameDay(new Date(previous.at), day)) holder.append(this.dayDivider(day))
      const grouped = previous && this.sameDay(new Date(previous.at), day) && this.sameAuthor(previous, message) &&
        (day - new Date(previous.at)) / 1000 < this.constructor.GROUP_SECONDS
      holder.append(this.buildMessage(message, grouped))
      previous = message
    })
    this.renderEmpty()
  }

  buildMessage(message, grouped) {
    const item = document.createElement("article")
    item.className = "buzz-msg"
    if (message.agent) item.classList.add("buzz-msg-agent")
    if (message.mine) item.classList.add("buzz-msg-mine")
    if (grouped) item.classList.add("buzz-msg-grouped")
    item.dataset.messageId = message.id

    const row = document.createElement("div")
    row.className = "buzz-msg-row"
    const avatar = this.avatar(message.author, message.key)
    if (grouped) avatar.classList.add("is-spacer")
    row.append(avatar)

    const main = document.createElement("div")
    main.className = "buzz-msg-main"
    if (!grouped) {
      const head = document.createElement("header")
      head.className = "buzz-msg-head"
      const name = document.createElement("span")
      name.className = message.named ? "buzz-msg-author" : "buzz-msg-author buzz-msg-unnamed"
      name.textContent = message.author
      name.title = message.key
      head.append(name)
      if (message.agent) head.append(this.badge(message.via_rupert ? "via Rupert" : "AI agent", "buzz-badge-agent"))
      const time = document.createElement("time")
      time.className = "buzz-msg-time"
      time.dateTime = message.at
      time.textContent = this.timeLabel(new Date(message.at))
      time.title = new Date(message.at).toLocaleString()
      head.append(time)
      main.append(head)
    }
    const body = document.createElement("div")
    body.className = "buzz-msg-body"
    message.text.split("\n").forEach((line, index) => {
      if (index > 0) body.append(document.createElement("br"))
      this.constructor.parseLine(line).forEach((part) => body.append(this.partNode(part)))
    })
    main.append(body)
    row.append(main)
    item.append(row)
    return item
  }

  avatar(name, key) {
    const node = document.createElement("span")
    node.className = "buzz-msg-avatar"
    node.setAttribute("aria-hidden", "true")
    node.textContent = this.constructor.initials(name)
    let hash = 0
    for (const char of String(key || name || "")) hash = (hash * 31 + char.charCodeAt(0)) % 360
    node.style.background = `hsl(${hash} 38% 48%)`
    return node
  }

  static initials(name) {
    const words = String(name || "?").trim().split(/\s+/).filter(Boolean)
    return (words.slice(0, 2).map((word) => word[0]).join("") || "?").toUpperCase()
  }

  partNode(part) {
    if (part.type === "text") return document.createTextNode(part.text)
    if (part.type === "bold") {
      const strong = document.createElement("strong")
      strong.textContent = part.text
      return strong
    }
    if (part.type === "code") {
      const code = document.createElement("code")
      code.textContent = part.text
      return code
    }
    const link = document.createElement("a")
    link.href = part.href
    link.textContent = part.text
    link.target = "_blank"
    link.rel = "noopener noreferrer nofollow ugc"
    return link
  }

  badge(text, extra) {
    const span = document.createElement("span")
    span.className = `buzz-badge ${extra}`
    span.textContent = text
    return span
  }

  dayDivider(day) {
    const divider = document.createElement("div")
    divider.className = "buzz-day"
    divider.setAttribute("role", "separator")
    const label = document.createElement("span")
    label.textContent = this.dayLabel(day)
    divider.append(label)
    return divider
  }

  renderMore() {
    const button = this.moreTarget
    button.hidden = !this.hasMore
    button.disabled = false
    button.textContent = this.loadFailed ? "Couldn’t load earlier messages. Try again" : "Load earlier messages"
  }

  renderEmpty() {
    if (this.hasEmptyTarget) this.emptyTarget.hidden = this.messages.length > 0
  }

  showLoading(on) {
    if (this.hasLoadingTarget) this.loadingTarget.hidden = !on
  }

  renderStatus() {
    if (!this.hasStatusTarget) return
    const node = this.statusTarget
    let text = ""
    let tone = "ok"
    if (this.fetchFailed) {
      text = "Rupert can’t be reached right now. Retrying…"
      tone = "bad"
    } else if (this.status && this.status.error) {
      const reason = this.status.error.charAt(0).toUpperCase() + this.status.error.slice(1)
      const when = this.status.synced_at ? ` Showing saved messages from ${this.ago(this.status.synced_at)}.` : " Showing what Rupert has saved."
      text = `Not live. ${reason.replace(/\.$/, "")}.${when}`
      tone = "warn"
    } else if (this.status && this.status.synced_at) {
      text = `Live · updated ${this.ago(this.status.synced_at)}`
    } else if (this.status) {
      text = "Connecting to Buzz…"
    }
    node.textContent = text
    node.dataset.tone = tone
  }

  showJump() { if (this.hasJumpTarget) this.jumpTarget.hidden = false }
  hideJump() { if (this.hasJumpTarget) this.jumpTarget.hidden = true }

  scrollToEnd() {
    this.logTarget.scrollTo({ top: this.logTarget.scrollHeight, behavior: "smooth" })
    this.hideJump()
  }

  onScroll() {
    const log = this.logTarget
    if (log.scrollHeight - log.scrollTop - log.clientHeight < 80) this.hideJump()
  }

  // The workspace search filters the channel rail. Buzz's full search spans all
  // history; the mirror keeps this to the channels that are on screen.
  filter() {
    if (!this.hasSearchTarget) return
    const query = this.searchTarget.value.trim().toLowerCase()
    this.element.querySelectorAll(".buzz-rail-channel").forEach((link) => {
      link.hidden = query.length > 0 && !link.textContent.toLowerCase().includes(query)
    })
  }

  // --- posting ---

  keydown(event) {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault()
      this.send(event)
    }
  }

  input() {
    const field = this.inputTarget
    field.style.height = "auto"
    field.style.height = `${Math.min(field.scrollHeight, 160)}px`
    const length = field.value.length
    if (this.hasCountTarget) {
      this.countTarget.hidden = length < this.postMaxValue * 0.8
      this.countTarget.textContent = `${length} / ${this.postMaxValue}`
      this.countTarget.dataset.over = length > this.postMaxValue ? "true" : "false"
    }
    this.sendTarget.disabled = this.sending || !field.value.trim() || length > this.postMaxValue
  }

  async send(event) {
    if (event) event.preventDefault()
    if (this.sending || !this.canPostValue) return
    const text = this.inputTarget.value.trim()
    if (!text || text.length > this.postMaxValue) return
    this.sending = true
    this.sendTarget.disabled = true
    this.setNotice("")
    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": this.csrf },
        credentials: "same-origin",
        body: JSON.stringify({ message: text, channel: this.channelValue })
      })
      const data = await response.json().catch(() => ({}))
      if (!response.ok) {
        this.setNotice(data.error || "Your message was not sent. Try again.")
        return
      }
      this.inputTarget.value = ""
      this.input()
      this.sending = false
      const last = this.messages[this.messages.length - 1]
      await this.fetchMessages({ after: last ? last.cursor : null })
      this.scrollToEnd()
    } catch (_error) {
      this.setNotice("Your message was not sent. Check your connection and try again.")
    } finally {
      this.sending = false
      this.input()
      this.inputTarget.focus()
    }
  }

  setNotice(text) {
    if (!this.hasNoticeTarget) return
    this.noticeTarget.textContent = text
    this.noticeTarget.hidden = !text
  }

  get csrf() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }

  // --- time ---

  sameDay(a, b) { return a.toDateString() === b.toDateString() }
  sameAuthor(a, b) { return a.author === b.author && a.agent === b.agent && a.via_rupert === b.via_rupert && a.key === b.key }

  timeLabel(date) {
    return date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
  }

  dayLabel(date) {
    const today = new Date()
    const yesterday = new Date(today.getTime() - 86400000)
    if (this.sameDay(date, today)) return "Today"
    if (this.sameDay(date, yesterday)) return "Yesterday"
    return date.toLocaleDateString([], { weekday: "short", month: "short", day: "numeric", year: date.getFullYear() === today.getFullYear() ? undefined : "numeric" })
  }

  ago(iso) {
    const seconds = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000))
    if (seconds < 10) return "just now"
    if (seconds < 90) return `${seconds}s ago`
    const minutes = Math.round(seconds / 60)
    if (minutes < 90) return `${minutes} min ago`
    return new Date(iso).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })
  }
}
