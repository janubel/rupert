# frozen_string_literal: true

module Directories
  class ShopifyCustomers
    QUERY = <<~GRAPHQL
      query RupertCustomers($cursor: String) {
        customers(first: 100, after: $cursor, sortKey: ID) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id firstName lastName
            defaultEmailAddress { emailAddress }
            defaultPhoneNumber { phoneNumber }
          }
        }
      }
    GRAPHQL

    def self.fetch
      fetch_directory(QUERY, 'customers', 'Customer')
    end

    def self.fetch_directory(query, field, native_type)
      rows = []
      cursors = []
      cursor = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 180
      200.times do
        raise Sync::Error if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        document = ShopifyClient.graphql(query, { cursor: cursor }).fetch(field)
        page = document.fetch('nodes')
        info = document.fetch('pageInfo')
        raise Sync::Error unless page.is_a?(Array) && page.size <= 100 && page.all? { |row| row.is_a?(Hash) }

        rows.concat(page)
        ids = rows.map { |row| row['id'] }
        unless ids.all? { |id| id.is_a?(String) && id.match?(%r{\Agid://shopify/#{native_type}/[1-9][0-9]{0,30}\z}) } && ids.uniq.size == rows.size
          raise Sync::Error
        end
        return rows if info['hasNextPage'] == false
        raise Sync::Error unless info['hasNextPage'] == true && page.any?

        cursor = info['endCursor']
        raise Sync::Error unless cursor.is_a?(String) && cursor.bytesize.between?(1, 4096) && !cursors.include?(cursor)

        cursors << cursor
      end
      raise Sync::Error
    rescue KeyError, TypeError, NoMethodError, ShopifyClient::Error
      raise Sync::Error
    end
  end
end
