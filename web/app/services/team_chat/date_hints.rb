# frozen_string_literal: true

module TeamChat
  # Turns the relative dates in a question ("last month", "year to date", "the
  # last 30 days") into exact dates before a bot sees it, so a small model
  # never has to work out which month or year "last month" was.
  module DateHints
    PHRASES = {
      'today' => /\btoday\b|\bso far today\b/i,
      'yesterday' => /\byesterday\b/i,
      'this_week' => /\bthis week\b/i,
      'last_week' => /\blast week\b|\bprevious week\b/i,
      'this_pay_week' => /\bthis pay ?week\b/i,
      'last_pay_week' => /\blast pay ?week\b/i,
      'this_month' => /\bthis month\b|\bmonth to date\b|\bmtd\b/i,
      'last_month' => /\blast month\b|\bprevious month\b/i,
      'this_quarter' => /\bthis quarter\b|\bquarter to date\b|\bqtd\b/i,
      'last_quarter' => /\blast quarter\b|\bprevious quarter\b/i,
      'year_to_date' => /\byear to date\b|\bytd\b|\bso far this year\b|\bthis year\b/i,
      'last_year' => /\blast year\b|\bprevious year\b/i
    }.freeze
    LAST_DAYS = /\b(?:last|past|previous)\s+(\d{1,3})\s+days\b/i

    module_function

    # ["last month = 2026-09-01 to 2026-09-30 (period_review period: last_month)", ...]
    def call(text, today: Date.current)
      text = text.to_s
      hints = PHRASES.filter_map do |key, pattern|
        next unless text.match?(pattern)
        next if key == 'this_week' && text.match?(PHRASES['this_pay_week'])
        next if key == 'last_week' && text.match?(PHRASES['last_pay_week'])

        preset = TimeRangePicker.preset(key, today)
        to = [preset.to, today].min
        span = preset.from == to ? preset.from.iso8601 : "#{preset.from.iso8601} to #{to.iso8601}"
        "#{preset.label.downcase} = #{span} (period_review period: #{key})"
      end
      text.scan(LAST_DAYS).each do |(days)|
        days = days.to_i.clamp(1, 400)
        hints << "the last #{days} days = #{(today - days + 1).iso8601} to #{today.iso8601}"
      end
      hints
    end
  end
end
