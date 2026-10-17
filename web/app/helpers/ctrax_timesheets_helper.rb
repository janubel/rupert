# frozen_string_literal: true

module CtraxTimesheetsHelper
  def ctrax_source_values(record)
    started = ctrax_source_time(record['started_at'])
    ended = ctrax_source_time(record['ended_at'])
    hours = record['number_of_hours']
    reported = BigDecimal(hours.to_s) if hours.is_a?(Numeric) && hours.finite? && hours >= 0 && hours <= 100_000
    { started_at: started, ended_at: ended, reported_hours: reported,
      elapsed_hours: started && ended && ended >= started ? BigDecimal((ended - started).to_s) / 3600 : nil,
      in_progress: [true, false].include?(record['is_in_progress']) ? record['is_in_progress'] : nil,
      verified: [true, false].include?(record['is_verified']) ? record['is_verified'] : nil }
  end

  def ctrax_source_time(value)
    Time.iso8601(value) if value.is_a?(String) && value.match?(/(?:Z|[+-]\d\d:\d\d)\z/)
  rescue ArgumentError
    nil
  end
end
