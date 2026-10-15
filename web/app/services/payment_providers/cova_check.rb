# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module PaymentProviders
  # Cova partner-onboarding API credentials only, never a merchant browser login.
  # Official contracts: api.covasoft.net/Documentation/Api/POST-v1-oauth2-token
  # and GET-v1-Companies(CompanyId)-Locations. A short-lived bearer token is used
  # only for this permission check and is neither returned nor persisted.
  class CovaCheck
    TOKEN_URL = 'https://accounts.iqmetrix.net/v1/oauth2/token'
    LOCATIONS_BASE_URL = 'https://api.covasoft.net/entitymanager/v1'
    MAX_RESPONSE_BYTES = 64 * 1024
    MESSAGES = {
      invalid: 'Enter the company ID and dedicated API credentials from the Cova onboarding package.',
      unauthorized: 'Cova rejected the API credentials. Check the dedicated onboarding credentials.',
      forbidden: 'Cova denied company-location read access. Check the approved API permissions.',
      response: 'Cova returned an unexpected response. No connection was verified.',
      network: 'Cova could not be reached securely. Try the check again later.',
      verified: 'Cova company-location read access verified. Payments and terminals are not enabled.'
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

      token = access_token
      uri = URI("#{LOCATIONS_BASE_URL}/Companies(#{@credentials.fetch('company_id')})/Locations")
      request = Net::HTTP::Get.new(uri.request_uri, 'Authorization' => "Bearer #{token}",
        'Accept' => 'application/json', 'Accept-Encoding' => 'identity')
      locations = JSON.parse(read_response(uri, request), max_nesting: 20)
      return outcome(:response) unless valid_locations?(locations)

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

      company_id = @credentials['company_id']
      company_id.is_a?(String) && company_id.valid_encoding? &&
        company_id.match?(/\A[1-9][0-9]{0,9}\z/) && company_id.to_i <= 2_147_483_647 &&
        ['client_id', 'client_secret', 'api_username', 'api_password'].all? do |key|
          valid_secret?(@credentials[key])
        end
    end

    def valid_secret?(value)
      value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, 4096) &&
        !value.strip.empty? && !value.match?(/[\x00-\x1f\x7f]/)
    end

    def access_token
      uri = URI(TOKEN_URL)
      request = Net::HTTP::Post.new(uri.request_uri,
        'Accept' => 'application/json', 'Accept-Encoding' => 'identity')
      request.set_form_data(
        grant_type: 'password', username: @credentials.fetch('api_username'),
        password: @credentials.fetch('api_password'), client_id: @credentials.fetch('client_id'),
        client_secret: @credentials.fetch('client_secret')
      )
      document = JSON.parse(read_response(uri, request, authentication: true), max_nesting: 20)
      token = document['access_token'] if document.is_a?(Hash)
      unless token.is_a?(String) && token.bytesize.between?(1, 8192) &&
          token.match?(/\A[A-Za-z0-9\-._~+\/]+=*\z/)
        raise CheckFailure, :response
      end

      token
    end

    def read_response(uri, request, authentication: false)
      # Fixed vendor hosts, verified TLS, no environment proxy, no redirects or
      # retries. Provider bodies and exceptions are never logged or returned.
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
          validate_status!(response, authentication: authentication)
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

    def validate_status!(response, authentication:)
      case response.code
      when '200' then nil
      when '401' then raise CheckFailure, :unauthorized
      when '403' then raise CheckFailure, :forbidden
      when '400' then raise CheckFailure, authentication ? :unauthorized : :response
      else raise CheckFailure, :response
      end
    end

    def valid_locations?(locations)
      locations.is_a?(Array) && locations.all? do |location|
        location.is_a?(Hash) && location['Id'].is_a?(Integer) && location['Id'].positive?
      end
    end

    def outcome(reason)
      { status: reason == :verified ? 'verified' : 'failed', message: MESSAGES.fetch(reason) }
    end
  end
end
