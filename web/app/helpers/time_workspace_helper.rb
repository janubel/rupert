# frozen_string_literal: true

# One consistent header across every time page (timesheets, punch report,
# Square and C-Trax history, team schedule, payroll) so an administrator can
# move between review, reporting and source history without hunting.
module TimeWorkspaceHelper
  # Named reporting windows for every time report, as TimeRangePicker::Preset
  # (key, label, from, to). Pay weeks run Thursday–Wednesday.
  def time_range_presets(today = Date.current)
    TimeRangePicker.presets(today)
  end

  # The same windows as [label, from, to], plus "All history" (kept for older callers).
  def time_report_presets(today = Date.current)
    time_range_presets(today).map { |preset| [preset.label, preset.from, preset.to] } + [['All history', Date.new(2000, 1, 1), today]]
  end

  # Options for the range dropdown: every preset, then Custom (and All dates when optional).
  def time_range_options(today = Date.current, optional: false)
    options = time_range_presets(today).map { |preset| [preset.label, preset.key] }
    options << ['All dates', TimeRangePicker::ALL] if optional
    options << ['Custom', TimeRangePicker::CUSTOM]
  end

  # The current query with the picker's resolved dates as plain from/to, for
  # links (CSV, views, filters) that must carry the chosen range.
  def time_range_query(from, to)
    request.query_parameters.to_h.symbolize_keys.except(:range, :range_shown, :from, :to, :commit)
      .merge(from: from&.iso8601, to: to&.iso8601).compact
  end

  def time_source_label(source)
    { 'rupert' => 'Rupert clock', 'square' => 'Square', 'ctrax' => 'C-Trax' }.fetch(source.to_s, source.to_s.humanize)
  end

  def time_source_pill(source)
    { 'rupert' => 'pill-olive', 'square' => 'pill-taupe', 'ctrax' => 'pill-clay' }.fetch(source.to_s, 'pill-taupe')
  end

  def time_status_pill(status)
    case status.to_s
    when 'open', 'conflict', 'invalid', 'missing', 'deleted' then 'pill-rose'
    when 'imported', 'closed' then 'pill-fern'
    else 'pill-olive'
    end
  end
end
