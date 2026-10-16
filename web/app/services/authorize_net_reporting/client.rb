# frozen_string_literal: true

require 'json'
require 'bigdecimal'
require 'net/http'
require 'openssl'

module AuthorizeNetReporting
  # Deliberately independent of AuthorizeNetClient, which can charge payments.
  class Client
    class Error < StandardError
      attr_reader :reason

      def initialize(message, reason: nil)
        @reason = reason
        super(message)
      end
    end
    ENDPOINTS = PaymentProviders::AuthorizeNetCheck::ENDPOINTS
    TOKEN_ENDPOINTS = {
      'sandbox' => 'https://accesstest.authorize.net/oauth/v1/token',
      'production' => 'https://access.authorize.net/oauth/v1/token'
    }.freeze
    READ_METHODS = %w[getMerchantDetailsRequest getSettledBatchListRequest getTransactionListRequest
      getUnsettledTransactionListRequest getTransactionDetailsRequest].freeze
    ACCESS_ERRORS = {
      'E00007' => 'Reporting authentication was rejected. Check the environment and integration credentials.',
      'E00011' => 'Reporting access is denied. Check Transaction Details API availability and account permissions in the merchant portal.',
      'E00123' => 'The reporting OAuth access token expired. Retry reporting to refresh access.',
      'E00124' => 'The reporting OAuth access token is invalid. Check the approved application access.'
    }.freeze
    MAX_BYTES = 8 * 1024 * 1024
    PAGE_SIZE = 1000
    MAX_PAGES = 100

    def initialize(connection)
      raise Error, 'Reporting connection belongs to another workspace.' unless connection.tenant_id == Current.tenant_id && connection.provider == 'authorize_net_reporting'
      @connection = connection
      @environment = connection.environment
      @credentials = connection.credential_values
      @version = connection.lock_version
      raise Error.new('Save approved reporting credentials and a valid environment first.', reason: :invalid) unless
        ENDPOINTS.key?(@environment) && connection.vendor_approved && connection.credentials_saved?
    end

    def merchant
      doc = request('getMerchantDetailsRequest')
      id!(doc['gatewayId'])
      raise Error.new('Gateway ID does not match the configured merchant reference.', reason: :identity) unless doc['gatewayId'].to_s == @connection.account_reference
      doc
    end

    def batches(from:, to:)
      raise Error, 'Choose an ordered reporting window of at most 31 days.' unless from < to && (to - from) <= 31.days
      doc = request('getSettledBatchListRequest', includeStatistics: true,
        firstSettlementDate: from.utc.iso8601, lastSettlementDate: to.utc.iso8601)
      list!(doc['batchList']).each { |batch| id!(batch['batchId']) }
    end

    def transactions(batch_id: nil)
      method = batch_id ? 'getTransactionListRequest' : 'getUnsettledTransactionListRequest'
      fields = batch_id ? { batchId: id!(batch_id) } : {}
      seen = {}
      total = nil
      (1..MAX_PAGES).each do |page|
        doc = request(method, **fields, sorting: { orderBy: 'id', orderDescending: false },
          paging: { limit: PAGE_SIZE, offset: page })
        rows = list!(doc['transactions'])
        if page == 1
          value = doc['totalNumInResultSet']
          raise Error.new('Reporting returned an invalid result count.', reason: :response) unless value.to_s.match?(/\A[0-9]+\z/)
          total = value.to_i
        end
        rows.each do |row|
          id = id!(row['transId'])
          raise Error.new('Reporting pages changed or repeated; retry reconciliation.', reason: :response) if seen.key?(id)
          seen[id] = row
        end
        if rows.size < PAGE_SIZE
          raise Error.new('Reporting pages were incomplete; retry reconciliation.', reason: :response) unless seen.size == total
          return seen.values
        end
        return seen.values if seen.size == total
      end
      raise Error.new('Reporting exceeded the page limit. No import was completed.', reason: :limit)
    end

    def detail(id)
      doc = request('getTransactionDetailsRequest', transId: id!(id))
      row = doc['transaction']
      raise Error.new('Reporting returned mismatched transaction details.', reason: :response) unless row.is_a?(Hash) && row['transId'].to_s == id.to_s
      row
    end

    def request(method, **fields)
      raise Error, 'Only reporting API methods are permitted.' unless READ_METHODS.include?(method)
      raise Error, 'Authentication overrides are not permitted.' if fields.keys.any? { |key| key.to_s == 'merchantAuthentication' }
      payload = { method => { merchantAuthentication: authentication }.merge(fields) }
      doc = decode(exchange(ENDPOINTS.fetch(@environment), JSON.generate(payload)))
      messages = doc['messages']
      entries = messages.is_a?(Hash) ? messages['message'] : nil
      if messages.is_a?(Hash) && messages['resultCode'] == 'Error' && entries.is_a?(Array)
        code = entries.filter_map { |entry| entry['code'] if entry.is_a?(Hash) }.find { |value| ACCESS_ERRORS.key?(value) }
        raise Error.new(ACCESS_ERRORS.fetch(code), reason: code == 'E00011' ? :forbidden : :unauthorized) if code
      end
      unless messages.is_a?(Hash) && messages['resultCode'] == 'Ok' && entries.is_a?(Array) && entries.any? &&
          entries.all? { |m| m.is_a?(Hash) && %w[I00001 I00004].include?(m['code']) }
        raise Error, 'Reporting access was not verified. Check environment, permissions and credential expiry.'
      end
      doc
    end

    private

    def id!(value)
      raise Error.new('Reporting returned an invalid source ID.', reason: :response) unless value.to_s.match?(/\A[0-9]{1,30}\z/) && value.to_i.positive?
      value.to_s
    end

    def list!(value)
      return [] if value.nil?
      raise Error.new('Reporting returned an invalid list.', reason: :response) unless value.is_a?(Array) && value.all? { |v| v.is_a?(Hash) }
      value
    end

    def authentication
      return @authentication if @authentication
      if @connection.reporting_auth_mode == 'oauth'
        form = URI.encode_www_form(grant_type: 'refresh_token', client_id: @credentials.fetch('client_id'),
          client_secret: @credentials.fetch('client_secret'), refresh_token: @credentials.fetch('refresh_token'))
        token = decode(exchange(TOKEN_ENDPOINTS.fetch(@environment), form, content_type: 'application/x-www-form-urlencoded'))
        # The token endpoint is authoritative for granted scopes; do not decode an unverified JWT.
        raise Error.new('OAuth must grant exactly the read scope.', reason: :forbidden) unless token['scope'].to_s.split == ['read']
        raise Error.new('OAuth did not return a usable access token.', reason: :unauthorized) unless token['access_token'].is_a?(String) && token['access_token'].present?
        # Authorize.net documents refresh-token renewal. Save rotation encrypted,
        # guarded against an operator changing/removing credentials in flight.
        if token['refresh_token'].present? && token['refresh_token'] != @credentials['refresh_token']
          fresh = PosConnection.find(@connection.id)
          fresh.with_lock do
            raise Error.new('Reporting setup changed; retry with the current credentials.', reason: :changed) unless fresh.lock_version == @version && fresh.credential_values == @credentials
            @credentials = @credentials.merge('refresh_token' => token.fetch('refresh_token'))
            fresh.update!(credentials_json: JSON.generate(@credentials))
            @connection.reload
            @version = @connection.lock_version
          end
        end
        @authentication = { accessToken: token.fetch('access_token') }
      elsif @connection.reporting_auth_mode == 'api_key'
        @authentication = { name: @credentials.fetch('api_login_id'), transactionKey: @credentials.fetch('transaction_key') }
      else
        raise Error, 'Choose a supported reporting authentication method.'
      end
    end

    def decode(body)
      body = body.b.delete_prefix("\xEF\xBB\xBF".b).force_encoding(Encoding::UTF_8)
      raise Error.new('Reporting returned an invalid response.', reason: :response) unless body.valid_encoding?
      doc = JSON.parse(body, max_nesting: 40, decimal_class: BigDecimal)
      raise Error.new('Reporting returned an invalid response.', reason: :response) unless doc.is_a?(Hash)
      doc
    rescue JSON::ParserError, EncodingError
      raise Error.new('Reporting returned an invalid response.', reason: :response)
    end

    def exchange(url, body, content_type: 'application/json')
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 3
      http.read_timeout = 15
      http.write_timeout = 5
      http.max_retries = 0
      req = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => content_type,
        'Accept' => 'application/json', 'Accept-Encoding' => 'identity')
      req.body = body
      output = +''
      http.start do |session|
        session.request(req) do |res|
          if res.code != '200'
            reason = SyncFailure.http_reason(res.code)
            raise Error.new('Reporting request failed. Check access and try again.', reason: reason)
          end
          raise Error.new('Reporting response exceeded the size limit.', reason: :limit) if res['Content-Length'].to_i > MAX_BYTES
          res.read_body do |chunk|
            raise Error.new('Reporting response exceeded the size limit.', reason: :limit) if output.bytesize + chunk.bytesize > MAX_BYTES
            output << chunk
          end
        end
      end
      output
    rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError,
        Net::HTTPBadResponse, Net::ProtocolError
      raise Error.new('Authorize.net reporting could not be reached securely. Try again later.', reason: :network)
    end
  end
end
