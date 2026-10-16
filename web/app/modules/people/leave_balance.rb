# frozen_string_literal: true

module People
  # Annual allowance per employee per leave type: hours accrued vs used.
  class LeaveBalance < ApplicationRecord
    include TenantScoped

    self.table_name = 'leave_balances'

    belongs_to :employee, class_name: 'People::Employee'

    validates :leave_type, inclusion: { in: LeaveRequest::LEAVE_TYPES }
    validates :year, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1900, less_than_or_equal_to: 2100 }
    validates :accrued_hours, :used_hours, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 9999.99 }

    scope :for_year, ->(year) { where(year: year) }
    scope :ordered, -> { order(:year, :leave_type) }

    def remaining_hours
      (accrued_hours || 0) - (used_hours || 0)
    end

    def label
      "#{leave_type.titleize} #{year}"
    end
  end
end
