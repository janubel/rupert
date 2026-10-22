# frozen_string_literal: true

module Metrics
  # A reporting period (named preset or from/to dates) and the periods it is compared with.
  # Shared by the metrics layer and period_review, so "last month vs the month before" means the same everywhere.
  Window = Data.define(:from, :to, :label, :key) do
    def self.resolve(period: nil, from: nil, to: nil, today: Date.current)
      if from.present? || to.present?
        first = parse(from, 'from') || (parse(to, 'to') || today) - 29
        last = parse(to, 'to') || today
        raise ArgumentError, 'to must be on or after from.' if last < first
        raise ArgumentError, "Choose a range of #{MAX_DAYS} days or fewer." if (last - first).to_i >= MAX_DAYS

        return new(from: first, to: last, label: "#{first.iso8601} to #{last.iso8601}", key: nil)
      end
      key = period.presence || 'last_month'
      raise ArgumentError, "Unknown period #{key.to_s.first(30)}. Use one of: #{PRESETS.join(', ')}." unless PRESETS.include?(key.to_s)

      preset = TimeRangePicker.preset(key, today)
      new(from: preset.from, to: [preset.to, today].min, label: preset.label, key: key.to_s)
    end

    def self.parse(value, name)
      return nil if value.blank?

      Date.iso8601(value.to_s.strip[/\A\d{4}-\d{2}-\d{2}/].to_s)
    rescue Date::Error
      raise ArgumentError, "#{name} must be a date like 2026-10-01."
    end

    def days = (to - from).to_i + 1

    # The same kind of period just before: the previous month or quarter, else the same number of days.
    def previous
      first, last = case key
                    when 'this_month', 'last_month' then [from.prev_month, from.prev_month.end_of_month]
                    when 'this_quarter', 'last_quarter' then [from.prev_month(3), from.prev_month(3).end_of_quarter]
                    when 'year_to_date' then [from.prev_year, to.prev_year]
                    when 'last_year' then [from.prev_year, from.prev_year.end_of_year]
                    when 'this_week', 'this_pay_week' then [from - 7, to - 7]
                    else [from - days, from - 1]
                    end
      Window.new(from: first, to: last, label: "#{first.iso8601} to #{last.iso8601}", key: nil)
    end

    # The same dates one year earlier.
    def last_year = Window.new(from: from.prev_year, to: to.prev_year, label: "#{from.prev_year.iso8601} to #{to.prev_year.iso8601}", key: nil)

    def times = from.in_time_zone.beginning_of_day...(to + 1).in_time_zone.beginning_of_day

    def as_json(*) = { label: label, from: from.iso8601, to: to.iso8601 }
  end
end
