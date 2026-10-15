# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module PaymentProviders
  # Authorize.net's authenticateTestRequest verifies merchant API credentials
  # without creating a transaction, retrieving payments, or activating terminals.
  # Contract: developer.authorize.net/api/reference/index.html, authentication.
  class AuthorizeNetCheck
    ENDPOINTS = {
      'sandbox' => 'https://apitest.authorize.net/xml/v1/request.api',
      'production' => 'https://api.authorize.net/xml/v1/request.api'
    }.freeze
    API_LOGIN_ID_MAX_BYTES = 20
    TRANSACTION_KEY_MAX_BYTES = 16
    MAX_RESPONSE_BYTES = 64 * 1024
    MESSAGES = {
      invalid: 'Enter valid Authorize.net API credentials and choose sandbox or production.',
      unauthorized: 'Authorize.net did not verify the API credentials. Check the selected environment and API keys.',
      response: 'Authorize.net returned an unexpected response. No connection was verified.',
      network: 'Authorize.net could not be reached securely. Try the check again later.',
      verified: 'Authorize.net API credentials verified. Payment processing and terminals are not enabled.'
    }.freeze

    class CheckFailure < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(MESSAGES.fetch(reason))
      end
    end

    def self.call(credentials:, environment:)
      new(credentials, environment).call
    end

    def initialize(credentials, environment)
      @credentials = credentials
      @environment = environment
    end

    def call
      return outcome(:invalid) unless valid_credentials?

      # Authorize.net officially documents an optional leading UTF-8 BOM in its
      # JSON responses. Remove only that prefix; retain all other validation.
      body = read_response.b.delete_prefix("\xEF\xBB\xBF".b).force_encoding(Encoding::UTF_8)
      return outcome(:response) unless body.valid_encoding?

      document = JSON.parse(body, max_nesting: 20)
      return outcome(:response) unless document.is_a?(Hash) && document['messages'].is_a?(Hash)

      messages = document['messages']
      return outcome(:unauthorized) if messages['resultCode'] == 'Error'
      return outcome(:response) unless verified_messages?(messages)

      outcome(:verified)
    rescue CheckFailure => e
      outcome(e.reason)
    rescue JSON::ParserError, EncodingError
      outcome(:response)
    rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError,
           Net::HTTPBadResponse, Net::ProtocolError
      outcome(:network)
    end

    private

    def valid_credentials?
      @credentials.is_a?(Hash) && ENDPOINTS.key?(@environment) &&
        valid_secret?(@credentials['api_login_id'], API_LOGIN_ID_MAX_BYTES) &&
        valid_secret?(@credentials['transaction_key'], TRANSACTION_KEY_MAX_BYTES)
    end

    def valid_secret?(value, maximum)
      value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, maximum) &&
        !value.strip.empty? && !value.match?(/[\x00-\x1f\x7f]/)
    end

    def read_response
      uri = URI(ENDPOINTS.fetch(@environment))
      request = Net::HTTP::Post.new(uri.request_uri,
        'Content-Type' => 'application/json', 'Accept' => 'application/json', 'Accept-Encoding' => 'identity')
      # Preserve the documented merchantAuthentication field order for the
      # gateway's JSON-to-XML translation. No financial request is permitted.
      request.body = JSON.generate(authenticateTestRequest: {
        merchantAuthentication: {
          name: @credentials.fetch('api_login_id'), transactionKey: @credentials.fetch('transaction_key')
        }
      })

      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 3
      http.read_timeout = 5
      http.write_timeout = 5
      http.max_retries = 0
      body = +''
      http.start do |client|
        client.request(request) do |response|
          raise CheckFailure, :unauthorized if ['401', '403'].include?(response.code)
          raise CheckFailure, :response unless response.code == '200'

          length = response['Content-Length']
          raise CheckFailure, :response if length&.match?(/\A[0-9]+\z/) && length.to_i > MAX_RESPONSE_BYTES

          response.read_body do |chunk|
            raise CheckFailure, :response if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES

            body << chunk
          end
        end
      end
      body
    end

    def verified_messages?(messages)
      entries = messages['message']
      messages['resultCode'] == 'Ok' && entries.is_a?(Array) && entries.any? &&
        entries.all? { |entry| entry.is_a?(Hash) && entry['code'] == 'I00001' }
    end

    def outcome(reason)
      { status: reason == :verified ? 'verified' : 'failed', message: MESSAGES.fetch(reason) }
    end
  end
end
