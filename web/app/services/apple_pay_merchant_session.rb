# frozen_string_literal: true

require 'net/http'
require 'json'
require 'openssl'

# Apple Pay on the web requires the merchant's server to validate the session
# with Apple, authenticating with the Merchant Identity Certificate. Rupert
# relays Apple's response to the browser; the card token itself is later sent to
# Authorize.net (COMMON.APPLE.INAPP.PAYMENT), which holds the Payment Processing
# certificate. Credentials live in EnvStore (Settings -> Apple Pay).
class ApplePayMerchantSession
  class Error < StandardError; end

  MAX_RESPONSE_BYTES = 64 * 1024

  class << self
    def configured?
      %w[APPLE_PAY_MERCHANT_ID APPLE_PAY_IDENTITY_CERT APPLE_PAY_IDENTITY_KEY].all? do |key|
        EnvStore.fetch(key, '').present?
      end
    end

    def display_name(default)
      EnvStore.fetch('APPLE_PAY_DISPLAY_NAME', '').presence || default
    end

    # Apple only validates against its own hosts; refusing everything else keeps
    # this endpoint from becoming a server-side request forger.
    def valid_validation_url?(value)
      uri = URI.parse(value.to_s)
      uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? &&
        (uri.host.to_s == 'apple.com' || uri.host.to_s.end_with?('.apple.com'))
    rescue URI::InvalidURIError
      false
    end

    # Returns Apple's merchant session JSON string.
    def call(validation_url:, domain:, default_name:)
      raise Error, 'Apple Pay is not configured' unless configured?
      raise Error, 'Invalid Apple Pay validation URL' unless valid_validation_url?(validation_url)

      uri = URI.parse(validation_url)
      request = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
      request.body = JSON.generate(
        merchantIdentifier: EnvStore.fetch('APPLE_PAY_MERCHANT_ID'),
        displayName: display_name(default_name),
        initiative: 'web',
        initiativeContext: domain
      )

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.cert = OpenSSL::X509::Certificate.new(EnvStore.fetch('APPLE_PAY_IDENTITY_CERT'))
      http.key = OpenSSL::PKey.read(EnvStore.fetch('APPLE_PAY_IDENTITY_KEY'))
      http.open_timeout = 5
      http.read_timeout = 10

      response = http.request(request)
      raise Error, "Apple Pay validation failed (HTTP #{response.code})" unless response.is_a?(Net::HTTPSuccess)
      raise Error, 'Unexpected Apple Pay response' if response.body.to_s.bytesize > MAX_RESPONSE_BYTES

      JSON.parse(response.body)
      response.body
    rescue OpenSSL::OpenSSLError, JSON::ParserError, SystemCallError, SocketError, Timeout::Error, IOError => e
      raise Error, "Apple Pay validation could not complete (#{e.class})"
    end
  end
end
