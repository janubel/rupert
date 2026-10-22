import { Controller } from "@hotwired/stimulus"

// Cash flow dashboard: draws the canvases from the embedded JSON block and keeps
// the page current. Every 30 seconds it fetches the same page as a Turbo Stream;
// the server swaps the figure, table, position and event regions in place and
// this controller re-reads the data block and updates the charts without
// recreating them (no flash, no layout jump). Colours come from the theme's
// chart tokens read off :root, so the charts follow light, dark and the other
// appearances, and re-theme when the account menu changes them.
const money = (cents) => {
  const dollars = Math.abs(cents) / 100
  const sign = cents < 0 ? "−" : ""
  return `${sign}$${dollars.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
}
const compact = (cents) => {
  const dollars = Math.abs(cents) / 100
  const sign = cents < 0 ? "−" : ""
  if (dollars >= 1_000_000) return `${sign}$${(dollars / 1_000_000).toFixed(1).replace(/\.0$/, "")}M`
  if (dollars >= 1000) return `${sign}$${(dollars / 1000).toFixed(1).replace(/\.0$/, "")}K`
  return `${sign}$${Math.round(dollars)}`
}

export default class extends Controller {
  static targets = ["bankChart", "channelChart", "data", "live", "liveText"]
  static values = { interval: { type: Number, default: 30000 }, url: String }

  connect() {
    this.charts = {}
    this.refreshedAt = Date.now()
    this.onTheme = () => this.retheme()
    this.onStream = (event) => this.afterStream(event)
    window.addEventListener("rupert:theme", this.onTheme)
    document.addEventListener("turbo:before-stream-render", this.onStream)
    this.draw()
    this.timer = setInterval(() => this.poll(), this.intervalValue)
    this.ticker = setInterval(() => this.tick(), 5000)
  }

  disconnect() {
    clearInterval(this.timer)
    clearInterval(this.ticker)
    window.removeEventListener("rupert:theme", this.onTheme)
    document.removeEventListener("turbo:before-stream-render", this.onStream)
    Object.values(this.charts).forEach((chart) => chart.destroy())
    this.charts = {}
  }

  // --- data & theme ---------------------------------------------------------

  // Named payload(): Stimulus reserves this.data for its own data map.
  payload() {
    try { return JSON.parse(this.dataTarget.textContent) } catch (e) { return null }
  }

  tokens() {
    const style = getComputedStyle(document.documentElement)
    const read = (name, fallback) => style.getPropertyValue(name).trim() || fallback
    return {
      slots: [read("--chart-muted", "#9aa7a4"), read("--chart-1", "#2f6fd8"), read("--chart-2", "#d9641e"), read("--chart-3", "#1f8a5a"), read("--chart-4", "#6b55c8")],
      in: read("--chart-in", "#2f6fd8"), out: read("--chart-out", "#d9641e"),
      ink: read("--color-ink", "#17353a"), text: read("--color-mocha", "#36504f"), grid: read("--color-fog", "#cddad3"),
      surface: read("--color-paper", "#fbfdfc"), muted: read("--chart-muted", "#9aa7a4")
    }
  }

  // Charts size themselves from their width (no fixed heights in the markup);
  // phones get a taller ratio so the bars keep room to breathe.
  ratio(wide) {
    return window.innerWidth < 640 ? wide * 0.6 : wide
  }

  // --- drawing ----------------------------------------------------------------

  draw() {
    const Chart = window.Chart
    const data = this.payload()
    if (!Chart || !data) return
    this.drawBank(Chart, data)
    this.drawChannels(Chart, data)
  }

  baseOptions(t, { stacked = false, aspect = 2.2 } = {}) {
    return {
      responsive: true, maintainAspectRatio: true, aspectRatio: this.ratio(aspect), animation: { duration: 250 },
      interaction: { mode: "index", intersect: false },
      layout: { padding: { top: 8 } },
      scales: {
        x: { stacked, grid: { display: false }, border: { color: t.grid }, ticks: { color: t.text, maxTicksLimit: 10, maxRotation: 0, autoSkip: true } },
        y: { stacked, grid: { color: t.grid, lineWidth: 1 }, border: { display: false }, ticks: { color: t.text, maxTicksLimit: 6, callback: (v) => compact(v) } }
      },
      plugins: {
        legend: { position: "bottom", align: "start", labels: { color: t.text, usePointStyle: true, boxWidth: 10, boxHeight: 10, padding: 16 } },
        tooltip: {
          backgroundColor: t.surface, titleColor: t.ink, bodyColor: t.ink, borderColor: t.grid, borderWidth: 1,
          padding: 10, displayColors: true, boxWidth: 8, boxHeight: 8, usePointStyle: true,
          callbacks: { label: (ctx) => ` ${money(Math.round(ctx.parsed.y))}  ${ctx.dataset.label}` }
        }
      }
    }
  }

  // The diverging in/out pair above and below the baseline, with the running net as a
  // line on the same dollar axis. Forecast weeks (the retained scenario's own receipts
  // less payments) continue the line past the range end as a dashed segment.
  bankDatasets(t, bank, forecast) {
    const actual = bank.in.length
    const future = Array((forecast && forecast.labels || []).length).fill(null)
    return [
      { type: "bar", label: "Into the bank", data: [...bank.in, ...future], backgroundColor: t.in, borderWidth: 0, borderRadius: 4, borderSkipped: "start", maxBarThickness: 24, order: 2 },
      { type: "bar", label: "Out of the bank", data: [...bank.out.map((v) => -v), ...future], backgroundColor: t.out, borderWidth: 0, borderRadius: 4, borderSkipped: "start", maxBarThickness: 24, order: 2 },
      { type: "line", label: future.length ? "Running net (dashed: forecast)" : "Running net", data: [...bank.cumulative, ...((forecast && forecast.cumulative) || [])],
        borderColor: t.ink, borderWidth: 2, tension: 0.25, pointRadius: 0, pointHoverRadius: 5, pointHitRadius: 12,
        pointBackgroundColor: t.ink, pointBorderColor: t.surface, pointBorderWidth: 2, order: 1, spanGaps: true,
        segment: { borderDash: (ctx) => (ctx.p1DataIndex >= actual ? [6, 4] : undefined) } }
    ]
  }

  bankLabels(data) {
    return [...data.range.labels, ...((data.forecast && data.forecast.labels) || [])]
  }

  drawBank(Chart, data) {
    if (!this.hasBankChartTarget) return
    const t = this.tokens()
    const actual = data.range.labels.length
    const options = this.baseOptions(t, { aspect: 2.4 })
    options.scales.x.stacked = true
    options.scales.y.grid.color = (ctx) => (ctx.tick.value === 0 ? t.text : t.grid)
    options.plugins.legend.labels.usePointStyle = false
    options.plugins.legend.labels.generateLabels = (chart) => chart.data.datasets.map((ds, i) => ({
      text: ds.label, fillStyle: ds.type === "line" ? "transparent" : ds.backgroundColor, strokeStyle: ds.type === "line" ? ds.borderColor : ds.backgroundColor,
      lineWidth: ds.type === "line" ? 2 : 0, lineDash: [], fontColor: t.text, datasetIndex: i, hidden: !chart.isDatasetVisible(i)
    }))
    options.plugins.tooltip.callbacks.title = (items) => items.length && items[0].dataIndex >= actual ? `${items[0].label} · forecast` : items.length ? items[0].label : ""
    options.plugins.tooltip.callbacks.label = (ctx) => {
      if (ctx.parsed.y === null || ctx.parsed.y === undefined) return null
      const raw = ctx.dataset.label === "Out of the bank" ? -ctx.parsed.y : ctx.parsed.y
      const name = ctx.dataset.type === "line" ? (ctx.dataIndex >= actual ? "Running net, forecast" : "Running net") : ctx.dataset.label
      return ` ${money(Math.round(raw))}  ${name}`
    }
    this.charts.bank = new Chart(this.bankChartTarget, { data: { labels: this.bankLabels(data), datasets: this.bankDatasets(t, data.bank, data.forecast) }, options })
  }

  channelDatasets(t, channels) {
    return channels.map((c) => ({
      type: "bar", label: c.name, data: c.values, backgroundColor: t.slots[c.slot] || t.muted,
      // A 2px surface-coloured edge is the gap between stacked segments and neighbours.
      borderColor: t.surface, borderWidth: 2, borderSkipped: false, maxBarThickness: 24
    }))
  }

  drawChannels(Chart, data) {
    if (!this.hasChannelChartTarget) return
    const t = this.tokens()
    this.charts.channels = new Chart(this.channelChartTarget, {
      type: "bar", data: { labels: data.range.labels, datasets: this.channelDatasets(t, data.channels) },
      options: this.baseOptions(t, { stacked: true, aspect: 2 })
    })
  }

  // Update in place after a live refresh: same chart objects, new numbers.
  update() {
    const data = this.payload()
    if (!data) return
    const t = this.tokens()
    if (this.charts.bank) {
      const chart = this.charts.bank
      chart.data.labels = this.bankLabels(data)
      const sets = this.bankDatasets(t, data.bank, data.forecast)
      chart.data.datasets.forEach((ds, i) => { ds.data = sets[i].data; ds.label = sets[i].label })
      chart.update("none")
    }
    if (this.charts.channels) {
      const chart = this.charts.channels
      chart.data.labels = data.range.labels
      const sets = this.channelDatasets(t, data.channels)
      if (sets.length === chart.data.datasets.length && sets.every((s, i) => s.label === chart.data.datasets[i].label)) {
        chart.data.datasets.forEach((ds, i) => { ds.data = sets[i].data })
      } else {
        chart.data.datasets = sets
      }
      chart.update("none")
    }
  }

  retheme() {
    Object.values(this.charts).forEach((chart) => chart.destroy())
    this.charts = {}
    this.draw()
  }

  // --- live refresh -----------------------------------------------------------------

  poll() {
    if (document.hidden || this.inFlight) return
    this.inFlight = true
    fetch(this.urlValue || window.location.href, { headers: { Accept: "text/vnd.turbo-stream.html", "X-Requested-With": "XMLHttpRequest" } })
      .then((r) => (r.ok ? r.text() : ""))
      .then((html) => { if (html) window.Turbo.renderStreamMessage(html) })
      .catch(() => {})
      .finally(() => { this.inFlight = false })
  }

  // After the data block is swapped, redraw from it. Stream render is async, so wrap it.
  afterStream(event) {
    if (event.target.getAttribute("target") !== "cash-flow-data") return
    const render = event.detail.render
    event.detail.render = async (stream) => {
      await render(stream)
      this.refreshedAt = Date.now()
      this.update()
      this.tick()
    }
  }

  tick() {
    if (!this.hasLiveTextTarget) return
    const seconds = Math.round((Date.now() - this.refreshedAt) / 1000)
    this.liveTextTarget.textContent = seconds < 8 ? "Live · refreshed just now" : `Live · refreshed ${seconds < 60 ? `${seconds}s` : `${Math.round(seconds / 60)} min`} ago`
    if (this.hasLiveTarget) this.liveTarget.dataset.stale = seconds > this.intervalValue / 1000 * 3 ? "1" : "0"
  }
}
