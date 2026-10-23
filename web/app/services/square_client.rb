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
        each_inventory_count_page(location_ids, ids) do |payload|
          aggregate_inventory_counts(payload, counts, counts_by_location)
        end
      end
      { counts: counts, counts_by_location: counts_by_location }
    end

    def each_inventory_count_page(location_ids, catalog_ids)
      cursor = nil
      seen_cursors = {}
      loop do
        payload = inventory_counts_page(location_ids, catalog_ids, cursor)
        yield payload
        cursor = next_inventory_counts_cursor(payload, seen_cursors)
        break if cursor.nil?
      end
    end

    def inventory_counts_page(location_ids, catalog_ids, cursor)
      body = { location_ids: location_ids, catalog_object_ids: catalog_ids, states: ['IN_STOCK'] }
      body[:cursor] = cursor if cursor
      request('/inventory/counts/batch-retrieve', method: 'POST', body: body)
    end

    def next_inventory_counts_cursor(payload, seen_cursors)
      cursor = payload['cursor']
      return if cursor.blank?

      raise Error.new('Square returned a repeated inventory cursor.', reason: :response) if seen_cursors[cursor]

      seen_cursors[cursor] = true
      cursor
    end

    def aggregate_inventory_counts(payload, counts, counts_by_location)
      Array(payload['counts']).each { |count| accumulate_inventory_count(count, counts, counts_by_location) }
    end

    def accumulate_inventory_count(count, counts, counts_by_location)
      return if count['quantity'].nil? || (count['state'] && count['state'] != 'IN_STOCK')

      quantity = count['quantity'].to_i
      counts[count['catalog_object_id']] += quantity
      counts_by_location[count['location_id']] ||= Hash.new(0)
      counts_by_location[count['location_id']][count['catalog_object_id']] += quantity
    end

    # Orders changed since `since_iso`. Filtered on updated_at (Square requires
    # the sort field to match the date filter) so a later refund or return
    # re-selects the order; refunds arrive on the order payload.
    # Square takes at most 10 locations per search, so every group of 10 is read (it used to send only the first
    # 10). Reaching `max` raises instead of returning a partial list: the caller would otherwise move its watermark
    # past orders it never read.
    def orders(location_ids, since_iso, max: nil)
      max ||= 100_000
      orders = {}
      Array(location_ids).each_slice(10) do |group|
        cursor = nil
        loop do
          body = {
            location_ids: group,
            query: {
              filter: {
                state_filter: { states: ['COMPLETED'] },
                date_time_filter: { updated_at: { start_at: since_iso } }
              },
              sort: { sort_field: 'UPDATED_AT', sort_order: 'DESC' }
            },
            limit: 200
          }
          body[:cursor] = cursor if cursor
          payload = request('/orders/search', method: 'POST', body: body)
          Array(payload['orders']).each { |order| orders[order['id'] || order.object_id] = order }
          if orders.size > max
            raise Error.new("Square returned more than #{max} changed orders since #{since_iso}; nothing was imported and the sync point was kept.",
              reason: :response)
          end
          cursor = payload['cursor']
          break if cursor.blank?
        end
      end
      orders.values
    end

    def configured?
      token.present?
    end
  end
end
