# frozen_string_literal: true

require 'net/http'

# Port of the legacy Shopify client (legacy/local-console.mjs) — client
# credentials token exchange plus Admin GraphQL, used by the sync engine.
class ShopifyClient
  class Error < StandardError
    attr_reader :reason

    def initialize(message, reason: nil)
      @reason = reason
      super(message)
    end
  end

  API_VERSION = '2026-07'
  TOKEN_TTL = 10 * 60 # seconds

  @mutex = Mutex.new
  @tokens = {} # tenant_id => { token:, at: }

  class << self
    def shop_domain
      EnvStore.fetch('SHOPIFY_SHOP_DOMAIN', 'm11u0i-sb.myshopify.com')
    end

    def token(force: false)
      @mutex.synchronize do
        cached = @tokens[Current.tenant_id]
        if force || cached.nil? || Time.now - cached[:at] > TOKEN_TTL
          response = http_post(
            "https://#{shop_domain}/admin/oauth/access_token",
            {
              client_id: EnvStore.fetch('SHOPIFY_CLIENT_ID', ''),
              client_secret: EnvStore.fetch('SHOPIFY_CLIENT_SECRET', ''),
              grant_type: 'client_credentials'
            }
          )
          unless response.is_a?(Net::HTTPSuccess)
            raise Error.new("Token exchange failed (HTTP #{response.code}).", reason: SyncFailure.http_reason(response.code))
          end

          payload = JSON.parse(response.body)
          raise Error.new('Token exchange returned no access_token', reason: :response) if payload['access_token'].blank?

          @tokens[Current.tenant_id] = { token: payload['access_token'], at: Time.now }
        end
        @tokens[Current.tenant_id][:token]
      end
    end

    def graphql(query, variables = {})
      response = http_post(
        "https://#{shop_domain}/admin/api/#{API_VERSION}/graphql.json",
        { query: query, variables: variables },
        { 'X-Shopify-Access-Token' => token }
      )
      unless response.is_a?(Net::HTTPSuccess)
        raise Error.new("GraphQL failed (HTTP #{response.code}).", reason: SyncFailure.http_reason(response.code))
      end

      payload = JSON.parse(response.body)
      if payload['errors'].present?
        codes = Array(payload['errors']).filter_map { |entry| entry.dig('extensions', 'code') if entry.is_a?(Hash) }
        reason = if codes.include?('ACCESS_DENIED')
          :access
        elsif codes.include?('THROTTLED')
          :rate_limit
        elsif codes.include?('INTERNAL_SERVER_ERROR')
          :vendor
        else
          :response
        end
        raise Error.new('Shopify returned a GraphQL error; previous source data was retained.', reason: reason)
      end

      payload['data']
    end

    private

    def http_post(url, body, headers = {})
      uri = URI(url)
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      headers.each { |k, v| request[k] = v }
      request.body = body.to_json
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 30, read_timeout: 120) do |http|
        http.request(request)
      end
    end
  end
end
