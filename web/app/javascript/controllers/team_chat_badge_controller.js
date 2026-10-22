import { Controller } from "@hotwired/stimulus"

// Unread badge for the Team chat, on the shell: polls one room's JSON feed
// quietly (the server answers with every room's unread and mention counts),
// shows the total on the header icon and in the status bar with the latest
// message's author and first words. Badges, not popups: a toast is raised only
// when the mention count grows. Message text is other people's text and is
// only ever placed with textContent.
export default class extends Controller {
  static targets = ["count", "latest", "author"]
  static values = { url: String, chatPath: String, interval: { type: Number, default: 45000 } }

  connect() {
    this.since = null
    this.mentions = null
    this.onVisible = () => { if (!document.hidden) this.poll() }
    document.addEventListener("visibilitychange", this.onVisible)
    this.poll()
    this.timer = setInterval(() => this.poll(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
    document.removeEventListener("visibilitychange", this.onVisible)
  }

  // Clicking through to the chat clears the badge right away; the chat page marks rooms read.
  open() {
    this.render(0, null)
  }

  async poll() {
    if (!this.hasUrlValue || document.hidden) return
    if (this.hasChatPathValue && window.location.pathname.startsWith(this.chatPathValue)) return
    try {
      const url = new URL(this.urlValue, window.location.origin)
      if (this.since) url.searchParams.set("since", this.since)
      const response = await fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      if (!response.ok) return
      const data = await response.json()
      if (typeof data.now === "string") this.since = data.now
      const rooms = Array.isArray(data.rooms) ? data.rooms : []
      const unread = rooms.reduce((sum, room) => sum + (Number(room.unread) || 0), 0)
      const mentions = rooms.reduce((sum, room) => sum + (Number(room.mentions) || 0), 0)
      const messages = Array.isArray(data.messages) ? data.messages : []
      const latest = messages.filter((m) => m && !m.mine).pop()
      if (this.mentions !== null && mentions > this.mentions) this.toast(latest)
      this.mentions = mentions
      this.render(unread, latest)
    } catch (_error) {
      /* offline: keep the last known state */
    }
  }

  toast(message) {
    window.dispatchEvent(new CustomEvent("rupert:toast", {
      detail: {
        title: "You were mentioned in team chat",
        body: message ? String(message.body || "").slice(0, 140) : "",
        href: this.chatPathValue
      }
    }))
  }

  render(count, latest) {
    this.countTargets.forEach((el) => {
      el.textContent = count > 99 ? "99+" : String(count)
      el.hidden = count === 0
      el.setAttribute("aria-label", count === 1 ? "1 unread message" : `${count} unread messages`)
    })
    const show = count > 0 && latest
    const author = show ? (typeof latest.author === "string" ? latest.author : latest.author?.name || "") : ""
    if (this.hasLatestTarget) {
      this.latestTarget.textContent = show ? String(latest.body || "").replace(/\s+/g, " ").slice(0, 90) : ""
      this.latestTarget.hidden = !show
    }
    if (this.hasAuthorTarget) {
      this.authorTarget.textContent = author
      this.authorTarget.hidden = !show || !author
    }
  }
}
