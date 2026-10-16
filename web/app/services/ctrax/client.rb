# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module Ctrax
  # Observed Serv 2.0 admin contract, not a published partner API. All business
  # requests are GETs. A fresh login token lives only in this client instance.
  class Client
    API_URL_PATTERN = %r{\Ahttps://[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.api\.cannatrax\.net\z}
    MAX_BYTES = 2 * 1024 * 1024
    MAX_TOTAL_BYTES = 32 * 1024 * 1024
    MAX_PAGES = 200
    MAX_ROWS = 20_000
    MESSAGES = {
      invalid: 'Enter the C-Trax HTTPS API origin and C-Trax user credentials. TRX merchant credentials do not authenticate the stock API.',
      unauthorized: 'C-Trax rejected the login or the session expired. Check the C-Trax user credentials.',
      forbidden: 'C-Trax denied read access. Check this user’s store and report permissions.',
      response: 'C-Trax returned an unexpected or incomplete response. The previous stock snapshot was retained.',
      network: 'C-Trax could not be reached securely. The previous stock snapshot was retained.',
      limit: 'The C-Trax read exceeded its size or time limit. The previous stock snapshot was retained.'
    }.freeze

    class Error < StandardError
      def initialize(reason)
        super(MESSAGES.fetch(reason))
      end
    end

    def self.valid_credentials?(credentials)
      credentials.is_a?(Hash) && credentials['api_url'].is_a?(String) && credentials['api_url'].valid_encoding? &&
        API_URL_PATTERN.match?(credentials['api_url']) &&
        %w[api_username api_password].all? do |key|
          value = credentials[key]
          value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, 4096) &&
            value.strip.present? && !value.match?(/[\x00-\x1f\x7f]/)
        end
    end

    def initialize(credentials)
      raise Error, :invalid unless self.class.valid_credentials?(credentials)

      @credentials = credentials
      @bytes_read = 0
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 90
    end

    def stores
      return @stores if @stores

      document = request('/api/auth/login', login: true)
      token = document['token']
      accessible = document['permissions'].is_a?(Hash) ? document['permissions']['accessible_stores'] : nil
      unless token.is_a?(String) && token.bytesize.between?(1, 16_384) && !token.match?(/[\x00-\x20\x7f]/) &&
             accessible.is_a?(Hash) && accessible.size.between?(1, 20)
        raise Error, :response
      end

      @token = token
      flags = document['feature_flags']
      @master_products = flags.is_a?(Array) && flags.any? { |flag| flag.is_a?(Hash) && flag['name'] == 'FLAG_MASTER_PRODUCT_LIST' }
      @stores = accessible.map do |id, name|
        raise Error, :response unless id.match?(/\A[1-9][0-9]{0,18}\z/) && name.is_a?(String) && name.bytesize <= 500

        { id: id, name: name }
      end
    end

    def master_products?
      stores
      @master_products
    end

    def stock(store_id)
      authorize_store!(store_id)
      rows = []
      total = nil
      last = nil
      (1..MAX_PAGES).each do |page|
        document = request("/api/v1/stores/#{store_id}/productVariants", params: { page: page, per_page: 100 })
        data = document['data']
        current_total = document['total']
        current_last = document['last_page']
        unless data.is_a?(Array) && data.size <= 100 && data.all? { |row| row.is_a?(Hash) } &&
               document['current_page'] == page && current_total.is_a?(Integer) && current_total.between?(0,
                 MAX_ROWS) &&
               current_last.is_a?(Integer) && current_last.between?(1, MAX_PAGES)
          raise Error, :response
        end

        total ||= current_total
        last ||= current_last
        raise Error, :response unless total == current_total && last == current_last && page <= last

        rows.concat(data)
        raise Error, :limit if rows.size > MAX_ROWS
        next unless page == last

        ids = rows.map { |row| row['id'].to_s }
        unless rows.size == total && ids.uniq.size == ids.size && ids.all? { |id| id.match?(/\A[1-9][0-9]{0,18}\z/) }
          raise Error, :response
        end

        return rows
      end
      raise Error, :limit
    end

    # This endpoint may contain merchant secrets. Return counts only; never
    # persist, log or render the raw merchant response.
    def merchant_summary(store_id)
      authorize_store!(store_id)
      document = request("/api/v1/stores/#{store_id}/paymentVendors/trx/connectionStatus")
      raise Error, :response unless %w[production sandbox].all? { |key| document[key].is_a?(Array) }

      { production: document['production'].size, sandbox: document['sandbox'].size }
    end

    private

    def authorize_store!(id)
      raise Error, :forbidden unless stores.any? { |store| store[:id] == id.to_s }
    end

    def request(path, params: {}, login: false)
      remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Error, :limit if remaining <= 0

      uri = URI(@credentials.fetch('api_url') + path)
      uri.query = URI.encode_www_form(params) if params.any?
      headers = { 'Accept' => 'application/json', 'Accept-Encoding' => 'identity' }
      headers['Authorization'] = "Bearer #{@token}" unless login
      request = login ? Net::HTTP::Post.new(uri.request_uri, headers) : Net::HTTP::Get.new(uri.request_uri, headers)
      if login
        request['Content-Type'] = 'application/json'
        request.body = { username: @credentials.fetch('api_username'),
                         password: @credentials.fetch('api_password') }.to_json
      end
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = [3, remaining].min
      http.read_timeout = [5, remaining].min
      http.write_timeout = [5, remaining].min
      http.max_retries = 0
      body = +''
      http.start do |client|
        client.request(request) do |response|
          raise Error, :unauthorized if response.code == '401'
          raise Error, :forbidden if response.code == '403'
          unless response.code == '200' && response['Content-Type'].to_s.include?('application/json')
            raise Error,
              :response
          end
          raise Error, :limit if response['Content-Length'].to_i > MAX_BYTES

          response.read_body do |chunk|
            @bytes_read += chunk.bytesize
            if body.bytesize + chunk.bytesize > MAX_BYTES || @bytes_read > MAX_TOTAL_BYTES || Process.clock_gettime(Process::CLOCK_MONOTONIC) > @deadline
              raise Error,
                :limit
            end

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
