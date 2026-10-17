import { Controller } from "@hotwired/stimulus"

// Google Pay. Google encrypts the card for Authorize.net (gateway
// "authorizenet", gatewayMerchantId = API Login ID); the token is submitted in
// the same hidden fields as the card flow with descriptor
// COMMON.GOOGLE.INAPP.PAYMENT, so the server never sees card numbers.
export default class extends Controller {
  static targets = ["wrapper", "button"]
  static values = { loginId: String, total: String, environment: String, merchantId: String, merchantName: String }

  connect() {
    this.loadScript()
      .then(() => this.setup())
      .catch(() => {})
  }

  loadScript() {
    if (window.google?.payments?.api) return Promise.resolve()
    return new Promise((resolve, reject) => {
      const script = document.createElement("script")
      script.src = "https://pay.google.com/gp/p/js/pay.js"
      script.onload = resolve
      script.onerror = reject
      document.head.appendChild(script)
    })
  }

  baseRequest() {
    return { apiVersion: 2, apiVersionMinor: 0 }
  }

  cardMethod() {
    return {
      type: "CARD",
      parameters: {
        allowedAuthMethods: ["PAN_ONLY", "CRYPTOGRAM_3DS"],
        allowedCardNetworks: ["AMEX", "DISCOVER", "MASTERCARD", "VISA"],
      },
    }
  }

  async setup() {
    this.client = new window.google.payments.api.PaymentsClient({ environment: this.environmentValue })
    const ready = await this.client.isReadyToPay({
      ...this.baseRequest(),
      allowedPaymentMethods: [this.cardMethod()],
    })
    if (!ready.result) return
    this.buttonTarget.appendChild(this.client.createButton({ onClick: () => this.pay(), buttonType: "buy" }))
    this.wrapperTarget.hidden = false
  }

  async pay() {
    const request = {
      ...this.baseRequest(),
      allowedPaymentMethods: [{
        ...this.cardMethod(),
        tokenizationSpecification: {
          type: "PAYMENT_GATEWAY",
          parameters: { gateway: "authorizenet", gatewayMerchantId: this.loginIdValue },
        },
      }],
      transactionInfo: { totalPriceStatus: "FINAL", totalPrice: this.totalValue, currencyCode: "USD", countryCode: "US" },
      merchantInfo: { merchantName: this.merchantNameValue, ...(this.merchantIdValue ? { merchantId: this.merchantIdValue } : {}) },
    }
    try {
      const data = await this.client.loadPaymentData(request)
      const token = data.paymentMethodData.tokenizationData.token
      this.field("payment_nonce").value = btoa(token)
      this.field("data_descriptor").value = "COMMON.GOOGLE.INAPP.PAYMENT"
      this.element.requestSubmit()
    } catch (error) {
      if (error.statusCode !== "CANCELED") this.showError("Google Pay could not complete. Please use a card instead.")
    }
  }

  field(name) {
    return this.element.querySelector(`[name=${name}]`)
  }

  showError(message) {
    const target = this.element.querySelector("[data-accept-payment-target=error]")
    if (target) target.textContent = message
  }
}
