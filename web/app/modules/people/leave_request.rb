# frozen_string_literal: true

module People
  # A time-off request (PTO). Moves requested -> approved / denied / cancelled.
  class LeaveRequest < ApplicationRecord
    include TenantScoped
    include AASM

    self.table_name = 'leave_requests'

    LEAVE_TYPES = %w[vacation sick personal unpaid].freeze

    belongs_to :employee, class_name: 'People::Employee'
    belongs_to :reviewer, class_name: 'User', foreign_key: :reviewed_by, optional: true

    validates :leave_type, inclusion: { in: LEAVE_TYPES }
    validates :starts_on, :ends_on, presence: true
    validates :reason, length: { maximum: 2000 }
    validates :hours, numericality: { greater_than: 0 }, allow_nil: true
    validate :employee_in_workspace
    validate :ends_after_starts

    scope :recent, ->(limit = 200) { order(starts_on: :desc).limit(limit) }
    scope :pending, -> { where(status: 'requested') }
    scope :by_status, ->(status) { status.present? && status != 'all' ? where(status: status) : all }

    aasm column: 'status', no_direct_assignment: true do
      state :requested, initial: true
      state :approved
      state :denied
      state :cancelled

      event :approve do
        transitions from: :requested, to: :approved
      end
      event :deny do
        transitions from: :requested, to: :denied
      end
      event :cancel do
        transitions from: %i[requested approved], to: :cancelled
      end
    end

    def days
      return 0 if starts_on.nil? || ends_on.nil?

      (ends_on - starts_on).to_i + 1
    end

    def duration_label
      hours.present? && hours.positive? ? "#{format('%g', hours)}h" : "#{days}d"
    end

    private

    def employee_in_workspace
      errors.add(:employee, 'must belong to this workspace') unless employee && employee.tenant_id == tenant_id
      errors.add(:hours, 'cannot exceed 24 hours per requested day') if hours && starts_on && ends_on && hours > days * 24
    end

    def ends_after_starts
      return if starts_on.nil? || ends_on.nil?

      errors.add(:ends_on, 'must be after the start') if ends_on < starts_on
    end
  end
end
