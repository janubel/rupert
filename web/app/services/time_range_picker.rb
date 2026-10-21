# frozen_string_literal: true

# Named reporting windows shared by every time report, and server-side
# resolution of the shared range picker (`shared/_time_range_picker`).
#
# The picker submits `range` (a preset key, `custom` or `all`), `from`, `to`
# and `range_shown` (the from..to the page was rendered with). A preset wins
# when the dates were left as shown (or not sent at all), so the form works
# without JavaScript: picking a preset and submitting applies it, and editing
# the dates applies them. With JavaScript the dropdown and dates always agree.
# Pay weeks run Thursday–Wednesday; calendar weeks run Monday–Sunday.
class TimeRangePicker
  Preset = Data.define(:key, :label, :from, :to)
  Resolved = Data.define(:from, :to, :key)

  CUSTOM = 'custom'
  ALL = 'all'

  def self.presets(today = Date.current)
    pay_week = today.beginning_of_week(:thursday)
    week = today.beginning_of_week(:monday)
    last_month = today.prev_month
    last_quarter = today.beginning_of_quarter.prev_day
    [
      Preset.new('today', 'Today', today, today),
      Preset.new('yesterday', 'Yesterday', today - 1, today - 1),
      Preset.new('this_pay_week', 'This pay week', pay_week, pay_week + 6),
      Preset.new('last_pay_week', 'Last pay week', pay_week - 7, pay_week - 1),
      Preset.new('next_pay_week', 'Next pay week', pay_week + 7, pay_week + 13),
      Preset.new('this_week', 'This week', week, week + 6),
      Preset.new('last_week', 'Last week', week - 7, week - 1),
      Preset.new('this_month', 'This month', today.beginning_of_month, today.end_of_month),
      Preset.new('last_month', 'Last month', last_month.beginning_of_month, last_month.end_of_month),
      Preset.new('this_quarter', 'This quarter', today.beginning_of_quarter, today.end_of_quarter),
      Preset.new('last_quarter', 'Last quarter', last_quarter.beginning_of_quarter, last_quarter.end_of_quarter),
      Preset.new('year_to_date', 'Year to date', today.beginning_of_year, today),
      Preset.new('last_year', 'Last year', today.prev_year.beginning_of_year, today.prev_year.end_of_year)
    ]
  end

  def self.preset(key, today = Date.current)
    presets(today).find { |preset| preset.key == key.to_s }
  end

  # The preset whose dates are exactly from..to, else `all` (both blank) or `custom`.
  def self.key_for(from, to, today = Date.current)
    return ALL if from.nil? && to.nil?

    presets(today).find { |preset| preset.from == from && preset.to == to }&.key || CUSTOM
  end

  # Resolves picker params into dates. Blank dates come back nil so each page
  # keeps its own default; invalid dates raise Date::Error as before.
  def self.resolve(params, today: Date.current)
    key = params[:range].to_s
    shown = params[:range_shown]
    dates_as_shown = shown.blank? || shown.to_s == "#{params[:from]}..#{params[:to]}"
    if dates_as_shown && (preset = preset(key, today))
      return Resolved.new(preset.from, preset.to, preset.key)
    end
    return Resolved.new(nil, nil, ALL) if dates_as_shown && key == ALL

    from = parse(params[:from])
    to = parse(params[:to])
    Resolved.new(from, to, key_for(from, to, today))
  end

  def self.parse(value)
    value.blank? ? nil : Date.iso8601(value.to_s)
  end
end
