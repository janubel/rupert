# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module PaymentProviders
  # Checks dedicated API-user access to one organizational-unit page. This does
  # not verify payment processing, terminal compatibility, or write permissions.
  # Contract: COMBASE/cloud-api-v3-js-client docs/OrganizationalUnitsApi.md and
  # docs/ResultListOrganizationalUnit.md (KORONA.cloud API v3, HTTP Basic auth).
  class KoronaCheck
    API_URL_PATTERN = %r{\Ahttps://(?:www|[0-9]+)\.koronacloud\.com/web/api/v3\z}
    ACCOUNT_ID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    MAX_RESPONSE_BYTES = 64 * 1024
    MESSAGES = {
      invalid: 'Enter a valid KORONA API endpoint, account UUID, and dedicated API-user credentials.',
      unauthorized: 'KORONA rejected the API credentials. Check the dedicated API user and password.',
      forbidden: 'KORONA denied organizational-unit read access. Check the API user permissions.',
      response: 'KORONA returned an unexpected response. No connection was verified.',
      network: 'KORONA could not be reached securely. Try the check again later.',
      verified: 'KORONA organizational-unit read access verified. Payments and terminals are not enabled.'
    }.freeze

    class CheckFailure < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(MESSAGES.fetch(reason))
      end
    end

    def self.call(credentials:)
      new(credentials).call
    end

    def initialize(credentials)
      @credentials = credentials
    end

    def call
      return outcome(:invalid) unless valid_credentials?

      document = JSON.parse(read_page, max_nesting: 20)
      return outcome(:response) unless valid_page?(document)

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
      return false unless @credentials.is_a?(Hash)

      url = @credentials['api_url']
      account = @credentials['account_id']
      url.is_a?(String) && url.valid_encoding? && url.bytesize <= 2048 && API_URL_PATTERN.match?(url) &&
        account.is_a?(String) && account.valid_encoding? && ACCOUNT_ID_PATTERN.match?(account) &&
        valid_secret?(@credentials['api_username'], 512, username: true) &&
        valid_secret?(@credentials['api_password'], 4096)
    end

    def valid_secret?(value, maximum, username: false)
      value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, maximum) &&
        !value.strip.empty? && !value.match?(/[\x00-\x1f\x7f]/) && !(username && value.include?(':'))
    end

    def read_page
      uri = URI("#{@credentials.fetch('api_url')}/accounts/#{@credentials.fetch('account_id')}/organizationalUnits")
      uri.query = URI.encode_www_form(page: 1, size: 1)
      request = Net::HTTP::Get.new(uri.request_uri,
        'Accept' => 'application/json', 'Accept-Encoding' => 'identity')
      request.basic_auth(@credentials.fetch('api_username'), @credentials.fetch('api_password'))

      # Ignore proxy environment variables: credentials go only to this validated
      # KORONA HTTPS endpoint. Net::HTTP does not follow redirects.
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
          # The documented 204 response represents an empty authorized collection.
          if response.code == '204'
            body = { currentPage: 1, results: [], resultsOfPage: 0, resultsTotal: 0 }.to_json
            next
          end
          validate_status!(response)
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

    def validate_status!(response)
      case response.code
      when '200' then nil
      when '401' then raise CheckFailure, :unauthorized
      when '403' then raise CheckFailure, :forbidden
      else raise CheckFailure, :response
      end
    end

    def valid_page?(document)
      return false unless document.is_a?(Hash) && document['currentPage'] == 1

      results = document['results']
      total = document['resultsTotal']
      results.is_a?(Array) && results.length <= 1 && results.all? { |item| item.is_a?(Hash) } &&
        document['resultsOfPage'] == results.length && total.is_a?(Integer) && total >= results.length
    end

    def outcome(reason)
      { status: reason == :verified ? 'verified' : 'failed', message: MESSAGES.fetch(reason) }
    end
  end
end
