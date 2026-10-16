import { Controller } from "@hotwired/stimulus"
import { mountNmiFields } from "lib/nmi_fields"

export default class extends Controller {
  static targets = ["items", "subtotal", "tax", "choices", "custom", "confirm", "status", "payment", "pay", "receipt", "nmiFields"]
  static values = { stateUrl: String, tipUrl: String, configUrl: String, payUrl: String }
  connect() {
    this.revision = null
    window.rupertPosPaymentResponse = response => this.cardResponse(response)
    this.poll(); this.timer = setInterval(() => this.poll(), 1500)
  }
  disconnect() { this.connected = false; this.paymentAbort?.abort(); this.nmi?.destroy(); clearInterval(this.timer); clearTimeout(this.timeout); this.abort?.abort(); delete window.rupertPosPaymentResponse }
  money(cents) { return new Intl.NumberFormat(undefined, { style: "currency", currency: "USD" }).format(cents / 100) }
  async poll() {
    if (this.polling) return
    this.polling = true
    try {
      this.abort = new AbortController(); this.timeout = setTimeout(() => this.abort.abort(), 8000)
      const response = await fetch(this.stateUrlValue, { cache: "no-store", signal: this.abort.signal })
      if (!response.ok) throw new Error(response.status === 410 ? "This customer screen has closed. Ask the cashier to pair it again." : "Connection interrupted. Please wait before confirming.")
      const state = await response.json()
      if (!state.active) throw new Error("This customer screen has closed.")
      this.connected = true
      if (this.revision !== state.cart_revision) {
        this.revision = state.cart_revision; this.configuredCheckout = null; this.paymentAbort?.abort(); this.nmi?.destroy(); this.nmi = null; this.nmiFieldsTarget.hidden = true
        this.element.querySelectorAll('input[name="choice"]').forEach(input => input.checked = false)
        this.customTarget.hidden = true
        this.customTarget.querySelector('input').required = false
        this.customTarget.querySelector('input').value = ''
        this.itemsTarget.replaceChildren()
        state.lines.forEach(line => {
          const row = document.createElement("div"); row.className = "flex items-center gap-3"
          if (line.thumbnail_url) { const img = document.createElement("img"); img.src = line.thumbnail_url; img.alt = line.product_title; img.referrerPolicy = "no-referrer"; img.className = "h-16 w-16 rounded-lg object-contain"; row.append(img) }
          const text = document.createElement("p"); text.className = "text-sm"; text.textContent = `${line.product_title} · ${line.quantity} × ${line.unit_price}`; row.append(text); this.itemsTarget.append(row)
        })
      }
      this.subtotalTarget.textContent = this.money(state.subtotal_cents)
      this.taxTarget.textContent = state.tax_verified ? this.money(state.tax_cents) : "Needs source verification"
      this.hasCart = state.lines.length > 0; this.confirmed = state.confirmed
      const frozen = !!state.checkout && state.checkout.status !== "cancelled"
      this.choicesTarget.disabled = state.confirmed || !this.hasCart || frozen || this.submitting
      this.confirmTarget.disabled = state.confirmed || !this.hasCart || frozen || this.submitting
      this.confirmTarget.textContent = state.confirmed ? "Choice confirmed" : "Confirm my choice"
      this.paymentTarget.hidden = true; this.receiptTarget.hidden = true
      if (!state.checkout || !["ready", "declined"].includes(state.checkout.status)) { this.paymentAbort?.abort(); this.nmi?.destroy(); this.nmi = null; this.nmiFieldsTarget.hidden = true; this.configuredCheckout = null }
      if (state.checkout?.status === "paid") {
        this.receiptTarget.hidden = false
        this.receiptTarget.textContent = `${state.checkout.sandbox ? "Sandbox receipt · " : (state.checkout.demo ? "Demo receipt · " : "Receipt · ")}${state.checkout.reference} · Paid ${this.money(state.checkout.total_cents)} · Tip ${this.money(state.checkout.tip_cents)}${state.checkout.tender === "cash" ? ` · Change ${this.money(state.checkout.change_cents)}` : ""}${state.checkout.inventory_pending ? " · Stock update pending" : ""}`
        this.statusTarget.textContent = state.checkout.sandbox ? "Sandbox test complete. No live money, sales or stock movement." : (state.checkout.demo ? "Demonstration complete. No money was collected." : "Thank you. Your payment is complete.")
      } else if (["processing", "unknown"].includes(state.checkout?.status)) {
        this.statusTarget.textContent = "Verifying your payment. Please do not submit another payment."
      } else if (state.checkout?.tender === "card" && ["ready", "declined"].includes(state.checkout.status)) {
        this.paymentTarget.hidden = false
        this.payTarget.textContent = `${state.checkout.sandbox ? "Sandbox pay" : (state.checkout.demo ? "Simulate payment" : "Pay")} ${this.money(state.checkout.total_cents)}`
        this.payTarget.disabled = true
        this.statusTarget.textContent = state.checkout.status === "declined" ? "Payment declined. No paid receipt was issued. You can try a new card." : "Review the total, then pay securely."
        if (this.configuredCheckout !== state.checkout.reference) await this.configurePayment(state.checkout)
        this.payTarget.disabled = this.submitting || this.tokenizing || !this.paymentReady
      } else {
        this.statusTarget.textContent = state.confirmed ? `Your tip choice of ${this.money(state.tip_cents)} is confirmed. Waiting for the cashier.` : this.hasCart ? "Your tip choice stays private until you confirm." : "Waiting for the cashier’s cart…"
      }
    } catch (error) {
      this.connected = false; this.confirmTarget.disabled = true; this.payTarget.disabled = true
      this.statusTarget.textContent = error.name === "AbortError" ? "Connection interrupted. Please wait before confirming." : error.message
    } finally { clearTimeout(this.timeout); this.polling = false }
  }
  choiceChanged(event) {
    this.customTarget.hidden = event.target.value !== "custom"
    this.customTarget.querySelector("input").required = event.target.value === "custom"
    this.confirmTarget.disabled = !this.connected || !this.hasCart || this.confirmed
  }
  async confirm(event) {
    event.preventDefault()
    if (!this.connected || !event.target.reportValidity()) return
    this.confirmTarget.disabled = true
    const form = new FormData(event.target)
    try {
      await this.post(this.tipUrlValue, { cart_revision: this.revision, choice: form.get("choice"), amount: form.get("amount") })
      this.poll()
    } catch (error) { this.statusTarget.textContent = error.message; this.confirmTarget.disabled = !this.connected }
  }
  async configurePayment(checkout) {
    this.paymentReady = false
    const response = await fetch(this.configUrlValue, { cache: "no-store", signal: this.abort.signal })
    if (!response.ok) throw new Error("The payment form is unavailable. Ask the cashier to check setup.")
    const config = await response.json()
    this.demoPayment = config.demo
    this.paymentAbort?.abort(); this.nmi?.destroy(); this.nmi = null
    this.nmiFieldsTarget.hidden = config.provider !== "nmi"
    this.payTarget.classList.remove("AcceptUI")
    if (config.provider === "nmi") {
      const reference = checkout.reference
      this.configuredCheckout = reference
      this.paymentAbort = new AbortController()
      this.nmi = await mountNmiFields(config, {
        signal: this.paymentAbort.signal,
        onReady: () => { if (this.configuredCheckout === reference) { this.paymentReady = true; this.payTarget.disabled = this.submitting || !this.connected } },
        onError: message => { if (this.configuredCheckout === reference) { this.tokenizing = false; this.statusTarget.textContent = message; this.payTarget.disabled = this.submitting || !this.connected } },
        onToken: token => { if (this.configuredCheckout === reference && this.tokenizing) { this.tokenizing = false; this.submitPayment({ payment_nonce: token, checkout_reference: reference }) } }
      })
      return
    }
    this.payTarget.classList.toggle("AcceptUI", !config.demo)
    if (!config.demo) {
      this.payTarget.setAttribute("data-apiLoginID", config.login_id)
      this.payTarget.setAttribute("data-clientKey", config.client_key)
      this.payTarget.setAttribute("data-responseHandler", "rupertPosPaymentResponse")
      this.payTarget.setAttribute("data-acceptUIFormBtnTxt", "Use this card")
      this.payTarget.setAttribute("data-acceptUIFormHeaderTxt", "Secure card details")
      this.payTarget.setAttribute("data-billingAddressOptions", '{"show":true,"required":true}')
      if (this.loadedScript && this.loadedScript !== config.script_url) throw new Error("Gateway environment changed. Reload the customer screen.")
      if (!this.loadedScript) {
        await new Promise((resolve, reject) => {
          const script = document.createElement("script"); script.src = config.script_url
          const timer = setTimeout(() => { script.remove(); reject(new Error("Secure payment form could not load.")) }, 8000)
          script.onload = () => { clearTimeout(timer); resolve() }
          script.onerror = () => { clearTimeout(timer); script.remove(); reject(new Error("Secure payment form could not load.")) }
          document.head.append(script)
        })
        this.loadedScript = config.script_url
      }
    }
    this.configuredCheckout = checkout.reference; this.paymentReady = true
  }
  async demoPay() {
    if (this.submitting || this.tokenizing || !this.connected || !this.paymentReady) return
    if (this.nmi) { this.tokenizing = true; this.payTarget.disabled = true; this.nmi.pay() }
    else if (this.demoPayment) await this.submitPayment({})
  }
  async cardResponse(response) {
    if (response?.messages?.resultCode !== "Ok" || response?.opaqueData?.dataDescriptor !== "COMMON.ACCEPT.INAPP.PAYMENT") {
      this.statusTarget.textContent = "Card details could not be tokenized. No payment was submitted."; return
    }
    await this.submitPayment({ payment_nonce: response.opaqueData.dataValue })
  }
  async submitPayment(body) {
    if (this.submitting || !this.connected) return
    this.submitting = true; this.payTarget.disabled = true; this.statusTarget.textContent = "Verifying payment. Please wait…"
    try { await this.post(this.payUrlValue, body) }
    catch (error) { this.statusTarget.textContent = error.message }
    finally { this.submitting = false; this.poll() }
  }
  async post(url, body) {
    const response = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content }, body: JSON.stringify(body) })
    const result = await response.json()
    if (!response.ok) throw new Error(result.error || "The request could not be verified. Check payment status before trying again.")
    return result
  }
}
