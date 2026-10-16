# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module IrisReporting
  # NAB's published OpenAPI 1.42.0. Only GET report endpoints are exposed.
  class Client
    ORIGIN_PATTERN = %r{\Ahttps://[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.iriscrm\.com\z}
    KINDS = %w[transactions chargebacks retrievals statements].freeze
    MAX_BYTES = 4 * 1024 * 1024
    MAX_TOTAL_BYTES = 32 * 1024 * 1024
    MAX_PAGES = 100
    MAX_ROWS = 10_000
    MESSAGES = {
      invalid: 'Enter an HTTPS IRIS tenant origin, approved API token and numeric merchant IDs.',
      unauthorized: 'IRIS rejected the API token. A merchant portal password is not an API token.',
      forbidden: 'IRIS denied this report. Ask NAB for merchant reporting API permissions.',
      unavailable: 'This IRIS report is unavailable for the selected merchant or processor.',
      rate_limit: 'IRIS rate limit reached. Retry later; the previous reports were retained.',
      response: 'IRIS returned incomplete or unexpected report data. Previous reports were retained.',
      network: 'IRIS could not be reached securely. Previous reports were retained.',
      limit: 'IRIS reporting exceeded its size or time limit. Choose a smaller date range.',
      stale: 'IRIS setup changed during import. Retry with the current configuration.'
    }.freeze

    class Error < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(MESSAGES.fetch(reason))
      end
    end

    def self.valid_credentials?(values)
      values.is_a?(Hash) && values['api_url'].is_a?(String) && values['api_url'].valid_encoding? && ORIGIN_PATTERN.match?(values['api_url']) &&
        values['api_token'].is_a?(String) && values['api_token'].valid_encoding? && values['api_token'].bytesize.between?(1, 4096) &&
        !values['api_token'].match?(/[\x00-\x20\x7f]/)
    end

    def self.merchants(reference)
      ids = reference.to_s.split(',').map(&:strip)
      raise Error, :invalid unless ids.size.between?(1, 10) && ids.uniq == ids && ids.all? { |id| id.match?(/\A[0-9]{1,30}\z/) }

      ids
    end

    def initialize(credentials)
      raise Error, :invalid unless self.class.valid_credentials?(credentials)

      @origin = credentials.fetch('api_url')
      @token = credentials.fetch('api_token')
      @bytes_read = 0
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120
    end

    def report(kind, merchant:, from:, to:)
      raise Error, :invalid unless merchant.is_a?(String) && merchant.match?(/\A[0-9]{1,30}\z/) &&
        from.is_a?(Date) && to.is_a?(Date) && from <= to && (to - from).to_i <= 89

      if kind == 'deposits'
        document = request("/merchants/#{merchant}/deposits/#{from.year}/#{from.month}/#{from.day}", end_date: to.iso8601)
        raise Error, :response unless %w[deposits adjustments].all? { |key| valid_rows?(document[key]) } && document['totals'].is_a?(Hash)

        return document.slice('deposits', 'adjustments', 'totals')
      end
      raise Error, :invalid unless KINDS.include?(kind)

      rows = []
      expected_total = nil
      last = nil
      (1..MAX_PAGES).each do |page|
        params = { page: page, per_page: 100 }
        params.merge!(start_date: from.iso8601, end_date: to.iso8601) unless kind == 'statements'
        document = request("/merchants/#{merchant}/#{kind}", params)
        data = document['data']
        meta = document['meta']
        # Statements' published schema omits collection pagination metadata;
        # fail closed if that processor cannot return complete metadata.
        raise Error, :response unless valid_rows?(data) && data.size <= 100 && meta.is_a?(Hash)

        total = Integer(meta.fetch('total').to_s, 10)
        current_last = Integer(meta.fetch('last_page').to_s, 10)
        current = Integer(meta.fetch('current_page').to_s, 10)
        raise Error, :response unless total.between?(0, MAX_ROWS) && current_last.between?(1, MAX_PAGES) && current == page

        expected_total ||= total
        last ||= current_last
        raise Error, :response unless expected_total == total && last == current_last && page <= last

        rows.concat(data)
        next unless page == last

        ids = rows.map { |row| row['id'].to_s }
        raise Error, :response unless rows.size == total && ids.uniq.size == ids.size && ids.all? { |id| id.match?(/\A[0-9]{1,30}\z/) }

        return { 'data' => rows }
      end
      raise Error, :limit
    rescue ArgumentError, TypeError, KeyError
      raise Error, :response
    end

    private

    def valid_rows?(rows)
      rows.is_a?(Array) && rows.size <= MAX_ROWS && rows.all? { |row| row.is_a?(Hash) }
    end

    def request(path, params)
      remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Error, :limit if remaining <= 0

      uri = URI("#{@origin}/api/v1#{path}")
      uri.query = URI.encode_www_form(params)
      req = Net::HTTP::Get.new(uri.request_uri, 'Accept' => 'application/json', 'Accept-Encoding' => 'identity', 'X-API-KEY' => @token)
      http = Net::HTTP.new(uri.host, 443, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = [5, remaining].min
      http.read_timeout = [10, remaining].min
      http.write_timeout = [5, remaining].min
      http.max_retries = 0
      body = +''
      http.start do |session|
        session.request(req) do |response|
          reason = { '401' => :unauthorized, '403' => :forbidden, '404' => :unavailable, '429' => :rate_limit }[response.code]
          raise Error, reason if reason
          raise Error, :response unless response.code == '200' && response['Content-Type'].to_s.include?('application/json')
          raise Error, :limit if response['Content-Length'].to_i > MAX_BYTES

          response.read_body do |chunk|
            @bytes_read += chunk.bytesize
            raise Error, :limit if body.bytesize + chunk.bytesize > MAX_BYTES || @bytes_read > MAX_TOTAL_BYTES || Process.clock_gettime(Process::CLOCK_MONOTONIC) > @deadline

            body << chunk
          end
        end
      end
      document = JSON.parse(body, max_nesting: 30)
      raise Error, :response unless document.is_a?(Hash)

      document
    rescue JSON::ParserError, EncodingError, TypeError
      raise Error, :response
    rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
      raise Error, :network
    end
  end
end
