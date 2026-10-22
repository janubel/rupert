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
    "thread", "threadLog", "threadInput", "threadSend", "newRoom", "topic", "suggest", "files", "fileInput"]
  static values = { url: String, roomUrl: String, room: String, direct: Boolean, postMax: { type: Number, default: 4000 }, title: String,
    people: Array, agents: Array, me: String, emoji: Array, fileMax: { type: Number, default: 8388608 }, fileCount: { type: Number, default: 4 } }

  static GROUP_SECONDS = 5 * 60
  static FAST = 1000
  static SLOW = 3000
  static RUPERT = { id: null, name: "rupert", label: "Rupert — the assistant" }
  static SHRINK_OVER = 1.5 * 1024 * 1024
  static SHRINK_TO = 2048

  connect() {
    this.byId = new Map()
    this.since = null
    this.hasMore = false
    this.threadId = null
    this.busy = false
    this.sending = false
    this.suggestIndex = 0
    this.suggestions = []
    this.pendingFiles = []
    this.mentionIds = new Set()
    this.load()
    this.schedule()
    this.onVisible = () => { if (!document.hidden) this.poll() }
    document.addEventListener("visibilitychange", this.onVisible)
  }

  disconnect() {
    clearTimeout(this.timer)
    document.removeEventListener("visibilitychange", this.onVisible)
    document.title = this.titleValue
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
    this.timer = setTimeout(async () => { await this.poll(); this.schedule() }, pending ? this.constructor.FAST : this.constructor.SLOW)
  }

  async load() {
    const data = await this.fetchJson(this.query({}))
    this.loadingTarget.hidden = true
    if (!data) return this.showNotice("Could not load messages. Check your connection; this page will keep trying.")
    this.since = data.now
    this.hasMore = data.has_more
    this.merge(data.messages)
    this.renderRooms(data.rooms)
    this.render({ stick: true })
  }

  async poll() {
    if (document.hidden || this.busy || !this.since) return
    this.busy = true
    const data = await this.fetchJson(this.query({ since: this.since, thread: this.threadId }))
    this.busy = false
    if (!data) return
    this.since = data.now
    const fresh = this.merge(data.messages)
    this.renderRooms(data.rooms)
    if (fresh.changed) this.render({ stick: false, newItems: fresh.added })
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
      } else if (old.updated_at !== message.updated_at || old.reply_count !== message.reply_count || old.body !== message.body || old.activity !== message.activity ||
          JSON.stringify(old.reactions) !== JSON.stringify(message.reactions)) {
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
    if (this.threadId) this.renderThread()
  }

  renderList(messages, { thread }) {
    const nodes = []
    let previous = null
    messages.forEach((message) => {
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
    row.append(avatar)

    const main = document.createElement("div")
    main.className = "chat-msg-main"
    if (!continued) {
      const head = document.createElement("p")
      head.className = "chat-msg-head"
      const author = document.createElement("span")
      author.className = "chat-msg-author"
      author.textContent = message.author.name
      head.append(author)
      if (message.kind !== "person") {
        const badge = document.createElement("span")
        badge.className = "chat-msg-badge"
        badge.textContent = message.kind === "system" ? "Notice" : "Assistant"
        head.append(badge)
      }
      const time = document.createElement("time")
      time.className = "chat-msg-time"
      time.dateTime = message.created_at
      time.title = new Date(message.created_at).toLocaleString()
      time.textContent = new Date(message.created_at).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })
      head.append(time)
      main.append(head)
    }

    const body = document.createElement("div")
    body.className = "chat-msg-body"
    if (message.deleted) {
      const gone = document.createElement("span")
      gone.className = "chat-msg-deleted"
      gone.textContent = "This message was deleted."
      body.append(gone)
    } else {
      if (message.body) body.append(...this.formatted(message.body))
      if (message.status === "pending") body.append(this.activityNode(message))
    }
    main.append(body)

    if (!message.deleted && message.attachments?.length) main.append(this.attachmentsNode(message.attachments))
    ;(message.actions || []).forEach((action) => main.append(this.actionNode(message, action)))
    if (message.reactions?.length) main.append(this.reactionsNode(message))

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
      tools.append(this.toolButton("React", (event) => this.openPalette(message, event.currentTarget)))
      if (!thread && message.kind !== "system") tools.append(this.toolButton("Reply in thread", () => this.openThread(message.id)))
      if (message.mine) tools.append(this.toolButton("Delete", () => this.deleteMessage(message)))
      if (tools.childElementCount) row.append(tools)
    }
    return row
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
      holder.append(link)
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
    const handles = ["rupert", ...this.agentsValue.map((agent) => agent.name)]
    return this.constructor.parseInline(line, names, handles).map((part) => {
      if (part.type === "text") return document.createTextNode(part.text)
      const node = document.createElement(part.type === "bold" ? "strong" : part.type === "code" ? "code" : part.type === "link" ? "a" : "span")
      node.textContent = part.text
      if (part.type === "mention") node.className = "chat-mention"
      if (part.type === "link") {
        node.href = part.href
        if (part.external) {
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
    document.title = total > 0 ? `(${total}) ${this.titleValue}` : this.titleValue
  }

  // --- threads ---

  async openThread(id) {
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
    this.autosize(this.inputTarget)
    this.sendTarget.disabled = this.inputTarget.value.trim() === "" && this.pendingFiles.length === 0
    this.updateSuggest()
  }

  threadInputChanged() {
    this.autosize(this.threadInputTarget)
    this.threadSendTarget.disabled = this.threadInputTarget.value.trim() === ""
  }

  autosize(field) {
    field.style.height = "auto"
    field.style.height = `${Math.min(field.scrollHeight, 192)}px`
  }

  keydown(event) {
    if (!this.suggestTarget.hidden) {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault()
        const step = event.key === "ArrowDown" ? 1 : -1
        this.suggestIndex = (this.suggestIndex + step + this.suggestions.length) % this.suggestions.length
        this.renderSuggest()
        return
      }
      if (event.key === "Tab" || event.key === "Enter") {
        event.preventDefault()
        this.completeMention(this.suggestions[this.suggestIndex])
        return
      }
      if (event.key === "Escape") {
        this.suggestTarget.hidden = true
        return
      }
    }
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault()
      this.formTarget.requestSubmit()
    }
  }

  threadKeydown(event) {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault()
      event.target.form.requestSubmit()
    }
  }

  // "@" plus the start of a name suggests Rupert and the people who use team chat.
  updateSuggest() {
    const field = this.inputTarget
    const before = field.value.slice(0, field.selectionStart)
    const match = before.match(/(?:^|\s)@([\p{L}\p{N}'-]{0,30})$/u)
    if (!match) {
      this.suggestTarget.hidden = true
      this.suggestions = []
      return
    }
    const term = match[1].toLowerCase()
    const starts = (name) => name.toLowerCase().split(/\s+/).some((word) => word.startsWith(term)) || name.toLowerCase().startsWith(term)
    const options = [this.constructor.RUPERT, ...this.agentsValue, ...this.peopleValue.map((person) => ({ ...person, label: person.name }))].filter((option) => starts(option.name)).slice(0, 8)
    if (!options.length || (options.length === 1 && options[0].name.toLowerCase() === term)) {
      this.suggestTarget.hidden = true
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
    this.suggestTarget.replaceChildren(...items)
    this.suggestTarget.hidden = false
  }

  completeMention(option) {
    if (!option) return
    const field = this.inputTarget
    const cursor = field.selectionStart
    const before = field.value.slice(0, cursor).replace(/@[\p{L}\p{N}'-]*$/u, `@${option.name} `)
    field.value = before + field.value.slice(cursor)
    field.selectionStart = field.selectionEnd = before.length
    if (option.id) this.mentionIds.add(option.id)
    this.suggestTarget.hidden = true
    this.suggestions = []
    this.input()
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
    this.inputTarget.value = event.currentTarget.textContent.trim()
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
