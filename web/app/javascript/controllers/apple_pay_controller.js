import { Controller } from "@hotwired/stimulus"

// Apple Pay on the web. Shows the button only when Safari/an Apple device can
// pay; the wallet token is base64-encoded and submitted in the same hidden
// fields the card flow uses (descriptor COMMON.APPLE.INAPP.PAYMENT), so the
// server never sees card numbers.
export default class extends Controller {
  static targets = ["wrapper", "button"]
  static values = { sessionUrl: String, total: String, label: String }

  connect() {
    if (window.ApplePaySession && window.ApplePaySession.canMakePayments()) {
      this.wrapperTarget.hidden = false
    }
  }

  pay() {
    const session = new window.ApplePaySession(6, {
      countryCode: "US",
      currencyCode: "USD",
      supportedNetworks: ["visa", "masterCard", "amex", "discover"],
      merchantCapabilities: ["supports3DS"],
      total: { label: this.labelValue, amount: this.totalValue },
    })

    session.onvalidatemerchant = async (event) => {
      try {
        const response = await fetch(this.sessionUrlValue, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content || "",
          },
          body: JSON.stringify({ validation_url: event.validationURL }),
        })
        if (!response.ok) throw new Error("validation failed")
        session.completeMerchantValidation(await response.json())
      } catch (_error) {
        session.abort()
        this.showError("Apple Pay could not start. Please use a card instead.")
      }
    }

    session.onpaymentauthorized = (event) => {
      const token = btoa(JSON.stringify(event.payment.token.paymentData))
      this.field("payment_nonce").value = token
      this.field("data_descriptor").value = "COMMON.APPLE.INAPP.PAYMENT"
      session.completePayment(window.ApplePaySession.STATUS_SUCCESS)
      this.element.requestSubmit()
    }

    session.oncancel = () => {}
    session.begin()
  }

  field(name) {
    return this.element.querySelector(`[name=${name}]`)
  }

  showError(message) {
    const target = this.element.querySelector("[data-accept-payment-target=error]")
    if (target) target.textContent = message
  }
}
