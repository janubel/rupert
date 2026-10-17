# frozen_string_literal: true

module People
  # A weekly/batched time record for one employee: period bounds plus entries
  # per day. Moves draft -> submitted -> approved/rejected as a manager reviews.
  class Timesheet < ApplicationRecord
    include TenantScoped
    include AASM

    self.table_name = 'timesheets'

    belongs_to :employee, class_name: 'People::Employee'
    belongs_to :reviewer, class_name: 'User', foreign_key: :reviewed_by, optional: true
    belongs_to :assigned_reviewer, class_name: 'User', optional: true
    has_many :entries, class_name: 'People::TimesheetEntry', dependent: :destroy, inverse_of: :timesheet

    has_many :events, class_name: 'People::TimesheetEvent', dependent: :destroy
    validates :period_start, :period_end, presence: true
    validates :period_start, uniqueness: { scope: [:tenant_id, :employee_id] }
    validates :notes, :review_note, length: { maximum: 4000 }
    validate :valid_employee_and_period
    validate :locked_fields
    validate :valid_demo_review

    validate :period_end_after_start

    scope :recent, ->(limit = 200) { order(period_start: :desc).limit(limit) }
    scope :by_status, ->(status) { status.present? && status != 'all' ? where(status: status) : all }
    scope :awaiting_review, -> { where(status: 'submitted') }
    scope :demo_records, -> { where(demo: true) }
    scope :non_demo, -> { where(demo: false) }

    aasm column: 'status', no_direct_assignment: true do
      state :draft, initial: true
      state :submitted
      state :approved
      state :rejected

      event :submit do
        transitions from: :draft, to: :submitted
      end
      event :approve do
        transitions from: :submitted, to: :approved
      end
      event :reject do
        transitions from: :submitted, to: :rejected
      end
      event :reopen do
        transitions from: %i[approved rejected], to: :draft
      end
    end

    def total_hours
      entries.sum(:hours)
    end

    def regular_hours
      entries.where(work_type: 'regular').sum(:hours)
    end

    def overtime_hours
      entries.where(work_type: 'overtime').sum(:hours)
    end

    def period_label
      "#{period_start.strftime('%b %d')} – #{period_end.strftime('%b %d, %Y')}"
    end

    # Display figures: 1% commission on credited sales plus the fixed card
    # bonus. Not posted to payroll.
    def compensation
      TimesheetCompensation.calculate(sales_cents: sales_cents, card_redemptions: card_redemptions)
    end

    def commission_cents
      compensation[:commission_cents]
    end

    def card_bonus_cents
      compensation[:card_bonus_cents]
    end

    def compensation_total_cents
      compensation[:total_cents]
    end

    def payroll_locked?
      People::Payslip.joins(:pay_run).where(employee_id: employee_id, pay_runs: { tenant_id: tenant_id })
        .where('pay_runs.period_start <= ? AND pay_runs.period_end >= ?', period_end, period_start).exists?
    end

    private

    def valid_demo_review
      errors.add(:demo, 'cannot be changed after creation') if persisted? && demo_changed?
      return unless assigned_reviewer_id

      errors.add(:assigned_reviewer, 'is available only for demo timesheets') unless demo?
      unless assigned_reviewer&.active? && assigned_reviewer.tenant_id == tenant_id && assigned_reviewer_id != employee&.user_id
        errors.add(:assigned_reviewer, 'must be another active account in this workspace')
      end
    end

    def locked_fields
      if persisted? && status_in_database != 'draft' && (changes.keys & %w[employee_id period_start period_end notes assigned_reviewer_id]).any?
        errors.add(:base, 'Only draft timesheets can be edited')
      end
      if persisted? && employee_id_changed? && entries.exists?
        errors.add(:employee, 'cannot be changed after entries have been added')
      end
    end

    def valid_employee_and_period
      unless employee && employee.tenant_id == tenant_id
        errors.add(:employee, 'must belong to this workspace')
      end
      return unless period_start && period_end
      errors.add(:period_end, 'must be within 31 days of the start') if period_end > period_start + 30
      overlapping = self.class.where(employee_id: employee_id).where.not(id: id)
        .where('period_start <= ? AND period_end >= ?', period_end, period_start)
      errors.add(:base, 'This staff member already has a timesheet overlapping this period') if overlapping.exists?
      if entries.where('worked_on < ? OR worked_on > ?', period_start, period_end).exists?
        errors.add(:base, 'The period must include all existing entries')
      end
    end

    def period_end_after_start
      return if period_start.nil? || period_end.nil?

      errors.add(:period_end, 'must be after the start') if period_end < period_start
    end
  end
end
