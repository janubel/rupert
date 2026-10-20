# frozen_string_literal: true

# One staff member's pay figures for a Thursday-Wednesday week: hours, hourly
# rate, base pay, commission and tips. A read-only estimate for the staff
# member's page; it does not post to payroll or create payslips.
#
# Commission is 1% of the before-tax, after-discount sales rung up while the
# staff member was clocked in (the same rule as the commission preview). A tip
# is split evenly between everyone clocked in when it was left. Sales come from
# imported Shopify/Square/SwipeSimple orders and stored C-Trax store-days.
class EmployeePayWeek
  CURRENCY = 'USD'

  attr_reader :employee, :start_date, :end_date, :pay_rate, :hours, :sales_cents, :commission_cents, :tip_cents, :notes

  def self.week_start(date)
    date.beginning_of_week(:thursday)
  end

  def initialize(employee:, week_of: Date.current)
    @employee = employee
    @start_date = self.class.week_start(week_of)
    @end_date = @start_date + 6
    @notes = []
    @sales_cents = 0
    @commission_cents = 0
    @tip_cents = 0
    @pay_rate = employee.current_pay_rate
    load_shifts
    @hours = own_shifts.sum { |shift| clipped_seconds(shift) } / 3600.0
    add_order_sources
    add_ctrax_days
    @notes << 'No pay rate is on file, so base pay is unavailable.' unless pay_rate
  end

  def hourly_rate_cents
    pay_rate&.pay_type == 'hourly' ? pay_rate.hourly_rate_cents : nil
  end

  def base_cents
    return nil unless pay_rate
    return (hours * pay_rate.hourly_rate_cents).round if pay_rate.pay_type == 'hourly'

    (pay_rate.annual_salary_cents / 52.0).round
  end

  def total_cents
    base_cents.to_i + commission_cents + tip_cents
  end

  private

  def window
    start_date.beginning_of_day...(end_date + 1).beginning_of_day
  end

  def load_shifts
    @now = Time.current
    @shifts = ClockShift.where('started_at < ? AND (ended_at IS NULL OR ended_at > ?)', window.end, window.begin).to_a
    @groups = @shifts.group_by(&:employee_key)
    @own_keys = @shifts.select { |shift| shift.employee_id == employee.id }.map(&:employee_key).uniq
  end

  def own_shifts
    @shifts.select { |shift| shift.employee_id == employee.id }
  end

  def clipped_seconds(shift)
    finish = [shift.ended_at || @now, window.end].min
    [finish - [shift.started_at, window.begin].max, 0].max
  end

  def add_order_sources
    return if @own_keys.empty?

    CommissionPreview::SOURCES.each do |source|
      preview = CommissionPreview.new(start_date: start_date.iso8601, end_date: end_date.iso8601, source: source, currency: CURRENCY)
      row = preview.rows.find { |candidate| candidate[:employee_id] == employee.id }
      next unless row

      @sales_cents += row[:sales_cents]
      @commission_cents += row[:commission_cents]
      @tip_cents += row[:tip_cents]
    end
  rescue CommissionPreview::Error => e
    @notes << "Shopify, Square and SwipeSimple sales were not included: #{e.message}"
  end

  def add_ctrax_days
    return if @own_keys.empty?

    CtraxDay.where(business_date: (start_date - 1)..(end_date + 1), currency: CURRENCY).find_each do |day|
      Ctrax::Reconciliation.new(day).orders.each do |order|
        at = Time.iso8601(order['completed_at'].to_s).in_time_zone
        next unless window.cover?(at) && order['total'].is_a?(Integer) && order['tax'].is_a?(Integer) && order['refund_count'].to_i.zero?

        on_shift = @groups.select { |_key, shifts| shifts.any? { |shift| at >= shift.started_at && at < (shift.ended_at || @now) } }
        next unless (@own_keys & on_shift.keys).any?

        base = order['total'] - order['tax']
        @sales_cents += base
        @commission_cents += (base + 50) / 100
        @tip_cents += order['tip'].to_i / on_shift.size
      end
    end
  rescue ArgumentError, ActiveRecord::Encryption::Errors::Decryption
    @notes << 'Some C-Trax sales could not be read and were not included.'
  end
end
