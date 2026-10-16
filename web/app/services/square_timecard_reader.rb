# frozen_string_literal: true

require 'digest'

# Only Square's search endpoint is used: POST search is a read operation.
class SquareTimecardReader
  class Error < StandardError; end
  attr_reader :fingerprint

  def self.credential_fingerprint
    Digest::SHA256.hexdigest([Current.tenant_id, SquareClient.environment, SquareClient.token].join("\0"))
  end

  def call
    raise Error, 'Configure the Square connection first.' unless SquareClient.configured?

    @fingerprint = self.class.credential_fingerprint
    rows = []
    seen_ids = {}
    seen_cursors = {}
    cursor = nil
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 600
    1000.times do
      raise Error, 'Square history read exceeded its limit. No hours were imported.' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      body = { limit: 200, query: { sort: { field: 'START_AT', order: 'ASC' } } }
      body[:cursor] = cursor if cursor
      document = SquareClient.request('/labor/timecards/search', method: 'POST', body: body)
      page = document.fetch('timecards', [])
      raise Error, 'Square returned an incomplete history. No hours were imported.' if document['errors'].present? || !page.is_a?(Array)

      page.each do |row|
        id = row.is_a?(Hash) && row['id']
        raise Error, 'Square returned invalid or repeated timecards. No hours were imported.' unless id.is_a?(String) && id.match?(/\A[a-zA-Z0-9_-]{1,255}\z/) && !seen_ids[id]

        seen_ids[id] = true
        rows << row
      end
      raise Error, 'Square history is too large. No hours were imported.' if rows.size > 100_000

      cursor = document['cursor']
      return rows if cursor.nil? || cursor == ''
      raise Error, 'Square pagination was incomplete. No hours were imported.' unless cursor.is_a?(String) && cursor.bytesize.between?(1, 4096) && !seen_cursors[cursor] && page.any?

      seen_cursors[cursor] = true
    end
    raise Error, 'Square history pagination exceeded its limit. No hours were imported.'
  rescue SquareClient::Error, KeyError
    raise Error, 'Square history could not be read. Existing hours were retained.'
  end

  def verify_connection!
    EnvStore.clear_cache!
    raise Error, 'The Square connection changed. No hours were imported.' unless fingerprint == self.class.credential_fingerprint
  end
end
