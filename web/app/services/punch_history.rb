# frozen_string_literal: true

require 'bigdecimal'

# Unified punch history for administrators and reviewers.
#
# Three independent punch sources are read side by side and never merged into
# one payable record:
#   * ClockShift       — punches taken inside Rupert (clock in / clock out)
#   * SquareTimecard   — historical Square shifts imported as read-only history
#   * CtraxLaborShift  — register shifts observed from C-Trax (never payable)
#
# The same shift can exist in both. Rupert punches win when they overlap, so a
# Square card flagged `conflict` is reported as not counted and its hours are
# never added to a Rupert shift. Nothing here creates, edits or approves
# payroll; it is a reporting view only.
class PunchHistory
  SOURCES = %w[rupert square ctrax].freeze
  # A single punch longer than this is almost always a missed clock-out.
  IMPLAUSIBLE_HOURS = 16

  Row = Struct.new(:kind, :employee_id, :employee_name, :source, :started_at, :ended_at,
    :hours, :status, :reference, :issue, :rate_cents, :counted, keyword_init: true) do
    def implausible?
      hours.to_f > IMPLAUSIBLE_HOURS
    end

    def flagged?
      implausible? || (status != 'closed' && status != 'imported')
    end

    def estimated_cents
      return nil unless counted && rate_cents&.positive? && hours

      (hours * rate_cents).round
    end
  end

  Summary = Struct.new(:punches, :counted_punches, :hours, :counted_hours, :flagged, :implausible,
    :by_source, :by_employee, :by_employee_source, :open_shifts, keyword_init: true)

  def initialize(from:, to:, employee_id: nil, source: nil, status: nil, all_employees: false, worker_id: nil)
    @from = from
    @to = to
    @employee_id = employee_id
    @source = SOURCES.include?(source) ? source : nil
    @status = status.presence
    @all_employees = all_employees
    @worker_id = worker_id
  end

  def rows
    @rows ||= (rupert_rows + square_rows + ctrax_rows).sort_by { |row| [row.started_at || Time.at(0), row.employee_name.to_s] }.reverse
  end

  def summary
    counted = rows.select(&:counted)
    Summary.new(
      punches: rows.size,
      counted_punches: counted.size,
      hours: rows.sum { |row| row.hours || 0 }.round(2),
      counted_hours: counted.sum { |row| row.hours || 0 }.round(2),
      flagged: rows.count(&:flagged?),
      implausible: rows.count(&:implausible?),
      by_source: rows.group_by(&:source).transform_values(&:size),
      by_employee: rows.group_by(&:employee_name).transform_values { |list| list.sum { |row| row.hours || 0 }.round(2) },
      # { name => { 'rupert' => h, 'square' => h, 'ctrax' => h, 'counted' => h } } for the staff matrix.
      by_employee_source: rows.group_by(&:employee_name).transform_values do |list|
        matrix = SOURCES.to_h { |src| [src, list.select { |row| row.source == src }.sum { |row| row.hours || 0 }.round(2)] }
        matrix.merge('counted' => list.select(&:counted).sum { |row| row.hours || 0 }.round(2), 'punches' => list.size,
          'flagged' => list.count(&:flagged?))
      end,
      open_shifts: rows.count { |row| row.status == 'open' }
    )
  end

  # Calendar buckets keyed by ISO date. A punch is placed on its clock-in day;
  # multi-day shifts also mark every day they span so the calendar shows
  # coverage, not just the start.
  def calendar_days
    @calendar_days ||= rows.each_with_object({}) do |row, days|
      next unless row.started_at

      start_date = row.started_at.to_date
      end_date = (row.ended_at || row.started_at).to_date
      (start_date..end_date).each do |date|
        bucket = (days[date.iso8601] ||= { rows: [], hours: 0.0 })
        bucket[:rows] << row
        bucket[:hours] = (bucket[:hours] + (row.hours || 0)).round(2)
      end
    end
  end

  def to_csv
    CSV.generate do |out|
      out << ['Staff member', 'Source', 'Clock-in', 'Clock-out', 'Hours', 'Status',
        'Counted', 'Reference', 'Issue', 'Hourly rate', 'Estimated pay', 'Flag']
      rows.each do |row|
        out << [row.employee_name, { 'rupert' => 'Rupert clock', 'square' => 'Square', 'ctrax' => 'C-Trax' }.fetch(row.source, row.source),
          row.started_at&.iso8601, row.ended_at&.iso8601,
          row.hours && BigDecimal(row.hours.to_s).to_s('F'), row.status, row.counted ? 'yes' : 'no',
          row.reference, row.issue, row.rate_cents && (BigDecimal(row.rate_cents.to_s) / 100).to_s('F'),
          row.estimated_cents && (BigDecimal(row.estimated_cents.to_s) / 100).to_s('F'),
          row.implausible? ? "Over #{IMPLAUSIBLE_HOURS} hours; check for a missed clock-out" : nil].map { |value| TimesheetCsv.cell(value) }
      end
    end
  end

  private

  def rupert_rows
    return [] unless @all_employees || @worker_id.present?
    return [] if @source && @source != 'rupert'

    scope = ClockShift.all
    scope = scope.where(employee_id: @worker_id) unless @all_employees
    scope = scope.where(employee_id: @employee_id) if @employee_id.present?
    scope = scope.where('started_at >= ?', @from.beginning_of_day).where('started_at < ?', (@to + 1).beginning_of_day)
    scope = scope.where(ended_at: nil) if @status == 'open'
    scope = scope.where.not(ended_at: nil) if @status == 'closed'
    scope.order(started_at: :desc).map do |shift|
      Row.new(
        kind: 'clock_shift', employee_id: shift.employee_id, employee_name: shift.employee_name,
        source: 'rupert', started_at: shift.started_at, ended_at: shift.ended_at,
        hours: shift.hours.round(2), status: shift.ended_at ? 'closed' : 'open',
        reference: "Clock shift ##{shift.id}", issue: nil,
        rate_cents: pay_rate_for(shift.employee_id, shift.started_at), counted: true
      )
    end
  end

  def square_rows
    return [] unless @all_employees || @worker_id.present?
    return [] if @source && @source != 'square'

    scope = SquareTimecard.all
    scope = scope.where(employee_id: @worker_id) unless @all_employees
    scope = scope.where(employee_id: @employee_id) if @employee_id.present?
    # Square has no open/closed states of its own; map the shared filter words.
    square_status = @status == 'closed' ? 'imported' : @status
    scope = scope.where(import_status: square_status) if square_status.present? && square_status != 'open'
    scope = scope.where('started_at >= ?', @from.beginning_of_day).where('started_at < ?', (@to + 1).beginning_of_day)
    scope.order(started_at: :desc).map do |card|
      Row.new(
        kind: 'square_timecard', employee_id: card.employee_id,
        employee_name: card.employee&.name || 'Staff member not matched',
        source: 'square', started_at: card.started_at, ended_at: card.ended_at,
        hours: card.hours.round(2), status: card.import_status,
        reference: "Square #{card.external_id}", issue: card.issue,
        rate_cents: card.hourly_rate_cents, counted: card.imported_at.present?
      )
    end
  end

  # C-Trax shifts are observations only: hours are the latest source-reported
  # value (falling back to the original) and are never counted toward totals.
  def ctrax_rows
    return [] unless @all_employees || @worker_id.present?
    return [] if @source && @source != 'ctrax'

    scope = CtraxLaborShift.all
    scope = scope.where(employee_id: @worker_id) unless @all_employees
    scope = scope.where(employee_id: @employee_id) if @employee_id.present?
    scope = scope.where('started_at >= ?', @from.beginning_of_day).where('started_at < ?', (@to + 1).beginning_of_day)
    scope = scope.where(in_progress: true) if @status == 'open'
    scope = scope.where(status: 'imported') if @status == 'closed'
    scope = scope.where(status: @status) if @status.present? && CtraxLaborShift::STATUSES.include?(@status) && !%w[open].include?(@status)
    scope.includes(:employee).order(started_at: :desc).map do |shift|
      hours = shift.reported_hours || shift.elapsed_hours
      Row.new(
        kind: 'ctrax_shift', employee_id: shift.employee_id,
        employee_name: shift.employee&.name || 'Staff member not matched',
        source: 'ctrax', started_at: shift.started_at, ended_at: shift.ended_at,
        hours: hours&.to_f&.round(2), status: shift.in_progress? ? 'open' : shift.status,
        reference: "C-Trax #{shift.external_id}", issue: shift.issue,
        rate_cents: nil, counted: false
      )
    end
  end

  def pay_rate_for(employee_id, started_at)
    return nil unless employee_id && started_at

    People::PayRate.where(employee_id: employee_id).where('effective_on <= ?', started_at.to_date)
      .order(effective_on: :desc, id: :desc).first&.hourly_rate_cents
  end
end
