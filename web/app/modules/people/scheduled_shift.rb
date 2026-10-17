# frozen_string_literal: true

module People
  # A planned shift for one employee. Not a record of hours worked.
  class ScheduledShift < ApplicationRecord
    include TenantScoped

    self.table_name = 'scheduled_shifts'

    belongs_to :employee, class_name: 'People::Employee'

    validates :starts_at, :ends_at, presence: true
    validates :role_label, length: { maximum: 80 }
    validates :notes, length: { maximum: 2000 }
    validate :employee_in_workspace
    validate :ordered_interval
    validate :non_overlapping_interval

    scope :chronological, -> { order(:starts_at, :id) }
    scope :between, lambda { |from, to|
      where('starts_at < ? AND ends_at > ?', (to + 1).in_time_zone, from.in_time_zone)
    }

    def hours
      return 0 if starts_at.nil? || ends_at.nil?

      (ends_at - starts_at) / 3600.0
    end

    def time_label
      "#{starts_at.strftime('%-l:%M %p')} – #{ends_at.strftime('%-l:%M %p')}"
    end

    private

    def employee_in_workspace
      errors.add(:employee, 'must belong to this workspace') unless employee && employee.tenant_id == tenant_id
    end

    def ordered_interval
      return if starts_at.nil? || ends_at.nil?

      errors.add(:ends_at, 'must be after the start') if ends_at <= starts_at
      errors.add(:ends_at, 'cannot make a shift longer than 24 hours') if ends_at > starts_at + 24.hours
    end

    def non_overlapping_interval
      return if starts_at.nil? || ends_at.nil? || employee_id.blank?

      overlap = self.class.where(employee_id: employee_id).where.not(id: id).where('starts_at < ? AND ends_at > ?', ends_at, starts_at)
      errors.add(:base, 'This overlaps another scheduled shift for this person') if overlap.exists?
    end
  end
end
