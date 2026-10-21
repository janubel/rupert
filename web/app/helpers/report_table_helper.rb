# frozen_string_literal: true

# Customizable report tables: wrap any report <table> to let the viewer choose
# columns, sort by a heading, narrow rows and download what they see. See
# app/javascript/controllers/report_table_controller.js.
module ReportTableHelper
  def report_table(key, label:, filename: nil, sortable: true, &block)
    render('shared/report_table', key: key, label: label, filename: filename || key, sortable: sortable, table: capture(&block))
  end

  # Date window carried between report tabs: explicit dates when chosen,
  # otherwise the rolling day count.
  def report_window_params
    return { days: @days } unless @to_date && @range

    { from: @range.to_date.iso8601, to: @to_date.iso8601 }
  end

  # Quick ranges for report date pickers, as [label, from, to].
  def report_date_presets(today = Date.current)
    last_month = today.prev_month
    last_quarter = today.beginning_of_quarter.prev_day
    [['This month', today.beginning_of_month, today], ['Last month', last_month.beginning_of_month, last_month.end_of_month],
     ['This quarter', today.beginning_of_quarter, today], ['Last quarter', last_quarter.beginning_of_quarter, last_quarter.end_of_quarter],
     ['Year to date', today.beginning_of_year, today], ['Last year', today.prev_year.beginning_of_year, today.prev_year.end_of_year]]
  end

  # Cents for a money cell's data-sort-value; blank when the amount is unknown.
  def report_sort_cents(cents)
    cents.nil? ? '' : cents.to_s
  end
end
