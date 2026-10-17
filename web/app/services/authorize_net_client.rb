# frozen_string_literal: true

require 'net/http'
require 'json'

# Thin client for Authorize.net's Payment API (JSON over HTTPS). Only the
# Accept.js flow is used here: the browser tokenizes card data into a payment
# nonce (opaqueData) so raw card numbers never reach the server.
#
# Credentials come first from the tenant's Valmar connection when its gateway is
# Authorize.net (POS & payment connections page, stored encrypted), falling back
# to EnvStore so existing Settings-page installs keep working
# (AUTHORIZE_NET_LOGIN_ID / AUTHORIZE_NET_TRANSACTION_KEY /
# AUTHORIZE_NET_CLIENT_KEY, plus AUTHORIZE_NET_SANDBOX=1 for the test gateway).
class AuthorizeNetClient
  class Error < StandardError; end

  ENDPOINTS = {
    sandbox: 'https://apitest.authorize.net/xml/v1/request.api',
    production: 'https://api.authorize.net/xml/v1/request.api'
  }.freeze

  ACCEPT_JS_URLS = {
    sandbox: 'https://jstest.authorize.net/v1/Accept.js',
    production: 'https://js.authorize.net/v1/Accept.js'
  }.freeze

  # Accept.js card nonces and Apple Pay / Google Pay wallet tokens are the only payment
  # descriptors accepted; anything else from the browser is ignored.
  DATA_DESCRIPTORS = %w[COMMON.ACCEPT.INAPP.PAYMENT COMMON.APPLE.INAPP.PAYMENT COMMON.GOOGLE.INAPP.PAYMENT].freeze

  # Outcome of a transaction attempt.
  Result = Struct.new(:transaction_id, :auth_code, :response_code, :message, keyword_init: true) do
    def approved?
      response_code == '1'
    end
  end

  class << self
    def configured?
      login_id.present? && transaction_key.present?
    end

    def sandbox?
      connection = saved_connection
      return connection.environment == 'sandbox' if connection

      EnvStore.fetch('AUTHORIZE_NET_SANDBOX', '0') == '1'
    end

    def accept_js_url
      ACCEPT_JS_URLS[sandbox? ? :sandbox : :production]
    end

    # Capture the destination once before a durable payment attempt is made.
    # Never persist or log this hash; attempts retain only its SHA-256 digest.
    def credential_snapshot
      connection = saved_connection
      if connection
        credentials = connection.credential_values
        { sandbox: connection.environment == 'sandbox', login_id: credentials['api_login_id'].to_s,
          transaction_key: credentials['transaction_key'].to_s }
      else
        { sandbox: EnvStore.fetch('AUTHORIZE_NET_SANDBOX', '0') == '1', login_id: EnvStore.fetch('AUTHORIZE_NET_LOGIN_ID', ''),
          transaction_key: EnvStore.fetch('AUTHORIZE_NET_TRANSACTION_KEY', '') }
      end
    end

    # Charge a tokenized (Accept.js) payment. amount_cents is the total in the
    # merchant's minor currency (USD cents).
    def charge!(amount_cents:, payment_nonce:, data_descriptor: 'COMMON.ACCEPT.INAPP.PAYMENT',
                ref_id: nil, invoice_number: nil, description: nil, credential_snapshot: nil)
      credentials = credential_snapshot || self.credential_snapshot
      raise Error, 'Authorize.net is not configured' unless credentials[:login_id].present? && credentials[:transaction_key].present?

      data_descriptor = DATA_DESCRIPTORS.first unless DATA_DESCRIPTORS.include?(data_descriptor)
      transaction = {
        transactionType: 'authCaptureTransaction',
        amount: format('%.2f', amount_cents.to_i / 100.0),
        payment: {
          opaqueData: {
            dataDescriptor: data_descriptor,
            dataValue: payment_nonce
          }
        }
      }
      transaction[:order] = { invoiceNumber: invoice_number, description: description } if invoice_number || description

      payload = {
        createTransactionRequest: {
          merchantAuthentication: { name: credentials[:login_id], transactionKey: credentials[:transaction_key] },
          refId: ref_id,
          transactionRequest: transaction
        }
      }

      parse(post(payload, sandbox: credentials[:sandbox]))
    end

    # Cancel a charge that has not settled yet. Voids need only the original
    # transaction id; once the batch settles the gateway rejects it and the
    # caller must use refund! instead.
    def void!(transaction_id:, ref_id: nil)
      referenced_request!('voidTransaction', transaction_id: transaction_id, ref_id: ref_id)
    end

    # Return money for a settled charge. Authorize.net requires the last four
    # digits of the original card (never the full number) and the original id.
    def refund!(transaction_id:, amount_cents:, last_four:, ref_id: nil)
      raise Error, 'Last four digits are required for a refund' unless last_four.to_s.match?(/\A\d{4}\z/)

      referenced_request!('refundTransaction', transaction_id: transaction_id, ref_id: ref_id,
        amount: format('%.2f', amount_cents.to_i / 100.0),
        payment: { creditCard: { cardNumber: last_four.to_s, expirationDate: 'XXXX' } })
    end

    # Look up status and the card's last four so the caller can choose between
    # void (unsettled) and refund (settled), or recover from a lost response.
    def transaction_details(transaction_id)
      raise Error, 'Authorize.net is not configured' unless configured?

      doc = JSON.parse(post({ getTransactionDetailsRequest: {
        merchantAuthentication: authentication, transId: transaction_id.to_s
      } }).b.delete_prefix("\xEF\xBB\xBF".b).force_encoding(Encoding::UTF_8))
      raise Error, doc.dig('messages', 'message', 0, 'text').to_s if doc.dig('messages', 'resultCode') == 'Error'

      transaction = doc['transaction'] || {}
      { status: transaction['transactionStatus'],
        amount: transaction['authAmount'],
        last_four: transaction.dig('payment', 'creditCard', 'cardNumber').to_s.delete('X') }
    end

    # Credential accessors read the Valmar connection when it is set up for
    # Authorize.net, otherwise the legacy EnvStore settings.
    def login_id
      connection = saved_connection
      connection ? connection.credential_values['api_login_id'].to_s : EnvStore.fetch('AUTHORIZE_NET_LOGIN_ID', '')
    end

    def client_key
      connection = saved_connection
      connection ? connection.credential_values['client_key'].to_s : EnvStore.fetch('AUTHORIZE_NET_CLIENT_KEY', '')
    end

    def transaction_key
      connection = saved_connection
      connection ? connection.credential_values['transaction_key'].to_s : EnvStore.fetch('AUTHORIZE_NET_TRANSACTION_KEY', '')
    end

    private

    def saved_connection
      connection = PosConnection.find_by(provider: 'valmar')
      connection if connection&.gateway == 'authorize_net' && connection.credentials_saved?
    end

    def authentication
      { name: login_id, transactionKey: transaction_key }
    end

    def referenced_request!(type, transaction_id:, ref_id:, **extra)
      raise Error, 'Authorize.net is not configured' unless configured?
      raise Error, 'Transaction id is required' if transaction_id.blank?

      request = { transactionType: type }.merge(extra).merge(refTransId: transaction_id.to_s)
      parse(post({ createTransactionRequest: {
        merchantAuthentication: authentication, refId: ref_id, transactionRequest: request
      } }))
    end

    def post(payload, sandbox: nil)
      environment = sandbox.nil? ? sandbox? : sandbox
      uri = URI(ENDPOINTS[environment ? :sandbox : :production])
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 30

      request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json', 'Accept' => 'application/json')
      request.body = JSON.generate(payload)

      response = http.request(request)
      raise Error, "Authorize.net HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end

    def parse(body)
      doc = JSON.parse(body)
      transaction = doc['transactionResponse'] || {}
      gateway_error = doc.dig('messages', 'message', 0, 'text').to_s
      transaction_error = transaction.dig('messages', 'description').to_s
      message = transaction_error.presence || gateway_error.presence || 'Unknown Authorize.net response'

      Result.new(
        response_code: transaction['responseCode'],
        transaction_id: transaction['transId'],
        auth_code: transaction['authCode'],
        message: message
      )
    end
  end
end
