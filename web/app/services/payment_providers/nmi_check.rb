# frozen_string_literal: true

require 'net/http'
require 'nokogiri'
require 'openssl'
require 'uri'

module PaymentProviders
  # Fixed NMI Query API profile request only. A merchant security key can allow
  # other operations; this adapter never submits payment or validation requests.
  # Official contracts: docs.nmi.com/reference/query and
  # docs.nmi.com/docs/terminal-management. No profile/contact data is retained.
  class NmiCheck
    ENDPOINTS = {
      'sandbox' => 'https://sandbox.nmi.com/api/query.php',
      'production' => 'https://secure.nmi.com/api/query.php'
    }.freeze
    SECURITY_KEY_MAX_BYTES = 4096
    MAX_RESPONSE_BYTES = 64 * 1024
    MESSAGES = {
      invalid: 'Enter a valid NMI merchant API security key and choose sandbox or production.',
      unauthorized: 'NMI did not verify the API credentials. Check the selected environment and API key.',
      response: 'NMI did not return the expected merchant profile. No connection was verified.',
      network: 'NMI could not be reached securely. Try the check again later.',
      verified: 'NMI merchant-profile read access verified. Payment processing and terminals are not enabled.'
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
      return outcome(:response) unless verified_profile?(read_response)

      outcome(:verified)
    rescue CheckFailure => e
      outcome(e.reason)
    rescue Nokogiri::XML::SyntaxError, EncodingError
      outcome(:response)
    rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError,
           Net::HTTPBadResponse, Net::ProtocolError
      outcome(:network)
    end

    private

    def valid_credentials?
      return false unless @credentials.is_a?(Hash) && ENDPOINTS.key?(@environment)

      key = @credentials['security_key']
      key.is_a?(String) && key.valid_encoding? && key.bytesize.between?(1, SECURITY_KEY_MAX_BYTES) &&
        !key.strip.empty? && !key.match?(/[\x00-\x1f\x7f]/)
    end

    def read_response
      uri = URI(ENDPOINTS.fetch(@environment))
      request = Net::HTTP::Post.new(uri.request_uri,
        'Accept' => 'application/xml', 'Accept-Encoding' => 'identity')
      # Explicit profile report prevents the Query API's default transaction
      # report. Never add processor/key creation or card-validation parameters.
      request.set_form_data(security_key: @credentials.fetch('security_key'), report_type: 'profile')

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

    def verified_profile?(body)
      body = body.b.force_encoding(Encoding::UTF_8)
      return false unless body.valid_encoding?
      return false if body.include?("\x00") || body.match?(/<!\s*(?:DOCTYPE|ENTITY)\b/i)

      # Explicit UTF-8, strict parsing, and NONET prevent recovery or external
      # resolution. Entity substitution and XInclude are never enabled.
      document = Nokogiri::XML(body, nil, 'UTF-8') { |config| config.strict.nonet }
      root = document.root
      return false if document.internal_subset || document.external_subset
      return false unless root&.name == 'nm_response' && root.namespace.nil?
      return false if root.xpath('.//transaction | .//error | .//error_response | .//response_text | .//response_code').any?

      merchants = root.xpath('./merchant')
      return false unless merchants.one?

      companies = merchants.first.xpath('./company')
      companies.one? && companies.first.element_children.empty? && !companies.first.text.strip.empty?
    end

    def outcome(reason)
      { status: reason == :verified ? 'verified' : 'failed', message: MESSAGES.fetch(reason) }
    end
  end
end
