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

  API_VERSION = SHOPIFY_ADMIN_API_VERSION
  TOKEN_TTL = 10 * 60 # seconds

  @mutex = Mutex.new
  @tokens = {} # tenant_id => { token:, at: }

  class << self
    # The store to talk to: the managed SHOPIFY_SHOP_DOMAIN setting, else the
    # workspace's own shop domain. There is deliberately no hard-coded default:
    # a misconfigured workspace must fail loudly rather than sync another shop.
    def shop_domain
      domain = EnvStore.fetch('SHOPIFY_SHOP_DOMAIN', '').to_s.strip.presence || Current.tenant&.shopify_shop_domain.to_s.strip.presence
      raise Error.new('SHOPIFY_SHOP_DOMAIN is not set for this workspace.', reason: :invalid) if domain.blank?

      domain
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

    # Retries rate limits (HTTP 429 and GraphQL THROTTLED, waiting for the cost
    # bucket to refill), 5xx and connection failures; see HttpRetry.
    def graphql(query, variables = {})
      HttpRetry.with_retries('shopify') do
        response = begin
          http_post(
            "https://#{shop_domain}/admin/api/#{API_VERSION}/graphql.json",
            { query: query, variables: variables },
            { 'X-Shopify-Access-Token' => token }
          )
        rescue *HttpRetry::NETWORK_ERRORS => e
          raise HttpRetry::Retry.new("#{e.class}: #{e.message}"), cause: e
        end

        unless response.is_a?(Net::HTTPSuccess)
          error = Error.new("GraphQL failed (HTTP #{response.code}).", reason: SyncFailure.http_reason(response.code))
          raise HttpRetry::Retry.new(error.message, after: HttpRetry.retry_after(response)), cause: error if HttpRetry.retryable_status?(response.code)

          raise error
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
          error = Error.new('Shopify returned a GraphQL error; previous source data was retained.', reason: reason)
          raise HttpRetry::Retry.new('Shopify THROTTLED', after: throttle_wait(payload)), cause: error if reason == :rate_limit
          raise HttpRetry::Retry.new('Shopify INTERNAL_SERVER_ERROR'), cause: error if reason == :vendor

          raise error
        end

        payload['data']
      end
    end

    private

    # Seconds until the GraphQL cost bucket can serve the throttled query:
    # (requested - available) / restoreRate, from extensions.cost when present.
    def throttle_wait(payload)
      cost = payload.dig('extensions', 'cost') || {}
      requested = cost['requestedQueryCost'].to_f
      status = cost['throttleStatus'] || {}
      available = status['currentlyAvailable'].to_f
      rate = status['restoreRate'].to_f
      return nil unless requested.positive? && rate.positive?

      ((requested - available) / rate).clamp(0.5, 60.0)
    end

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
