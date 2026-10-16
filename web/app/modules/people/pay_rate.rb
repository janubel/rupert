# frozen_string_literal: true

module People
  # Pay for an employee: hourly or salary, at a given frequency, active over a
  # date range. The latest effective rate that isn't ended drives payroll.
  class PayRate < ApplicationRecord
    include TenantScoped

    self.table_name = 'pay_rates'

    PAY_TYPES = %w[hourly salary].freeze
    PAY_FREQUENCIES = %w[weekly biweekly monthly].freeze

    belongs_to :employee, class_name: 'People::Employee'

    validates :pay_type, inclusion: { in: PAY_TYPES }
    validates :pay_frequency, inclusion: { in: PAY_FREQUENCIES }
    validates :effective_on, presence: true
    validates :hourly_rate_cents, :annual_salary_cents, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 2_000_000_000, only_integer: true }
    validate :ended_after_effective
    validate :one_rate_kind

    scope :current, -> { where('effective_on <= ? AND (ended_on IS NULL OR ended_on >= ?)', Date.current, Date.current) }
    scope :recent, -> { order(effective_on: :desc) }

    def rate_cents
      pay_type == 'salary' ? annual_salary_cents : hourly_rate_cents
    end

    def label
      if pay_type == 'salary'
        "$#{format('%.0f', annual_salary_cents / 100.0)}/yr · #{pay_frequency}"
      else
        "$#{format('%.2f', hourly_rate_cents / 100.0)}/hr · #{pay_frequency}"
      end
    end

    private

    def ended_after_effective
      errors.add(:ended_on, 'must not be before the effective date') if ended_on && effective_on && ended_on < effective_on
    end

    def one_rate_kind
      if pay_type == 'hourly' && annual_salary_cents.positive?
        errors.add(:annual_salary_cents, "can't be set for an hourly rate")
      elsif pay_type == 'salary' && hourly_rate_cents.positive?
        errors.add(:hourly_rate_cents, "can't be set for a salary")
      end
    end
  end
end
