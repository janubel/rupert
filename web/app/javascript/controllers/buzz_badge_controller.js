import { Controller } from "@hotwired/stimulus"

// Unread badge for the Buzz team chat, on the shell: polls the chat's JSON
// endpoint quietly, counts messages newer than the last one this browser saw
// (and not posted by this person), and shows the count on the header icon and
// in the status bar with the latest message's author and first words. Badges,
// not popups: a toast is raised only when a new message mentions this person.
// Message text is other people's text and is only ever placed with textContent.
const SEEN_KEY = "rupert-buzz-seen"

export default class extends Controller {
  static targets = ["count", "latest", "author"]
  static values = { url: String, chatPath: String, mention: String, interval: { type: Number, default: 45000 } }

  connect() {
    this.unread = []
    this.newest = null
    this.seen = this.readSeen()
    this.onLoad = () => this.markSeenIfOnChat()
    document.addEventListener("turbo:load", this.onLoad)
    this.onVisible = () => { if (!document.hidden) this.poll() }
    document.addEventListener("visibilitychange", this.onVisible)
    this.markSeenIfOnChat()
    this.poll()
    this.timer = setInterval(() => this.poll(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
    document.removeEventListener("turbo:load", this.onLoad)
    document.removeEventListener("visibilitychange", this.onVisible)
  }

  // --- cursors: "posted_at:event_id"; newer means a later posted_at, then id ---
  static compare(a, b) {
    if (!a) return b ? -1 : 0
    if (!b) return 1
    const [at, id] = a.split(":"), [bt, bid] = b.split(":")
    const d = Number(at) - Number(bt)
    return d !== 0 ? d : id.localeCompare(bid)
  }

  readSeen() {
    try { return localStorage.getItem(SEEN_KEY) } catch (e) { return null }
  }

  writeSeen(cursor) {
    this.seen = cursor
    try { localStorage.setItem(SEEN_KEY, cursor) } catch (e) { /* private mode */ }
  }

  markSeenIfOnChat() {
    if (this.hasChatPathValue && window.location.pathname.startsWith(this.chatPathValue) && this.newest) {
      this.writeSeen(this.newest)
      this.unread = []
      this.render()
    }
  }

  // Clicking through to the chat clears the badge right away.
  open() {
    if (this.newest) this.writeSeen(this.newest)
    this.unread = []
    this.render()
  }

  async poll() {
    if (!this.hasUrlValue || document.hidden) return
    try {
      const url = new URL(this.urlValue, window.location.origin)
      if (this.newest) url.searchParams.set("after", this.newest)
      const response = await fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      if (!response.ok) return
      const data = await response.json()
      this.absorb(Array.isArray(data.messages) ? data.messages : [])
    } catch (_error) {
      /* offline or relay down: keep the last known state */
    }
  }

  absorb(messages) {
    const known = new Set(this.unread.map((m) => m.cursor))
    const fresh = []
    for (const m of messages) {
      if (!m || typeof m.cursor !== "string") continue
      if (!this.newest || this.constructor.compare(m.cursor, this.newest) > 0) this.newest = m.cursor
      if (m.mine || known.has(m.cursor)) continue
      if (this.seen && this.constructor.compare(m.cursor, this.seen) <= 0) continue
      fresh.push(m)
    }
    if (window.location.pathname.startsWith(this.chatPathValue || "/buzz/chat")) {
      if (this.newest) this.writeSeen(this.newest)
      this.unread = []
    } else {
      this.unread = this.unread.concat(fresh)
      fresh.forEach((m) => { if (this.mentions(m.text)) this.toast(m) })
    }
    this.render()
  }

  mentions(text) {
    if (!this.hasMentionValue || !this.mentionValue) return false
    return new RegExp(`@${this.mentionValue.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`, "i").test(String(text || ""))
  }

  toast(message) {
    window.dispatchEvent(new CustomEvent("rupert:toast", {
      detail: { title: `${message.author || "Buzz"} mentioned you`, body: String(message.text || "").slice(0, 140), href: this.chatPathValue }
    }))
  }

  render() {
    const count = this.unread.length
    this.countTargets.forEach((el) => {
      el.textContent = count > 99 ? "99+" : String(count)
      el.hidden = count === 0
      el.setAttribute("aria-label", count === 1 ? "1 unread message" : `${count} unread messages`)
    })
    const latest = this.unread[this.unread.length - 1]
    if (this.hasLatestTarget) {
      this.latestTarget.textContent = latest ? String(latest.text || "").replace(/\s+/g, " ").slice(0, 90) : ""
      this.latestTarget.hidden = !latest
    }
    if (this.hasAuthorTarget) {
      this.authorTarget.textContent = latest ? String(latest.author || "") : ""
      this.authorTarget.hidden = !latest
    }
  }
}
