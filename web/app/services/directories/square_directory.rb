# frozen_string_literal: true

module Directories
  class SquareDirectory
    def self.fetch(kind)
      rows = []
      seen = []
      cursor = nil
      total = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 180
      1000.times do
        raise Sync::Error if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        if kind == 'customers'
          query = { limit: 100, count: true, sort_field: 'CREATED_AT', sort_order: 'ASC' }
          query[:cursor] = cursor if cursor
          document = SquareClient.request("/customers?#{query.to_query}")
          count = document.fetch('count')
          raise Sync::Error unless count.is_a?(Integer) && count >= 0 && (total.nil? || total == count)

          total = count
          page = document.fetch('customers', [])
        else
          body = { limit: 200 }
          body[:cursor] = cursor if cursor
          document = SquareClient.request('/team-members/search', method: 'POST', body: body)
          page = document.fetch('team_members', [])
        end
        raise Sync::Error if document['errors'].present?
        raise Sync::Error unless page.is_a?(Array) && page.all? { |row| row.is_a?(Hash) }

        rows.concat(page)
        ids = rows.map { |row| row['id'] }
        raise Sync::Error unless ids.all? { |id| id.is_a?(String) && id.match?(/\A[a-zA-Z0-9_-]{1,255}\z/) } && ids.uniq.size == rows.size
        raise Sync::Error if rows.size > 100_000

        cursor = document['cursor']
        if cursor.nil? || cursor == ''
          raise Sync::Error if total && rows.size != total

          return rows
        end
        raise Sync::Error unless cursor.is_a?(String) && cursor.bytesize.between?(1, 4096) && !seen.include?(cursor) && page.any?

        seen << cursor
      end
      raise Sync::Error
    rescue KeyError, TypeError, NoMethodError, SquareClient::Error
      raise Sync::Error
    end
  end
end
