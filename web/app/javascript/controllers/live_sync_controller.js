import { Controller } from "@hotwired/stimulus"

// Polls the live Turbo Stream endpoint and applies any returned updates to the
// page. Replaces the sync banner, "last synced" line, and recent runs list.
// When a running sync completes (banner flips data-just-finished), the page
// does a full reload so every widget reflects fresh data.
export default class extends Controller {
  static values = {
    interval: { type: Number, default: 5000 }
  }

  connect() {
    this.preserveDetails = (event) => {
      if (event.target.getAttribute("target") !== "source-sync-status") return
      const open = Array.from(document.querySelectorAll("[data-source-details][open]"), el => el.dataset.sourceDetails)
      const render = event.detail.render
      event.detail.render = async (stream) => {
        await render(stream)
        document.querySelectorAll("[data-source-details]").forEach(el => { el.open = open.includes(el.dataset.sourceDetails) })
      }
    }
    document.addEventListener("turbo:before-stream-render", this.preserveDetails)
    this.timer = setInterval(() => this.refresh(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
    document.removeEventListener("turbo:before-stream-render", this.preserveDetails)
  }

  refresh() {
    if (document.hidden || this.inFlight) return
    this.inFlight = true
    const sourceStatus = document.getElementById("source-sync-status") ? "?source_status=1" + (document.getElementById("dashboard-widgets") ? "&dashboard=1" : "") : ""
    fetch(`/live/sync_status${sourceStatus}`, {
      headers: {
        "Accept": "text/vnd.turbo-stream.html",
        "X-Requested-With": "XMLHttpRequest"
      }
    })
      .then(r => (r.ok ? r.text() : ""))
      .then(html => {
        if (!html) return
        Turbo.renderStreamMessage(html)
        this.maybeReload()
      })
      .catch(() => {})
      .finally(() => { this.inFlight = false })
  }

  maybeReload() {
    const banner = document.getElementById("sync-banner")
    if (banner && banner.dataset.justFinished === "1" && !document.getElementById("dashboard-widgets")) {
      window.location.reload()
    }
  }
}
