import { Controller } from "@hotwired/stimulus"

// Team chat (/chat). Loads a room's messages as JSON, keeps them current by
// polling for anything created or changed since the last poll (a reply Rupert
// is still writing, an action someone approved), and posts through the same
// controller.
//
// Every message is text written by people or by the model: it only reaches the
// page through textContent and DOM nodes, never innerHTML. A small, safe subset
// of formatting is built from nodes: paragraphs, "- " and "1. " lists, **bold**,
// `code`, @mentions, http(s) links and same-site [label](/path) links.
export default class extends Controller {
  static targets = ["log", "more", "notice", "form", "input", "send", "jump", "empty", "loading", "filter", "roomLink",
    "thread", "threadLog", "threadInput", "threadSend", "newRoom", "topic", "suggest", "files", "fileInput", "pins", "typing", "newDm", "threadSuggest",
    "media", "mediaSearch", "mediaStatus", "mediaGrid", "mediaMore", "presence", "presenceToggle", "presenceLabel"]
  static values = { url: String, roomUrl: String, room: String, direct: Boolean, postMax: { type: Number, default: 4000 }, title: String,
    compact: Boolean, people: Array, agents: Array, me: String, emoji: Array, fileMax: { type: Number, default: 8388608 }, fileCount: { type: Number, default: 4 } }

  static GROUP_SECONDS = 5 * 60
  static MIN_HEIGHT = 320
  static FAST = 1000
  static SLOW = 3000
  static RUPERT = { id: null, name: "rupert", label: "Rupert — the assistant" }
  static ALL = { id: null, name: "all", label: "all — every bot answers, side by side" }
  static SHRINK_OVER = 1.5 * 1024 * 1024
  static SHRINK_TO = 2048

  connect() {
    this.byId = new Map()
    this.since = null
    this.hasMore = false
    this.hasMoreChanges = false
    this.threadId = null
    this.busy = false
    this.sending = false
    this.suggestIndex = 0
    this.suggestions = []
    this.pendingFiles = []
    this.mentionIds = new Set()
    this.pins = []
    this.lastTypingPing = 0
    this.editingId = null
    this.pinsOpen = false
    this.quoting = { main: null, thread: null }
    this.startFitting()
    this.load()
    this.schedule()
    this.onVisible = () => { if (!document.hidden) this.poll() }
    document.addEventListener("visibilitychange", this.onVisible)
  }

  disconnect() {
    clearTimeout(this.timer)
    document.removeEventListener("visibilitychange", this.onVisible)
    this.stopFitting()
    if (!this.compactValue) document.title = this.titleValue
  }

  // --- layout: the full page fills the window, so the message box stays at the bottom ---

  startFitting() {
    if (this.compactValue) return
    this.onResize = () => {
      cancelAnimationFrame(this.fitFrame)
      this.fitFrame = requestAnimationFrame(() => this.fitToWindow())
    }
    window.addEventListener("resize", this.onResize)
    window.visualViewport?.addEventListener("resize", this.onResize)
    // The header can wrap to two lines or gain a banner; re-fit when anything above the chat changes size.
    if (window.ResizeObserver) {
      this.fitObserver = new ResizeObserver(this.onResize)
      const header = document.querySelector("header.app-header")
      if (header) this.fitObserver.observe(header)
      this.fitObserver.observe(document.body)
    }
    this.fitToWindow()
  }

  // What the page shows under the chat (the help bar in the rail layout), so the chat leaves room for it
  // and the page itself never scrolls.
  heightBelow(main) {
    if (!main) return 0
    let block = this.element
    while (block.parentElement && block.parentElement !== main) block = block.parentElement
    let total = 0
    for (let next = block.nextElementSibling; next; next = next.nextElementSibling) {
      const style = getComputedStyle(next)
      if (style.display === "none" || style.position === "fixed" || style.position === "absolute") continue
      total += next.getBoundingClientRect().height + (parseFloat(style.marginTop) || 0) + (parseFloat(style.marginBottom) || 0)
    }
    return total
  }

  stopFitting() {
    if (!this.onResize) return
    window.removeEventListener("resize", this.onResize)
    window.visualViewport?.removeEventListener("resize", this.onResize)
    this.fitObserver?.disconnect()
    cancelAnimationFrame(this.fitFrame)
  }

  // Height = the visible window below the chat's top edge, minus the page's bottom padding.
  fitToWindow() {
    const viewport = window.visualViewport?.height || window.innerHeight
    const top = this.element.getBoundingClientRect().top + window.scrollY
    const main = this.element.closest("main")
    const gap = main ? parseFloat(getComputedStyle(main).paddingBottom) || 0 : 0
    const height = Math.max(this.constructor.MIN_HEIGHT, Math.floor(viewport - top - gap - this.heightBelow(main)))
    if (this.element.style.height !== `${height}px`) this.element.style.height = `${height}px`
  }

  // --- text formatting (pure; also used by the tests) ---

  static escapeRegExp(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  }

