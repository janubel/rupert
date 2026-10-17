# frozen_string_literal: true

module SquareTimesheetsHelper
  def square_latest_values(card)
    record = JSON.parse(card.latest_payload.presence || card.source_payload.presence || '{}')
    record = {} unless record.is_a?(Hash)
    zone = Time.find_zone(record['timezone']) if record['timezone'].is_a?(String)
    pauses = record['breaks'].is_a?(Array) ? record['breaks'] : []
    { started_at: square_source_time(record['start_at']), ended_at: square_source_time(record['end_at']),
      timezone: zone&.tzinfo&.name, status: %w[OPEN CLOSED].include?(record['status']) ? record['status'] : nil,
      breaks: pauses.filter_map do |pause|
        next unless pause.is_a?(Hash)

        { name: pause['name'].is_a?(String) ? pause['name'] : nil,
          started_at: square_source_time(pause['start_at']), ended_at: square_source_time(pause['end_at']),
          is_paid: [true, false].include?(pause['is_paid']) ? pause['is_paid'] : nil }
      end }
  rescue JSON::ParserError, TypeError, ArgumentError
    { started_at: nil, ended_at: nil, timezone: nil, status: nil, breaks: [] }
  end

  def square_source_time(value)
    Time.iso8601(value) if value.is_a?(String) && value.match?(/(?:Z|[+-]\d\d:\d\d)\z/)
  rescue ArgumentError
    nil
  end

  def square_punch_label(time, timezone)
    return 'Not available' unless time

    l(timezone ? time.in_time_zone(timezone) : time, format: '%b %-d, %Y · %-I:%M:%S %p %Z')
  end
end
