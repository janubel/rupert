# frozen_string_literal: true

module People
  # Turns approved timesheets (and current pay rates) into payslips for a pay
  # run. Hourly employees are paid from their approved hours; salaried staff are
  # paid a prorated slice of their annual salary. Deductions default to a flat
  # 15% payroll-tax estimate and can be adjusted per payslip before finalizing.
  class PayrollCalculator
    TAX_ESTIMATE = 0.15
    OVERTIME_MULTIPLIER = 1.5

    # Rebuilds the payslips for a draft pay run. Returns the payslips.
    def self.generate!(pay_run)
      raise ActiveRecord::RecordNotFound unless pay_run.tenant_id == Current.tenant_id

      pay_run.class.transaction do
        Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at')
        pay_run.reload
        raise ArgumentError, 'Only draft pay runs can be regenerated' unless pay_run.draft?

        pay_run.payslips.destroy_all

        approved_hours(pay_run).each do |employee_id, (hours, overtime)|
          employee = People::Employee.find(employee_id)
          rate = employee.current_pay_rate
          next if rate.nil?

          pay_run.payslips.create!(
            employee: employee,
            pay_rate: rate,
            hours: hours,
            gross_cents: gross_for(employee, hours, overtime, pay_run),
            deductions_cents: 0,
            net_cents: 0
          )
        end
        apply_default_deductions(pay_run)
        pay_run.payslips
      end
    end

    # Applies the default tax estimate to every payslip that has none.
    def self.apply_default_deductions(pay_run)
      pay_run.payslips.each do |slip|
        next if slip.deductions_cents.positive?

        deductions = (slip.gross_cents * TAX_ESTIMATE).round
        slip.update!(
          deductions_cents: deductions,
          net_cents: slip.gross_cents - deductions
        )
      end
    end

    def self.gross_for(employee, hours, overtime, pay_run)
      rate = employee.current_pay_rate
      return 0 if rate.nil?

      if rate.pay_type == 'hourly'
        regular = [hours.to_f - overtime.to_f, 0].max
        ((regular * rate.hourly_rate_cents) + (overtime.to_f * rate.hourly_rate_cents * OVERTIME_MULTIPLIER)).round
      else
        weeks = (pay_run.period_end - pay_run.period_start).to_f / 7.0
        denominator = { 'weekly' => 52.0, 'biweekly' => 26.0, 'monthly' => 12.0 }.fetch(rate.pay_frequency, 26.0)
        (rate.annual_salary_cents * (weeks / denominator)).round
      end
    end

    # Approved hours per employee inside the pay window: [total, overtime].
    def self.approved_hours(pay_run)
      rows = People::Timesheet.non_demo.approved
                              .where('period_start <= ? AND period_end >= ?', pay_run.period_end, pay_run.period_start)
                              .joins(:entries)
                              .where(timesheet_entries: { worked_on: pay_run.period_start..pay_run.period_end, tenant_id: Current.tenant_id })
                              .group('timesheets.employee_id', 'timesheet_entries.work_type')
                              .sum('timesheet_entries.hours')

      totals = Hash.new { |hash, key| hash[key] = [0.0, 0.0] }
      rows.each do |(employee_id, work_type), hours|
        total, overtime = totals[employee_id]
        totals[employee_id] = [total + hours, work_type == 'overtime' ? overtime + hours : overtime]
      end
      totals
    end

    private_class_method :gross_for, :approved_hours
  end
end