  // names: people who can be mentioned, so "@Alex Rivera" is shown as one mention.
  // handles: the assistants (@rupert and the local model @agents).
  static parseInline(text, names = [], handles = ["rupert"]) {
    const parts = []
    const people = [...names].sort((a, b) => b.length - a.length).map((name) => this.escapeRegExp(name)).join("|")
    const bots = `@(?:${handles.map((handle) => this.escapeRegExp(handle)).join("|")})\\b`
    const mention = people ? `${bots}|@(?:${people})(?![\\w])` : bots
    const pattern = new RegExp("`([^`\\n]+)`|\\*\\*([^*\\n]+)\\*\\*|\\[([^\\]\\n]{1,120})\\]\\((\\/(?!\\/)[^)\\s]*)\\)|(https?:\\/\\/[^\\s<>\"'`]+)|((?<![\\w@])(?:" + mention + "))", "gi")
    let last = 0
    let match
    const push = (type, value, extra = {}) => { if (value) parts.push({ type, text: value, ...extra }) }
    while ((match = pattern.exec(text)) !== null) {
      push("text", text.slice(last, match.index))
      last = match.index + match[0].length
      if (match[1] !== undefined) push("code", match[1])
      else if (match[2] !== undefined) push("bold", match[2])
      else if (match[3] !== undefined) push("link", match[3], { href: match[4] })
      else if (match[5] !== undefined) {
        let url = match[5]
        let trailing = ""
        while (/[.,;:!?)\]}'"]$/.test(url) && !(url.endsWith(")") && url.includes("("))) {
          trailing = url.slice(-1) + trailing
          url = url.slice(0, -1)
        }
        const safe = this.safeUrl(url)
        if (safe) push("link", url, { href: safe, external: true })
        else push("text", url)
        push("text", trailing)
      } else push("mention", match[6])
    }
    push("text", text.slice(last))
    return parts
  }

  // Splits text into blocks: paragraphs and lists.
  static parseBlocks(text) {
    const blocks = []
    String(text || "").split("\n").forEach((raw) => {
      const line = raw.replace(/\s+$/, "")
      const bullet = line.match(/^\s*[-*•]\s+(.*)$/)
      const numbered = line.match(/^\s*\d{1,2}[.)]\s+(.*)$/)
      const kind = bullet ? "ul" : numbered ? "ol" : null
      const last = blocks[blocks.length - 1]
      if (kind) {
        const item = (bullet || numbered)[1]
        if (last && last.type === kind) last.items.push(item)
        else blocks.push({ type: kind, items: [item] })
      } else if (line.trim() === "") {
        if (last && last.type === "p" && !last.closed) last.closed = true
      } else if (last && last.type === "p" && !last.closed) {
        last.lines.push(line)
      } else {
        blocks.push({ type: "p", lines: [line] })
      }
    })
    return blocks
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

  schedule() {
    clearTimeout(this.timer)
    const pending = [...this.byId.values()].some((message) => message.status === "pending")
    this.timer = setTimeout(async () => { await this.poll(); this.schedule() }, pending || this.hasMoreChanges ? this.constructor.FAST : this.constructor.SLOW)
  }

  async load() {
    const data = await this.fetchJson(this.query({}))
    this.loadingTarget.hidden = true
    if (!data) return this.showNotice("Could not load messages. Check your connection; this page will keep trying.")
    this.since = data.now
    this.hasMore = data.has_more
    this.merge(data.messages)
    this.renderRooms(data.rooms)
    this.setPins(data.pins)
    this.presenceMap = data.presence || {}
    this.render({ stick: true })
    const params = new URLSearchParams(window.location.search)
    const thread = Number(params.get("thread"))
    const target = Number(params.get("message"))
    if (thread && !this.compactValue) {
      await this.openThread(thread)
      if (target) this.flash(this.threadLogTarget.querySelector(`[data-id="${target}"]`))
    } else if (target && !this.compactValue) {
      this.jumpToMessage(target)
    }
  }

  async poll() {
    if (document.hidden || this.busy || !this.since) return
    this.busy = true
    const data = await this.fetchJson(this.query({ since: this.since, thread: this.threadId }))
    this.busy = false
    if (!data) return
    this.since = data.now
    this.hasMoreChanges = !!data.has_more_changes
    const fresh = this.merge(data.messages)
    this.renderRooms(data.rooms)
    this.setPins(data.pins)
    this.renderTyping(data.typing)
    if (data.presence) this.presenceMap = data.presence
    if (fresh.changed) this.render({ stick: false, newItems: fresh.added })
    else this.applyPresence()
  }

  async loadEarlier() {
    const first = this.topLevel()[0]
    if (!first) return
    this.moreTarget.disabled = true
    const log = this.logTarget
    const before = log.scrollHeight
    const data = await this.fetchJson(this.query({ before: first.id }))
    this.moreTarget.disabled = false
    if (!data) return
    this.hasMore = data.has_more
    this.merge(data.messages)
    this.render({ stick: false })
    log.scrollTop = log.scrollHeight - before
  }

  query({ since = null, before = null, thread = null }) {
    const params = new URLSearchParams()
    if (since) params.set("since", since)
    if (before) params.set("before", before)
    if (thread) params.set("thread", thread)
    if (!document.hidden) params.set("visible", "1")
    return `${this.urlValue}?${params}`
  }

  async fetchJson(url, options = {}) {
    try {
      const { headers = {}, ...rest } = options
      const response = await fetch(url, { ...rest, headers: { Accept: "application/json", ...this.csrf(), ...headers }, credentials: "same-origin" })
      const data = await response.json().catch(() => ({}))
      if (!response.ok) {
        if (options.method) this.showNotice(data.error || "That did not work. Try again.")
        return null
      }
      return data
    } catch (_error) {
      if (options.method) this.showNotice("Could not reach Rupert. Check your connection and try again.")
      return null
    }
  }

  csrf() {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    return token ? { "X-CSRF-Token": token } : {}
  }

  merge(list) {
    let changed = false
    let added = 0
    ;(list || []).forEach((message) => {
      const old = this.byId.get(message.id)
      if (!old) {
        added += message.parent_id ? 0 : 1
        changed = true
      } else if (old.updated_at !== message.updated_at || old.reply_count !== message.reply_count || old.body !== message.body || old.activity !== message.activity || old.status !== message.status ||
          JSON.stringify(old.actions) !== JSON.stringify(message.actions) ||
          JSON.stringify(old.reactions) !== JSON.stringify(message.reactions) || JSON.stringify(old.rating) !== JSON.stringify(message.rating) || old.pinned !== message.pinned || old.edited !== message.edited) {
        changed = true
      }
      this.byId.set(message.id, { ...old, ...message })
      if (message.parent_id) {
        const parent = this.byId.get(message.parent_id)
        if (parent && message.reply_count > (parent.reply_count || 0)) parent.reply_count = message.reply_count
      }
    })
    return { changed, added }
  }

  topLevel() {
    return [...this.byId.values()].filter((message) => !message.parent_id && !(message.deleted && !message.reply_count)).sort((a, b) => a.id - b.id)
  }

  repliesTo(id) {
    return [...this.byId.values()].filter((message) => message.parent_id === id && !message.deleted).sort((a, b) => a.id - b.id)
  }

  // --- rendering ---

  render({ stick, newItems = 0 }) {
    const log = this.logTarget
    const atBottom = stick || log.scrollHeight - log.scrollTop - log.clientHeight < 90
    const list = log.querySelector("[data-team-chat-list]")
    const messages = this.topLevel()
    list.replaceChildren(...this.renderList(messages, { thread: false }))
    this.emptyTarget.hidden = messages.length > 0
    this.moreTarget.hidden = !this.hasMore
    if (atBottom) {
      log.scrollTop = log.scrollHeight
      this.jumpTarget.hidden = true
    } else if (newItems > 0) {
      this.jumpTarget.hidden = false
    }
    if (this.threadId && this.hasThreadTarget) this.renderThread()
    this.applyPresence()
  }

  renderList(messages, { thread }) {
    const nodes = []
    let previous = null
    const compared = new Set()
    messages.forEach((message) => {
      // @all: the bots' answers to one question render once, as side-by-side columns.
      if (message.compare_of) {
        if (compared.has(message.compare_of)) return
        compared.add(message.compare_of)
        nodes.push(this.compareNode(messages.filter((other) => other.compare_of === message.compare_of)))
        previous = null
        return
      }
      const day = new Date(message.created_at).toDateString()
      if (!thread && (!previous || new Date(previous.created_at).toDateString() !== day)) nodes.push(this.dayDivider(message.created_at))
      const continued = previous && previous.author.name === message.author.name && previous.kind === message.kind &&
        new Date(previous.created_at).toDateString() === day &&
        (new Date(message.created_at) - new Date(previous.created_at)) / 1000 < this.constructor.GROUP_SECONDS &&
        !previous.actions?.length && !(previous.reply_count && !thread)
      nodes.push(this.messageNode(message, { continued, thread }))
      previous = message
    })
    return nodes
  }

  compareNode(answers) {
    const box = document.createElement("section")
    box.className = "chat-compare"
    box.setAttribute("aria-label", "Every bot’s answer, side by side")
    const head = document.createElement("p")
    head.className = "chat-compare-head"
    const done = answers.filter((answer) => answer.status !== "pending").length
    head.textContent = done === answers.length ? `Every bot answered · ${answers.length} answers · rate the best one` : `Asking every bot · ${done} of ${answers.length} answered`
    const grid = document.createElement("div")
    grid.className = "chat-compare-grid"
    answers.forEach((answer) => {
      const column = document.createElement("div")
      column.className = "chat-compare-col"
      column.append(this.messageNode(answer, { continued: false, thread: true }))
      grid.append(column)
    })
    box.append(head, grid)
    return box
  }

  dayDivider(iso) {
    const node = document.createElement("div")
    node.className = "chat-day"
    const date = new Date(iso)
    const today = new Date()
    const yesterday = new Date(Date.now() - 86400000)
    node.textContent = date.toDateString() === today.toDateString() ? "Today" : date.toDateString() === yesterday.toDateString() ? "Yesterday"
      : date.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" })
    return node
  }

  messageNode(message, { continued, thread }) {
    const row = document.createElement("article")
    row.className = `chat-msg is-${message.kind}${continued ? " is-continued" : ""}${message.status === "failed" ? " is-failed" : ""}${message.mentions_me ? " is-mentioned" : ""}`
    row.dataset.id = message.id

    const avatar = document.createElement("span")
    avatar.className = `chat-msg-avatar${message.kind === "person" ? "" : " is-bot"}`
    avatar.setAttribute("aria-hidden", "true")
    if (message.kind === "person") avatar.style.background = message.author.color
    avatar.textContent = message.author.initials
    avatar.title = this.whoTitle(message.author)
    if (message.kind === "person" && message.author.user_id) avatar.dataset.presenceUser = message.author.user_id
    row.append(avatar)

    const main = document.createElement("div")
    main.className = "chat-msg-main"
    if (!continued) {
      const head = document.createElement("p")
      head.className = "chat-msg-head"
      const author = document.createElement("span")
      author.className = "chat-msg-author"
      author.textContent = message.author.name
      author.title = this.whoTitle(message.author)
      head.append(author)
      if (message.kind !== "person") {
        const badge = document.createElement("span")
        badge.className = "chat-msg-badge"
        badge.textContent = message.kind === "system" ? "Notice" : "Assistant"
        head.append(badge)
      }
      if (message.pinned) {
        const pin = document.createElement("span")
        pin.className = "chat-msg-pinned"
        pin.textContent = "📌 Pinned"
        pin.title = message.pinned_by ? `Pinned by ${message.pinned_by}` : "Pinned"
        head.append(pin)
      }
      const time = document.createElement("time")
      time.className = "chat-msg-time"
      time.dateTime = message.created_at
      time.title = new Date(message.created_at).toLocaleString()
      time.textContent = new Date(message.created_at).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })
      head.append(time)
      if (message.answer) head.append(this.answerNode(message.answer))
      if (message.edited) {
        const edited = document.createElement("span")
        edited.className = "chat-msg-edited"
        edited.textContent = "(edited)"
        head.append(edited)
      }
      main.append(head)
    }

    if (message.quote && !message.deleted) main.append(this.quoteNode(message.quote))

    const body = document.createElement("div")
    body.className = "chat-msg-body"
    if (message.deleted) {
      const gone = document.createElement("span")
      gone.className = "chat-msg-deleted"
      gone.textContent = "This message was deleted."
      body.append(gone)
    } else if (this.editingId === message.id) {
      body.append(this.editorNode(message))
    } else {
      if (message.body) body.append(...this.formatted(message.body))
      if (message.status === "pending") body.append(this.activityNode(message))
    }
    main.append(body)
    if (message.can_cancel && message.status === "pending") {
      const stop = document.createElement("button")
      stop.type = "button"
      stop.className = "btn-ghost btn-sm"
      stop.textContent = "Stop"
      stop.addEventListener("click", async () => {
        stop.disabled = true
        const data = await this.fetchJson(`${this.urlValue}/${message.id}/cancel`, { method: "POST" })
        if (data) { this.merge(data.messages); this.render({ stick: false }) }
        else stop.disabled = false
      })
      main.append(stop)
    }

    if (!message.deleted && message.unverified?.length) main.append(this.unverifiedNode(message.unverified))
    if (!message.deleted && message.attachments?.length) main.append(this.attachmentsNode(message.attachments))
    ;(message.actions || []).forEach((action) => main.append(this.actionNode(message, action)))
    if (message.reactions?.length) main.append(this.reactionsNode(message))
    if (message.rating && !message.deleted) main.append(this.ratingNode(message))

    if (!thread && message.reply_count > 0) {
      const replies = document.createElement("button")
      replies.type = "button"
      replies.className = "chat-replies"
      replies.textContent = `${message.reply_count} ${message.reply_count === 1 ? "reply" : "replies"}`
      replies.addEventListener("click", () => this.openThread(message.id))
      main.append(replies)
    }
    row.append(main)

    if (!message.deleted && message.status !== "pending") {
      const tools = document.createElement("div")
      tools.className = "chat-msg-tools"
      if (message.kind !== "system") tools.append(this.toolButton("↩ Reply", (event) => this.startQuote(message, event.currentTarget)))
      if (!thread && !message.parent_id && message.kind !== "system" && !this.compactValue) tools.append(this.toolButton("💬 Thread", () => this.openThread(message.id)))
      tools.append(this.toolButton("React", (event) => this.openPalette(message, event.currentTarget)))
      if (message.kind !== "system") tools.append(this.toolButton(message.pinned ? "Unpin" : "Pin", () => this.togglePin(message.id)))
      tools.append(this.toolButton("Copy link", () => this.copyLink(message)))
      if (message.mine) tools.append(this.toolButton("Edit", () => this.startEdit(message)))
      if (message.mine) tools.append(this.toolButton("Delete", () => this.deleteMessage(message)))
      if (tools.childElementCount) row.append(tools)
    }
    // On touch screens there is no hover: a tap on the message shows its tools.
    row.addEventListener("click", (event) => {
      if (event.target.closest("a, button, input, textarea, video, summary")) return
      this.element.querySelectorAll(".chat-msg.is-selected").forEach((other) => { if (other !== row) other.classList.remove("is-selected") })
      row.classList.toggle("is-selected")
    })
    return row
  }

  // --- Media: the room's photos and files, searchable ---

  showTab(event) {
    const tab = event.currentTarget.dataset.tab
    this.element.querySelectorAll(".chat-tabs .chat-tab").forEach((button) => {
      const on = button.dataset.tab === tab
      button.classList.toggle("is-active", on)
      button.setAttribute("aria-selected", on ? "true" : "false")
    })
    const media = tab === "media"
    this.mediaTarget.hidden = !media
    this.element.querySelector(".chat-body").hidden = media
    if (this.hasPinsTarget) this.pinsTarget.classList.toggle("is-tab-hidden", media)
    if (media) {
      this.mediaFilter ||= "all"
      if (!this.mediaLoaded) this.loadMedia()
      this.mediaSearchTarget.focus()
    }
  }

  searchMedia() {
    clearTimeout(this.mediaTimer)
    this.mediaTimer = setTimeout(() => this.loadMedia(), 250)
  }

  mediaKind(event) {
    this.mediaFilter = event.currentTarget.dataset.kind
    this.element.querySelectorAll(".chat-media-kinds .chat-tab").forEach((button) => {
      const on = button.dataset.kind === this.mediaFilter
      button.classList.toggle("is-active", on)
      button.setAttribute("aria-pressed", on ? "true" : "false")
    })
    this.loadMedia()
  }

  moreMedia() {
    this.loadMedia({ append: true })
  }

  async loadMedia({ append = false } = {}) {
    const url = new URL(this.mediaTarget.dataset.url, window.location.origin)
    const query = this.mediaSearchTarget.value.trim()
    if (query) url.searchParams.set("q", query)
    if (this.mediaFilter && this.mediaFilter !== "all") url.searchParams.set("kind", this.mediaFilter)
    if (append && this.mediaLastId) url.searchParams.set("before", this.mediaLastId)
    const ticket = (this.mediaTicket = (this.mediaTicket || 0) + 1)
    if (!append) this.mediaStatusTarget.textContent = "Loading…"
    this.mediaStatusTarget.hidden = append
    const data = await this.fetchJson(url.pathname + url.search)
    if (!data || ticket !== this.mediaTicket) return
    this.mediaLoaded = true
    const nodes = data.items.map((item) => this.mediaNode(item))
    append ? this.mediaGridTarget.append(...nodes) : this.mediaGridTarget.replaceChildren(...nodes)
    if (data.items.length) this.mediaLastId = data.items[data.items.length - 1].id
    this.mediaMoreTarget.hidden = !data.has_more
    const shown = this.mediaGridTarget.childElementCount
    this.mediaStatusTarget.hidden = shown > 0
    this.mediaStatusTarget.textContent = query ? `Nothing matches “${query}”.` : "No photos or files in this room yet. Paste, drop or 📎 attach one in a message."
  }

  mediaNode(item) {
    const card = document.createElement("figure")
    card.className = `chat-media-item${item.image ? " is-image" : ""}`
    const open = document.createElement("a")
    open.href = item.url
    open.target = "_blank"
    open.rel = "noopener"
    open.className = "chat-media-open"
    if (item.image) {
      const img = document.createElement("img")
      img.src = item.url
      img.alt = item.name
      img.loading = "lazy"
      open.append(img)
    } else {
      const icon = document.createElement("span")
      icon.className = "chat-media-icon"
      icon.textContent = item.type === "application/pdf" ? "PDF" : (item.name.split(".").pop() || "file").toUpperCase().slice(0, 4)
      const name = document.createElement("span")
      name.className = "chat-media-name"
      name.textContent = item.name
      open.append(icon, name)
    }
    const caption = document.createElement("figcaption")
    const who = document.createElement("span")
    who.textContent = item.author
    who.title = this.whoTitle({ name: item.author, email: item.email })
    const when = document.createElement("time")
    when.dateTime = item.created_at
    when.textContent = new Date(item.created_at).toLocaleDateString(undefined, { month: "short", day: "numeric" })
    when.title = new Date(item.created_at).toLocaleString()
    const show = document.createElement("button")
    show.type = "button"
    show.className = "chat-media-show"
    show.textContent = "Show in chat"
    show.title = item.excerpt || item.name
    show.addEventListener("click", () => this.showMediaMessage(item))
    caption.append(who, when, show)
    card.append(open, caption)
    return card
  }

  async showMediaMessage(item) {
    this.element.querySelector('.chat-tabs .chat-tab[data-tab="messages"]').click()
    if (item.parent_id && !this.compactValue) {
      await this.openThread(item.parent_id)
      return this.flash(this.threadLogTarget.querySelector(`[data-id="${item.message_id}"]`))
    }
    this.jumpToMessage(item.message_id)
  }

  // A bot answer quoted figures that are not in the data its tools returned.
  unverifiedNode(figures) {
    const note = document.createElement("p")
    note.className = "chat-unverified"
    note.setAttribute("role", "note")
    note.title = "Rupert compares every $ amount and % in a bot answer with the data its tools returned. These were not found there: the bot may have calculated or made them up."
    const icon = document.createElement("span")
    icon.setAttribute("aria-hidden", "true")
    icon.textContent = "⚠"
    const text = document.createElement("span")
    text.textContent = `Not found in Rupert's data: ${figures.join(", ")}. Check before relying on ${figures.length === 1 ? "it" : "them"}.`
    note.append(icon, text)
    return note
  }

  // "Name · email" on hover, so two people with the same name can be told apart.
  whoTitle(author) {
    return author.email ? `${author.name} · ${author.email}` : author.name
  }

  // --- replies: quote a message in the room (or in the thread) ---

  quoteNode(quote) {
    const node = document.createElement("button")
    node.type = "button"
    node.className = `chat-quote${quote.deleted ? " is-deleted" : ""}`
    node.setAttribute("aria-label", `Replying to ${quote.author}. Show that message.`)
    const who = document.createElement("strong")
    who.textContent = quote.author
    const text = document.createElement("span")
    text.textContent = quote.excerpt
    node.append(who, text)
    node.addEventListener("click", (event) => this.showQuoted(quote, event.currentTarget))
    return node
  }

  async showQuoted(quote, from) {
    const inThread = from.closest(".chat-thread-log")
    if (inThread) return this.flash(inThread.querySelector(`[data-id="${quote.id}"]`))
    if (quote.parent_id && !this.compactValue) {
      await this.openThread(quote.parent_id)
      return this.flash(this.threadLogTarget.querySelector(`[data-id="${quote.id}"]`))
    }
    this.jumpToMessage(quote.parent_id || quote.id)
  }

  startQuote(message, from) {
    const where = from.closest(".chat-thread-log") ? "thread" : "main"
    this.quoting[where] = message
    this.renderQuoteBar(where)
    const field = where === "thread" ? this.threadInputTarget : this.inputTarget
    field.focus()
  }

  clearQuote(where) {
    if (!this.quoting[where]) return false
    this.quoting[where] = null
    this.renderQuoteBar(where)
    return true
  }

  renderQuoteBar(where) {
    const field = where === "thread" ? this.threadInputTarget : this.inputTarget
    const composer = field.closest(".chat-composer")
    let bar = composer.querySelector(".chat-quote-bar")
    const message = this.quoting[where]
    if (!message) return bar?.remove()
    if (!bar) {
      bar = document.createElement("div")
      bar.className = "chat-quote-bar"
      field.before(bar)
    }
    const label = document.createElement("span")
    const who = document.createElement("strong")
    who.textContent = `Replying to ${message.author.name}`
    const text = document.createElement("span")
    text.className = "chat-quote-bar-text"
    const plain = (message.body || "").replace(/\[([^\]]+)\]\([^)\s]+\)/g, "$1").replace(/\*\*|`/g, "").replace(/\s+/g, " ").trim() || (message.attachments?.length ? `📎 ${message.attachments[0].name}` : "")
    text.textContent = plain.length > 90 ? `${plain.slice(0, 89)}…` : plain
    label.append(who, text)
    const hint = document.createElement("span")
    hint.className = "chat-quote-bar-hint"
    hint.textContent = message.kind === "assistant" ? "it answers your reply" : ""
    const cancel = document.createElement("button")
    cancel.type = "button"
    cancel.setAttribute("aria-label", "Cancel reply")
    cancel.textContent = "✕"
    cancel.addEventListener("click", () => { this.clearQuote(where); field.focus() })
    bar.replaceChildren(label, hint, cancel)
  }

  // "31s · qwen3.5-4b · local" next to a bot reply; "31s (17s load)" when the model had to be loaded first.
  answerNode(answer) {
    const node = document.createElement("span")
    node.className = `chat-msg-answer is-${answer.where}`
    const short = (value) => value < 10 ? value.toFixed(1) : Math.round(value)
    const time = answer.load_seconds ? `${short(answer.seconds)}s (${short(answer.load_seconds)}s load)` : `${short(answer.seconds)}s`
    node.textContent = [time, answer.model, answer.where].filter(Boolean).join(" · ")
    node.title = `Answered in ${answer.seconds} seconds${answer.model ? ` by ${answer.model}` : ""} (${answer.where === "local" ? "on this server" : "cloud"})` +
      (answer.load_seconds ? `, including ${answer.load_seconds} seconds loading the model` : "")
    return node
  }

  toolButton(label, handler) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "chat-msg-tool"
    button.textContent = label
    button.addEventListener("click", handler)
    return button
  }

  attachmentsNode(list) {
    const holder = document.createElement("div")
    holder.className = "chat-attachments"
    list.forEach((file) => {
      const link = document.createElement("a")
      link.href = file.url
      link.target = "_blank"
      link.rel = "noopener"
      if (file.image) {
        link.className = "chat-attachment-image"
        const img = document.createElement("img")
        img.src = file.url
        img.alt = file.name
        img.loading = "lazy"
        link.append(img)
      } else {
        link.className = "chat-attachment-file"
        const icon = document.createElement("span")
        icon.setAttribute("aria-hidden", "true")
        icon.textContent = file.type === "application/pdf" ? "📄" : "📎"
        const name = document.createElement("span")
        name.textContent = file.name
        const size = document.createElement("small")
        size.textContent = this.constructor.fileSize(file.size)
        link.append(icon, name, size)
      }
      if (file.drive_url) {
        const wrap = document.createElement("span")
        wrap.className = "chat-attachment"
        const drive = document.createElement("a")
        drive.className = "chat-attachment-drive"
        drive.href = file.drive_url
        drive.target = "_blank"
        drive.rel = "noopener noreferrer"
        drive.textContent = "Open in Google Drive"
        wrap.append(link, drive)
        holder.append(wrap)
      } else {
        holder.append(link)
      }
    })
    return holder
  }

  static fileSize(bytes) {
    if (bytes >= 1048576) return `${(bytes / 1048576).toFixed(1)} MB`
    return `${Math.max(1, Math.round(bytes / 1024))} KB`
  }

  reactionsNode(message) {
    const row = document.createElement("div")
    row.className = "chat-reactions"
    message.reactions.forEach((reaction) => {
      const pill = document.createElement("button")
      pill.type = "button"
      pill.className = `chat-reaction${reaction.mine ? " is-mine" : ""}`
      pill.title = reaction.names.join(", ")
      pill.setAttribute("aria-pressed", reaction.mine ? "true" : "false")
      pill.textContent = `${reaction.emoji} ${reaction.count}`
      pill.addEventListener("click", () => this.react(message, reaction.emoji))
      row.append(pill)
    })
    return row
  }

  // --- typing, editing and links ---

  // Tells the room you are typing, at most every three seconds.
  pingTyping() {
    const now = Date.now()
    if (now - this.lastTypingPing < 3000) return
    this.lastTypingPing = now
    fetch(`${this.roomUrlValue}/typing`, { method: "POST", headers: this.csrf(), credentials: "same-origin" }).catch(() => {})
  }

  renderTyping(names) {
    if (!this.hasTypingTarget || !Array.isArray(names)) return
    const text = names.length === 0 ? "" : names.length === 1 ? `${names[0]} is typing…` : names.length === 2 ? `${names[0]} and ${names[1]} are typing…` : "Several people are typing…"
    this.typingTarget.hidden = text === ""
    this.typingTarget.textContent = text
  }

  startEdit(message) {
    this.editingId = message.id
    this.render({ stick: false })
    const field = this.element.querySelector(`[data-id="${message.id}"] .chat-edit-input`)
    if (field) {
      field.focus()
      field.setSelectionRange(field.value.length, field.value.length)
    }
  }

  editorNode(message) {
    const form = document.createElement("form")
    form.className = "chat-edit"
    form.dataset.busy = "false"
    const field = document.createElement("textarea")
    field.className = "chat-input chat-edit-input"
    field.value = message.body || ""
    field.rows = Math.min(8, Math.max(1, field.value.split("\n").length))
    field.setAttribute("aria-label", "Edit message")
    const bar = document.createElement("div")
    bar.className = "chat-edit-bar"
    const hint = document.createElement("span")
    hint.textContent = "Enter saves · Esc cancels"
    const cancel = document.createElement("button")
    cancel.type = "button"
    cancel.className = "btn-ghost btn-sm"
    cancel.textContent = "Cancel"
    const save = document.createElement("button")
    save.type = "submit"
    save.className = "btn-primary btn-sm"
    save.textContent = "Save"
    bar.append(hint, cancel, save)
    form.append(field, bar)
    const stop = () => { this.editingId = null; this.render({ stick: false }) }
    cancel.addEventListener("click", stop)
    field.addEventListener("keydown", (event) => {
      if (event.key === "Escape") { event.preventDefault(); stop() }
      if (event.key === "Enter" && !event.shiftKey && !event.isComposing) { event.preventDefault(); form.requestSubmit() }
    })
    form.addEventListener("submit", async (event) => {
      event.preventDefault()
      const text = field.value.trim()
      if (text === (message.body || "").trim()) return stop()
      save.disabled = true
      const data = await this.fetchJson(`${this.urlValue}/${message.id}`, {
        method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ body: text })
      })
      if (!data) { save.disabled = false; return }
      this.editingId = null
      this.merge(data.messages)
      this.render({ stick: false })
    })
    return form
  }

  // A link straight to this message (its thread for a reply), to paste anywhere.
  async copyLink(message) {
    const url = new URL(this.roomUrlValue, window.location.origin)
    if (message.parent_id) url.searchParams.set("thread", message.parent_id)
    url.searchParams.set("message", message.id)
    try {
      await navigator.clipboard.writeText(url.href)
      this.toast("Link copied.")
      this.showNotice(null)
    } catch (_error) {
      window.prompt("Copy this link", url.href)
    }
  }

  async jumpToMessage(id) {
    for (let tries = 0; tries < 10; tries += 1) {
      const node = this.logTarget.querySelector(`[data-id="${id}"]`)
      if (node) return this.flash(node)
      if (!this.hasMore) break
      await this.loadEarlier()
    }
    this.showNotice("That message is no longer in this room.")
  }

  flash(node) {
    if (!node) return
    node.scrollIntoView({ block: "center", behavior: "smooth" })
    node.classList.remove("is-flash")
    void node.offsetWidth
    node.classList.add("is-flash")
  }

  // --- "recently active" dots ---

  // Updates every avatar that names a person: data-presence drives the dot, the title says when.
  applyPresence() {
    if (!this.presenceMap) return
    this.element.querySelectorAll("[data-presence-user]").forEach((node) => {
      const status = this.presenceMap[node.dataset.presenceUser]
      if (node.dataset.baseTitle === undefined) node.dataset.baseTitle = node.getAttribute("title") || ""
      if (status) {
        node.dataset.presence = status.state
        node.dataset.presenceLabel = status.label
      } else {
        delete node.dataset.presence
        delete node.dataset.presenceLabel
      }
      const base = node.dataset.baseTitle
      const title = [base, status?.label].filter(Boolean).join(" · ")
      if (title) node.setAttribute("title", title)
      else node.removeAttribute("title")
    })
  }

  openPresence() {
    if (this.hasPresenceTarget) this.presenceTarget.showModal()
  }

  closePresence() {
    this.presenceTarget.close()
  }

  async togglePresence(event) {
    const shown = event.currentTarget.checked
    const form = new FormData()
    form.append("hidden", shown ? "0" : "1")
    const data = await this.fetchJson(this.presenceTarget.dataset.url, { method: "PATCH", body: form })
    if (!data) {
      event.currentTarget.checked = !shown
      return
    }
    this.afterPresence(data)
    this.toast(data.shown ? "Others can see when you are active." : "Your activity is hidden.")
  }

  async savePresencePolicy(event) {
    event.preventDefault()
    const data = await this.fetchJson(this.presenceTarget.dataset.policyUrl, { method: "PATCH", body: new FormData(event.currentTarget) })
    if (!data) return
    this.afterPresence(data)
    this.toast("Workspace rule saved.")
  }

  afterPresence(data) {
    this.presenceMap = data.presence || {}
    this.applyPresence()
    if (this.hasPresenceToggleTarget) {
      this.presenceToggleTarget.checked = data.shown
      this.presenceToggleTarget.disabled = data.mode !== "choice"
    }
    if (this.hasPresenceLabelTarget) this.presenceLabelTarget.textContent = `${data.shown ? "Shown as active" : "Activity hidden"} · change`
  }

  openNewDm() {
    this.newDmTarget.showModal()
  }

  closeNewDm() {
    this.newDmTarget.close()
  }

  // --- pins: the newest is a banner above the messages, the rest a click away ---

  setPins(pins) {
    if (!Array.isArray(pins) || !this.hasPinsTarget) return
    if (JSON.stringify(pins) === JSON.stringify(this.pins)) return
    this.pins = pins
    this.renderPins()
  }

  renderPins() {
    const holder = this.pinsTarget
    holder.hidden = this.pins.length === 0
    if (!this.pins.length) {
      holder.replaceChildren()
      return
    }
    const latest = this.pins[0]
    const bar = document.createElement("div")
    bar.className = "chat-pins-bar"
    bar.append(this.pinButton(latest, true))
    if (this.pins.length > 1) {
      const more = document.createElement("button")
      more.type = "button"
      more.className = "chat-pins-more"
      more.setAttribute("aria-expanded", this.pinsOpen ? "true" : "false")
      more.textContent = this.pinsOpen ? "Hide" : `+${this.pins.length - 1} more`
      more.addEventListener("click", () => { this.pinsOpen = !this.pinsOpen; this.renderPins() })
      bar.append(more)
    }
    bar.append(this.unpinButton(latest))
    const nodes = [bar]
    if (this.pinsOpen && this.pins.length > 1) {
      const list = document.createElement("ul")
      list.className = "chat-pins-list"
      this.pins.slice(1).forEach((pin) => {
        const item = document.createElement("li")
        item.append(this.pinButton(pin, false), this.unpinButton(pin))
        list.append(item)
      })
      nodes.push(list)
    }
    holder.replaceChildren(...nodes)
  }

  pinButton(pin, banner) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = banner ? "chat-pin chat-pin-banner" : "chat-pin"
    button.title = `Pinned by ${pin.pinned_by || "someone"} · show the message`
    const icon = document.createElement("span")
    icon.setAttribute("aria-hidden", "true")
    icon.textContent = "📌"
    const who = document.createElement("strong")
    who.textContent = `${pin.author}:`
    const text = document.createElement("span")
    text.className = "chat-pin-text"
    text.textContent = pin.excerpt
    button.append(icon, who, text)
    button.addEventListener("click", () => this.jumpToPin(pin))
    return button
  }

  unpinButton(pin) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "chat-pin-unpin"
    button.setAttribute("aria-label", `Unpin message from ${pin.author}`)
    button.title = "Unpin"
    button.textContent = "✕"
    button.addEventListener("click", () => this.togglePin(pin.id))
    return button
  }

  async togglePin(id) {
    const data = await this.fetchJson(`${this.urlValue}/${id}/pin`, { method: "POST" })
    if (!data) return
    this.merge(data.messages)
    this.setPins(data.pins)
    this.render({ stick: false })
  }

  // Shows the pinned message: its thread when it is a reply, else the message in the log.
  async jumpToPin(pin) {
    if (pin.parent_id) {
      await this.openThread(pin.parent_id)
      if (this.hasThreadLogTarget) this.flash(this.threadLogTarget.querySelector(`[data-id="${pin.id}"]`))
      return
    }
    return this.jumpToMessage(pin.id)
  }

  // 👍 / 👎 on an assistant reply, so Model scores can show which models people like.
  ratingNode(message) {
    const row = document.createElement("div")
    row.className = "chat-rating"
    row.setAttribute("role", "group")
    row.setAttribute("aria-label", "Rate this reply")
    ;[["up", "👍", "Helpful"], ["down", "👎", "Not helpful"]].forEach(([value, emoji, label]) => {
      const button = document.createElement("button")
      button.type = "button"
      button.className = `chat-rating-button${message.rating.mine === value ? " is-mine" : ""}`
      button.setAttribute("aria-pressed", message.rating.mine === value ? "true" : "false")
      button.title = `${label} (counts toward Model scores)`
      const count = message.rating[value]
      button.textContent = count > 0 ? `${emoji} ${count}` : emoji
      button.setAttribute("aria-label", `${label}${count ? `, ${count}` : ""}`)
      button.addEventListener("click", () => this.rate(message, value))
      row.append(button)
    })
    if (message.rating.mine) row.append(this.reasonNode(message))
    return row
  }

  // After a thumb: an optional one-line "why", saved with the rating. Never blocks anything.
  reasonNode(message) {
    const saved = message.rating.my_reason
    if (saved && this.reasonOpenFor !== message.id) {
      const note = document.createElement("button")
      note.type = "button"
      note.className = "chat-rating-note"
      note.title = "Edit why"
      note.textContent = `“${saved}”`
      note.addEventListener("click", () => { this.reasonOpenFor = message.id; this.render({ stick: false }); this.focusReason(message.id) })
      return note
    }
    if (this.reasonOpenFor !== message.id) return document.createTextNode("")
    const form = document.createElement("form")
    form.className = "chat-rating-reason"
    form.dataset.busy = "false"
    const field = document.createElement("input")
    field.type = "text"
    field.maxLength = 500
    field.value = saved || ""
    field.placeholder = message.rating.mine === "up" ? "What made it good? (optional)" : "What was wrong? (optional)"
    field.setAttribute("aria-label", "Why (optional)")
    const close = () => { this.reasonOpenFor = null; this.render({ stick: false }) }
    field.addEventListener("keydown", (event) => { if (event.key === "Escape") { event.preventDefault(); close() } })
    form.addEventListener("submit", async (event) => {
      event.preventDefault()
      const data = await this.fetchJson(`${this.urlValue}/${message.id}/rating/reason`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ reason: field.value })
      })
      if (!data) return
      this.reasonOpenFor = null
      this.merge(data.messages)
      this.render({ stick: false })
    })
    form.append(field)
    return form
  }

  focusReason(id) {
    requestAnimationFrame(() => this.element.querySelector(`[data-id="${id}"] .chat-rating-reason input`)?.focus())
  }

  async rate(message, value) {
    const data = await this.fetchJson(`${this.urlValue}/${message.id}/rating`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ value })
    })
    if (data) {
      const after = data.messages.find((row) => row.id === message.id)
      this.reasonOpenFor = after?.rating?.mine && !after.rating.my_reason ? message.id : null
      this.merge(data.messages)
      this.render({ stick: false })
      if (this.reasonOpenFor) this.focusReason(message.id)
    }
  }

  openPalette(message, anchor) {
    document.querySelector(".chat-palette")?.remove()
    const palette = document.createElement("div")
    palette.className = "chat-palette"
    palette.setAttribute("role", "menu")
    this.emojiValue.forEach((emoji) => {
      const button = document.createElement("button")
      button.type = "button"
      button.setAttribute("role", "menuitem")
      button.textContent = emoji
      button.addEventListener("click", () => { palette.remove(); this.react(message, emoji) })
      palette.append(button)
    })
    anchor.closest(".chat-msg").append(palette)
    palette.querySelector("button")?.focus()
    const close = (event) => {
      if (palette.contains(event.target)) return
      palette.remove()
      document.removeEventListener("pointerdown", close)
    }
    setTimeout(() => document.addEventListener("pointerdown", close), 0)
    palette.addEventListener("keydown", (event) => { if (event.key === "Escape") palette.remove() })
  }

  async react(message, emoji) {
    const data = await this.fetchJson(`${this.urlValue}/${message.id}/reactions`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ emoji })
    })
    if (data) {
      this.merge(data.messages)
      this.render({ stick: false })
    }
  }

  activityNode(message) {
    const node = document.createElement("span")
    node.className = "chat-activity"
    node.setAttribute("role", "status")
    const dots = document.createElement("span")
    dots.className = "chat-dots"
    dots.setAttribute("aria-hidden", "true")
    dots.append(document.createElement("i"), document.createElement("i"), document.createElement("i"))
    const label = document.createElement("span")
    label.textContent = message.body ? "" : `${message.activity || "Thinking"}…`
    node.append(dots, label)
    return node
  }

  actionNode(message, action) {
    const card = document.createElement("div")
    card.className = `chat-action is-${action.status}`
    const text = document.createElement("div")
    text.className = "chat-action-text"
    const small = document.createElement("small")
    small.textContent = action.status === "proposed" ? "Needs approval" : action.title || "Change"
    text.append(small, document.createTextNode(action.summary || ""))
    card.append(text)
    if (action.status === "proposed") {
      const buttons = document.createElement("div")
      buttons.className = "chat-action-buttons"
      const approve = document.createElement("button")
      approve.type = "button"
      approve.className = "btn-primary btn-sm"
      approve.textContent = "Approve"
      approve.addEventListener("click", () => this.decide(message, action, "approve", buttons))
      const dismiss = document.createElement("button")
      dismiss.type = "button"
      dismiss.className = "btn-ghost btn-sm"
      dismiss.textContent = "Dismiss"
      dismiss.addEventListener("click", () => this.decide(message, action, "dismiss", buttons))
      buttons.append(approve, dismiss)
      card.append(buttons)
    } else {
      const state = document.createElement("span")
      state.className = "chat-action-state"
      const who = action.decided_by ? ` by ${action.decided_by}` : ""
      state.textContent = { done: `Done${who}`, failed: `Failed${who}`, dismissed: `Dismissed${who}` }[action.status] || action.status
      card.append(state)
    }
    return card
  }

  formatted(text) {
    return this.constructor.parseBlocks(text).map((block) => {
      if (block.type === "p") {
        const p = document.createElement("p")
        block.lines.forEach((line, index) => {
          if (index) p.append(document.createElement("br"))
          p.append(...this.inlineNodes(line))
        })
        return p
      }
      const list = document.createElement(block.type)
      block.items.forEach((item) => {
        const li = document.createElement("li")
        li.append(...this.inlineNodes(item))
        list.append(li)
      })
      return list
    })
  }

  inlineNodes(line) {
    const names = this.peopleValue.map((person) => person.name).concat(this.meValue ? [this.meValue] : [])
    const handles = ["rupert", "all", ...this.agentsValue.map((agent) => agent.name)]
    return this.constructor.parseInline(line, names, handles).map((part) => {
      if (part.type === "text") return document.createTextNode(part.text)
      const node = document.createElement(part.type === "bold" ? "strong" : part.type === "code" ? "code" : part.type === "link" ? "a" : "span")
      node.textContent = part.text
      if (part.type === "mention") node.className = "chat-mention"
      if (part.type === "link") {
        node.href = part.href
        if (part.external && new URL(part.href).origin !== window.location.origin) {
          node.target = "_blank"
          node.rel = "noopener noreferrer nofollow"
        }
      }
      return node
    })
  }

  renderRooms(rooms) {
    let total = 0
    ;(rooms || []).forEach((room) => {
      const link = this.roomLinkTargets.find((candidate) => candidate.dataset.slug === room.slug)
      if (!link) return
      const badge = link.querySelector("[data-unread]")
      const here = room.slug === this.roomValue
      const unread = here ? 0 : room.unread
      const mentions = here ? 0 : room.mentions || 0
      total += unread
      badge.hidden = unread === 0 && mentions === 0
      badge.textContent = mentions > 0 ? `@${mentions}` : unread > 99 ? "99+" : String(unread)
      badge.classList.toggle("is-mention", mentions > 0)
      link.classList.toggle("has-unread", unread > 0 || mentions > 0)
    })
    if (!this.compactValue) document.title = total > 0 ? `(${total}) ${this.titleValue}` : this.titleValue
  }

  // --- threads ---

  async openThread(id) {
    // The dock has no room for a thread pane: open the thread in the full page.
    if (this.compactValue || !this.hasThreadTarget) {
      const url = `${this.roomUrlValue}?thread=${id}`
      window.Turbo ? window.Turbo.visit(url) : (window.location.href = url)
      return
    }
    if (this.threadId !== id) this.clearQuote("thread")
    this.threadId = id
    this.threadTarget.hidden = false
    this.renderThread()
    const data = await this.fetchJson(this.query({ since: this.since, thread: id }))
    if (data) {
      this.merge(data.messages)
      this.renderThread()
    }
    this.threadInputTarget.focus()
  }

  closeThread() {
    this.threadId = null
    this.clearQuote("thread")
    this.threadTarget.hidden = true
  }

  renderThread() {
    const root = this.byId.get(this.threadId)
    if (!root) return
    const log = this.threadLogTarget
    const atBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 90
    const rootNode = this.messageNode(root, { continued: false, thread: true })
    rootNode.classList.add("chat-thread-root")
    log.replaceChildren(rootNode, ...this.renderList(this.repliesTo(root.id), { thread: true }))
    if (atBottom) log.scrollTop = log.scrollHeight
  }

  // --- composing ---

  input() {
    this.historyAt = null
    this.autosize(this.inputTarget)
    this.sendTarget.disabled = this.inputTarget.value.trim() === "" && this.pendingFiles.length === 0
    this.updateSuggest(this.inputTarget, this.suggestTarget)
    this.pingTyping()
  }

  threadInputChanged() {
    this.historyAt = null
    this.pingTyping()
    this.autosize(this.threadInputTarget)
    this.threadSendTarget.disabled = this.threadInputTarget.value.trim() === ""
    if (this.hasThreadSuggestTarget) this.updateSuggest(this.threadInputTarget, this.threadSuggestTarget)
  }

  autosize(field) {
    field.style.height = "auto"
    field.style.height = `${Math.min(field.scrollHeight, 192)}px`
  }

  keydown(event) {
    if (this.handleSuggestKeys(event)) return
    if (this.historyKey(event, this.inputTarget)) return
    if (event.key === "Escape" && this.clearQuote("main")) return
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault()
      this.formTarget.requestSubmit()
    }
  }

  // ↑ / ↓ in the message box step through what you sent before, like a terminal.
  // ↑ only from the first line and ↓ only from the last, so moving inside a
  // multi-line message still works. ↓ past the newest brings back what you were typing.
  historyKey(event, field) {
    if (!["ArrowUp", "ArrowDown"].includes(event.key) || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey || event.isComposing) return false
    const up = event.key === "ArrowUp"
    if (up && field.value.slice(0, field.selectionStart).includes("\n")) return false
    if (!up && field.value.slice(field.selectionEnd).includes("\n")) return false
    if (this.historyField !== field) {
      this.historyField = field
      this.historyAt = null
    }
    const sent = this.sentHistory()
    if (up) {
      if (this.historyAt === null || this.historyAt === undefined) {
        if (!sent.length) return false
        this.historyDraft = field.value
        this.historyAt = 0
      } else if (this.historyAt < sent.length - 1) {
        this.historyAt += 1
      } else {
        event.preventDefault()
        return true
      }
    } else {
      if (this.historyAt === null || this.historyAt === undefined) return false
      this.historyAt -= 1
    }
    event.preventDefault()
    const at = this.historyAt
    field.value = at < 0 ? (this.historyDraft || "") : sent[at]
    if (at < 0) this.historyAt = null
    field.selectionStart = field.selectionEnd = field.value.length
    this.autosize(field)
    if (field === this.inputTarget) this.sendTarget.disabled = field.value.trim() === "" && this.pendingFiles.length === 0
    else this.threadSendTarget.disabled = field.value.trim() === ""
    return true
  }

  // Your own messages in this room, newest first, each text once.
  sentHistory() {
    const mine = [...this.byId.values()].filter((message) => message.mine && !message.deleted && message.body).sort((a, b) => b.id - a.id)
    return [...new Set(mine.map((message) => message.body))]
  }

  // Arrow keys, Tab/Enter and Escape drive the @ list while it is open. Returns true when handled.
  handleSuggestKeys(event) {
    const list = this.suggestList
    if (!list || list.hidden || !this.suggestions.length || event.target !== this.suggestField) return false
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      const step = event.key === "ArrowDown" ? 1 : -1
      this.suggestIndex = (this.suggestIndex + step + this.suggestions.length) % this.suggestions.length
      this.renderSuggest()
      return true
    }
    if (event.key === "Tab" || event.key === "Enter") {
      event.preventDefault()
      this.completeMention(this.suggestions[this.suggestIndex])
      return true
    }
    if (event.key === "Escape") {
      list.hidden = true
      return true
    }
    return false
  }

  threadKeydown(event) {
    if (this.handleSuggestKeys(event)) return
    if (this.historyKey(event, this.threadInputTarget)) return
    if (event.key === "Escape" && this.clearQuote("thread")) return
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault()
      event.target.form.requestSubmit()
    }
  }

  // "@" plus the start of a name suggests Rupert, the model @agents and the people who use team chat.
  updateSuggest(field, list) {
    this.suggestField = field
    this.suggestList = list
    const before = field.value.slice(0, field.selectionStart)
    const match = before.match(/(?:^|\s)@([\p{L}\p{N}'-]{0,30})$/u)
    if (!match) {
      list.hidden = true
      this.suggestions = []
      return
    }
    const term = match[1].toLowerCase()
    const starts = (name) => name.toLowerCase().split(/\s+/).some((word) => word.startsWith(term)) || name.toLowerCase().startsWith(term)
    const options = [this.constructor.RUPERT, this.constructor.ALL, ...this.agentsValue, ...this.peopleValue.map((person) => ({ ...person, label: person.email ? `${person.name} — ${person.email}` : person.name }))].filter((option) => starts(option.name)).slice(0, 8)
    if (!options.length || (options.length === 1 && options[0].name.toLowerCase() === term)) {
      list.hidden = true
      this.suggestions = []
      return
    }
    this.suggestions = options
    this.suggestIndex = 0
    this.renderSuggest()
  }

  renderSuggest() {
    const items = this.suggestions.map((option, index) => {
      const li = document.createElement("li")
      li.setAttribute("role", "option")
      li.setAttribute("aria-selected", index === this.suggestIndex ? "true" : "false")
      li.textContent = option.label
      li.addEventListener("mousedown", (event) => { event.preventDefault(); this.completeMention(option) })
      return li
    })
    this.suggestList.replaceChildren(...items)
    this.suggestList.hidden = false
  }

  completeMention(option) {
    if (!option || !this.suggestField) return
    const field = this.suggestField
    const cursor = field.selectionStart
    const before = field.value.slice(0, cursor).replace(/@[\p{L}\p{N}'-]*$/u, `@${option.name} `)
    field.value = before + field.value.slice(cursor)
    field.selectionStart = field.selectionEnd = before.length
    if (option.id) this.mentionIds.add(option.id)
    this.suggestList.hidden = true
    this.suggestions = []
    field === this.inputTarget ? this.input() : this.threadInputChanged()
  }

  // --- files ---

  pickFiles(event) {
    this.addFiles([...event.target.files])
    event.target.value = ""
  }

  paste(event) {
    const files = [...(event.clipboardData?.files || [])]
    if (!files.length) return
    event.preventDefault()
    this.addFiles(files)
  }

  dragOver(event) {
    if (![...(event.dataTransfer?.types || [])].includes("Files")) return
    event.preventDefault()
    this.formTarget.classList.add("is-dropping")
  }

  dragLeave() {
    this.formTarget.classList.remove("is-dropping")
  }

  drop(event) {
    if (!event.dataTransfer?.files?.length) return
    event.preventDefault()
    this.formTarget.classList.remove("is-dropping")
    this.addFiles([...event.dataTransfer.files])
  }

  async addFiles(files) {
    this.showNotice(null)
    for (const original of files) {
      if (this.pendingFiles.length >= this.fileCountValue) {
        this.showNotice(`Attach at most ${this.fileCountValue} files to one message.`)
        break
      }
      const file = await this.shrink(original)
      if (file.size > this.fileMaxValue) {
        this.showNotice(`${file.name} is larger than ${Math.round(this.fileMaxValue / 1048576)} MB.`)
        continue
      }
      // A data: URL, because the page's security policy allows data: images but not blob: ones.
      const preview = file.type.startsWith("image/") ? await new Promise((resolve) => {
        const reader = new FileReader()
        reader.onload = () => resolve(reader.result)
        reader.onerror = () => resolve(null)
        reader.readAsDataURL(file)
      }) : null
      this.pendingFiles.push({ file, preview })
    }
    this.renderFiles()
    this.input()
    this.inputTarget.focus()
  }

  // Large photos are scaled down in the browser before upload (GIFs keep their animation).
  async shrink(file) {
    if (!/^image\/(jpeg|png|webp)$/.test(file.type) || file.size <= this.constructor.SHRINK_OVER || !window.createImageBitmap) return file
    try {
      const bitmap = await createImageBitmap(file)
      const scale = Math.min(1, this.constructor.SHRINK_TO / Math.max(bitmap.width, bitmap.height))
      const canvas = document.createElement("canvas")
      canvas.width = Math.round(bitmap.width * scale)
      canvas.height = Math.round(bitmap.height * scale)
      canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height)
      const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.85))
      if (!blob || blob.size >= file.size) return file
      return new File([blob], file.name.replace(/\.(png|webp|jpe?g)$/i, "") + ".jpg", { type: "image/jpeg" })
    } catch (_error) {
      return file
    }
  }

  renderFiles() {
    const holder = this.filesTarget
    holder.hidden = this.pendingFiles.length === 0
    holder.replaceChildren(...this.pendingFiles.map((entry, index) => {
      const chip = document.createElement("div")
      chip.className = "chat-file-chip"
      if (entry.preview) {
        const img = document.createElement("img")
        img.src = entry.preview
        img.alt = ""
        chip.append(img)
      }
      const name = document.createElement("span")
      name.textContent = entry.file.name
      const remove = document.createElement("button")
      remove.type = "button"
      remove.setAttribute("aria-label", `Remove ${entry.file.name}`)
      remove.textContent = "✕"
      remove.addEventListener("click", () => {
        this.pendingFiles.splice(index, 1)
        this.renderFiles()
        this.input()
      })
      chip.append(name, remove)
      return chip
    }))
  }

  useStarter(event) {
    if (this.formTarget.dataset.busy === "true") return
    this.inputTarget.value = (event.currentTarget.dataset.text || event.currentTarget.textContent).trim()
    this.input()
    this.formTarget.requestSubmit()
  }

  async send(event) {
    event.preventDefault()
    await this.post(this.inputTarget, this.sendTarget, null)
  }

  async sendThread(event) {
    event.preventDefault()
    if (!this.threadId) return
    await this.post(this.threadInputTarget, this.threadSendTarget, this.threadId)
  }

  async post(field, button, parentId) {
    const body = field.value.trim()
    const files = parentId ? [] : this.pendingFiles
    if ((!body && !files.length) || this.sending) return
    if (body.length > this.postMaxValue) return this.showNotice(`Keep it under ${this.postMaxValue} characters.`)
    this.sending = true
    button.disabled = true
    this.showNotice(null)
    const form = new FormData()
    form.append("body", body)
    if (parentId) form.append("parent_id", parentId)
    const where = field === this.inputTarget ? "main" : "thread"
    if (this.quoting[where]) form.append("quote_id", this.quoting[where].id)
    files.forEach((entry) => form.append("files[]", entry.file, entry.file.name))
    this.mentionIds.forEach((id) => form.append("mention_ids[]", id))
    const data = await this.fetchJson(this.urlValue, { method: "POST", body: form })
    this.sending = false
    if (!data) {
      button.disabled = false
      return
    }
    field.value = ""
    this.autosize(field)
    this.clearQuote(where)
    if (!parentId) {
      this.pendingFiles = []
      this.mentionIds = new Set()
      this.renderFiles()
    }
    this.merge(data.messages)
    if (parentId) {
      const parent = this.byId.get(parentId)
      if (parent) parent.reply_count = this.repliesTo(parentId).length
    }
    this.render({ stick: !parentId })
    this.schedule()
  }

  async deleteMessage(message) {
    if (!window.confirm("Delete this message?")) return
    const data = await this.fetchJson(`${this.urlValue}/${message.id}`, { method: "DELETE" })
    if (data) {
      this.merge(data.messages)
      this.render({ stick: false })
    }
  }

  async decide(message, action, decision, buttons) {
    buttons.querySelectorAll("button").forEach((button) => { button.disabled = true })
    const data = await this.fetchJson(`${this.urlValue}/${message.id}/actions/${action.id}`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ decision })
    })
    if (!data) {
      buttons.querySelectorAll("button").forEach((button) => { button.disabled = false })
      return
    }
    this.merge(data.messages)
    this.render({ stick: false })
    this.poll()
  }

  // --- room ---

  async saveMode(event) {
    const data = await this.fetchJson(this.roomUrlValue, {
      method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ assistant_mode: event.target.value })
    })
    if (data) this.toast("Saved. Rupert will follow the new setting from the next message.")
  }

  async editTopic() {
    const current = this.topicTarget.textContent.trim()
    const topic = window.prompt("Room topic", current === "No topic yet." ? "" : current)
    if (topic === null) return
    const data = await this.fetchJson(this.roomUrlValue, {
      method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ topic: topic.trim() })
    })
    if (data) this.topicTarget.textContent = data.topic || "No topic yet."
  }

  openNewRoom() {
    this.newRoomTarget.showModal()
  }

  closeNewRoom() {
    this.newRoomTarget.close()
  }

  filterRooms() {
    const term = this.filterTarget.value.trim().toLowerCase()
    this.roomLinkTargets.forEach((link) => { link.hidden = term !== "" && !link.dataset.name.toLowerCase().includes(term) })
  }

  // --- scrolling and notices ---

  onScroll() {
    const log = this.logTarget
    if (log.scrollHeight - log.scrollTop - log.clientHeight < 90) this.jumpTarget.hidden = true
  }

  scrollToEnd() {
    this.logTarget.scrollTop = this.logTarget.scrollHeight
    this.jumpTarget.hidden = true
  }

  showNotice(text) {
    this.noticeTarget.hidden = !text
    this.noticeTarget.textContent = text || ""
  }

  toast(text) {
    document.dispatchEvent(new CustomEvent("rupert:toast", { detail: { message: text } }))
  }
}
