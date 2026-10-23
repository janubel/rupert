# frozen_string_literal: true

# "What if we paid staff this way?" A read-only model of an incentive plan against real history: for each employee,
# the sales they rang up while clocked in (the same matching as the Pay tab, EmployeePayWeek), the commission under
# today's rule (1% of before-tax, after-discount sales on shift) and under the plan being modelled, with a higher
# rate for staff marked in training who worked more than a set number of hours that week. Nothing is saved or
# posted to payroll. Coupon and referral bonuses need discount codes on orders, which are not imported yet.
class IncentiveModel
  PERIODS = {
    'last_4_weeks' => 'Last 4 weeks', 'last_3_months' => 'Last 3 months (13 weeks)',
    'last_5_saturdays' => 'Last 5 Saturdays', 'custom' => 'Custom dates'
  }.freeze
  MAX_DAYS = 92
  DEFAULTS = { shift_rate: 1.0, training_rate: 2.0, training_hours: 20.0 }.freeze

  Plan = Struct.new(:shift_rate, :training_rate, :training_hours, :trainees, keyword_init: true)
  Row = Struct.new(:employee, :hours, :sales_cents, :current_cents, :plan_cents, :training_weeks, keyword_init: true) do
    def difference_cents = plan_cents - current_cents

    def per_hour_cents
      (plan_cents / hours).round if hours.positive?
    end
  end

  attr_reader :plan, :period, :from, :to, :ranges, :rows, :notes

  def self.plan_from(params)
    number = ->(key, min, max) { (params[key].presence || DEFAULTS.fetch(key)).to_f.clamp(min, max).round(2) }
    Plan.new(shift_rate: number.call(:shift_rate, 0, 10), training_rate: number.call(:training_rate, 0, 10),
      training_hours: number.call(:training_hours, 0, 60), trainees: Array(params[:trainees]).map(&:to_s).compact_blank)
  end

  def initialize(plan:, period: 'last_4_weeks', from: nil, to: nil, today: Date.current)
    @plan = plan
    @period = PERIODS.key?(period.to_s) ? period.to_s : 'last_4_weeks'
    @today = today
    @ranges = build_ranges(from, to)
    @from = @ranges.map(&:first).min
    @to = @ranges.map(&:last).max
    @notes = []
    @rows = CommissionPreview.caching { build_rows }
  end

  def total(key) = rows.sum { |row| row.public_send(key) }
  def total_hours = rows.sum(&:hours)

  def cost_per_hour_cents
    (total(:plan_cents) / total_hours).round if total_hours.positive?
  end

  def days = ranges.sum { |first, last| (last - first).to_i + 1 }

  private

  # Whole Thursday-Wednesday weeks that have ended, single Saturdays, or custom dates cut at week boundaries.
  def build_ranges(from, to)
    this_week = EmployeePayWeek.week_start(@today)
    case @period
    when 'last_3_months' then (1..13).map { |back| week(this_week - (7 * back)) }.reverse
    when 'last_5_saturdays'
      last = @today.saturday? ? @today - 7 : @today - ((@today.wday - 6) % 7)
      (0...5).map { |back| [last - (7 * back)] * 2 }.reverse
    when 'custom'
      first = parse(from) || (@today - 27)
      last = [parse(to) || @today, @today].min
      first, last = last, first if first > last
      first = last - (MAX_DAYS - 1) if (last - first).to_i >= MAX_DAYS
      split_weeks(first, last)
    else (1..4).map { |back| week(this_week - (7 * back)) }.reverse
    end
  end

  def week(start) = [start, start + 6]

  def split_weeks(first, last)
    ranges = []
    cursor = first
    while cursor <= last
      week_end = EmployeePayWeek.week_start(cursor) + 6
      ranges << [cursor, [week_end, last].min]
      cursor = week_end + 1
    end
    ranges
  end

  def parse(value)
    Date.iso8601(value.to_s) if value.present?
  rescue Date::Error
    nil
  end

  def build_rows
    employees = People::Employee.where(id: ClockShift.where(started_at: from.beginning_of_day...(to + 1).beginning_of_day).select(:employee_id)).order(:first_name, :last_name).to_a
    employees.map do |employee|
      row = Row.new(employee: employee, hours: 0.0, sales_cents: 0, current_cents: 0, plan_cents: 0, training_weeks: 0)
      ranges.each do |first, last|
        part = EmployeePayWeek.new(employee: employee, from: first, to: last)
        whole_week = first == EmployeePayWeek.week_start(first) && last == first + 6 ? part : EmployeePayWeek.new(employee: employee, week_of: first)
        training = plan.trainees.include?(employee.id.to_s) && whole_week.hours > plan.training_hours
        rate = training ? plan.training_rate : plan.shift_rate
        row.hours += part.hours
        row.sales_cents += part.sales_cents
        row.current_cents += part.commission_cents
        row.plan_cents += (part.sales_cents * rate / 100.0).round
        row.training_weeks += 1 if training
        @notes |= part.notes.reject { |note| note.start_with?('No pay rate') }
      end
      row
    end
  end
end
