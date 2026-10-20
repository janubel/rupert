# frozen_string_literal: true

require 'net/http'

# Port of the legacy Square client (legacy/local-console.mjs) — catalog,
# inventory counts, orders, and locations against the Square v2 REST API.
class SquareClient
  class Error < StandardError
    attr_reader :reason

    def initialize(message, reason: nil)
      @reason = reason
      super(message)
    end
  end

  SQUARE_VERSION = '2026-07-15'
  PAGE_SIZE = 1000

  class << self
    def token
      EnvStore.fetch('SQUARE_ACCESS_TOKEN', '')
    end

    def environment
      EnvStore.fetch('SQUARE_ENVIRONMENT', 'production')
    end

    def base_url
      environment == 'sandbox' ? 'https://connect.squareupsandbox.com/v2' : 'https://connect.squareup.com/v2'
    end

    # Retries 429 (honouring Retry-After), 5xx and connection failures; see
    # HttpRetry. Square writes carry idempotency keys.
    def request(pathname, method: 'GET', body: nil)
      HttpRetry.with_retries('square') do
        uri = URI("#{base_url}#{pathname}")
        request = case method
                  when 'POST' then Net::HTTP::Post.new(uri)
                  else Net::HTTP::Get.new(uri)
                  end
        request['Authorization'] = "Bearer #{token}"
        request['Content-Type'] = 'application/json'
        request['Square-Version'] = SQUARE_VERSION
        request.body = body.to_json if body

        response = begin
          Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 120) do |http|
            http.request(request)
          end
        rescue *HttpRetry::NETWORK_ERRORS => e
          raise HttpRetry::Retry.new("#{e.class}: #{e.message}"), cause: e
        end

        if !response.is_a?(Net::HTTPSuccess) && HttpRetry.retryable_status?(response.code)
          error = Error.new("Square request failed (HTTP #{response.code}).", reason: SyncFailure.http_reason(response.code))
          raise HttpRetry::Retry.new(error.message, after: HttpRetry.retry_after(response)), cause: error
        end

        payload = begin
          JSON.parse(response.body)
        rescue JSON::ParserError
          Rails.logger.warn('SquareClient returned an unparseable response.')
          raise Error.new('Square returned invalid JSON.', reason: :response)
        end
        unless response.is_a?(Net::HTTPSuccess)
          raise Error.new("Square request failed (HTTP #{response.code}).", reason: SyncFailure.http_reason(response.code))
        end
        payload
      end
    end

    def locations
      (request('/locations')['locations'] || []).select { |l| l['status'] == 'ACTIVE' }
    end

    def catalog
      variations = []
      cursor = nil
      loop do
        params = { types: 'ITEM', limit: PAGE_SIZE.to_s }
        params['cursor'] = cursor if cursor
        query = params.to_query
        payload = request("/catalog/list?#{query}")
        Array(payload['objects']).each do |object|
          next if object['type'] != 'ITEM' || object['is_deleted']

          item_name = object.dig('item_data', 'name') || 'Untitled item'
          Array(object.dig('item_data', 'variations')).each do |variation|
            next if variation['is_deleted']

            variations << {
              variationId: variation['id'],
              itemId: object['id'],
              sku: variation.dig('item_variation_data', 'sku') || '',
              name: variation.dig('item_variation_data', 'name') || item_name
            }
          end
        end
        cursor = payload['cursor']
        break if cursor.blank?
      end
      variations
    end

    def inventory_counts(location_ids, catalog_ids)
      counts = Hash.new(0)
      counts_by_location = {}
      catalog_ids.each_slice(100) do |ids|
        payload = request('/inventory/counts/batch-retrieve', method: 'POST', body: {
                            location_ids: location_ids, catalog_object_ids: ids, states: ['IN_STOCK']
                          })
        Array(payload['counts']).each do |count|
          next if count['quantity'].nil?

          quantity = count['quantity'].to_i
          next if count['state'] && count['state'] != 'IN_STOCK'

          counts[count['catalog_object_id']] += quantity
          counts_by_location[count['location_id']] ||= Hash.new(0)
          counts_by_location[count['location_id']][count['catalog_object_id']] += quantity
        end
      end
      { counts: counts, counts_by_location: counts_by_location }
    end

    def orders(location_ids, since_iso, max: nil)
      orders = []
      cursor = nil
      max ||= 100_000
      loop do
        body = {
          location_ids: location_ids.first(10),
          query: {
            filter: {
              state_filter: { states: ['COMPLETED'] },
              date_time_filter: { created_at: { start_at: since_iso } }
            },
            sort: { sort_field: 'UPDATED_AT', sort_order: 'DESC' }
          },
          limit: 200
        }
        body[:cursor] = cursor if cursor
        payload = request('/orders/search', method: 'POST', body: body)
        orders.concat(payload['orders'] || [])
        cursor = payload['cursor']
        break if cursor.blank? || orders.length >= max
      end
      orders
    end

    def configured?
      token.present?
    end
  end
end
