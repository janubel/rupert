# frozen_string_literal: true

module People
  # An HR record for a person on the team. Ties to a login account (User) when
  # they sign in to Rupert, plus the org structure (Department / Position) and
  # time-and-pay history.
  class Employee < ApplicationRecord
    include TenantScoped
    include AASM

    self.table_name = 'employees'

    # Original profiles remain as private audit records after consolidation.
    default_scope { where(merged_into_id: nil) }
    has_many :source_identities, class_name: 'EmployeeSourceIdentity', dependent: :restrict_with_exception
    before_destroy :protect_consolidation_history, prepend: true

    EMPLOYMENT_TYPES = %w[unspecified full_time part_time contractor seasonal].freeze

    belongs_to :user, optional: true
    belongs_to :department, class_name: 'People::Department', optional: true
    belongs_to :position, class_name: 'People::Position', optional: true
    has_many :pay_rates, class_name: 'People::PayRate', dependent: :destroy
    has_many :timesheets, class_name: 'People::Timesheet', dependent: :destroy
    has_many :timesheet_entries, through: :timesheets, source: :entries
    has_many :leave_balances, class_name: 'People::LeaveBalance', dependent: :destroy
    has_many :leave_requests, class_name: 'People::LeaveRequest', dependent: :destroy
    has_many :payslips, class_name: 'People::Payslip', dependent: :destroy
    has_many :managed_departments, class_name: 'People::Department', foreign_key: :manager_id, dependent: :nullify

    validates :first_name, presence: true
    validates :last_name, presence: true
    validates :employee_number, presence: true, uniqueness: { scope: :tenant_id }, allow_nil: true
    validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
    validates :employment_type, inclusion: { in: EMPLOYMENT_TYPES }
    validates :user_id, uniqueness: { scope: :tenant_id }, allow_nil: true, if: :user_id_changed?
    validate :termination_after_hire
    validate :associations_belong_to_workspace

    scope :ordered, -> { order(:last_name, :first_name) }
    scope :active, -> { where(status: 'active') }
    scope :on_payroll, -> { where(id: People::PayRate.current.pluck(:employee_id)) }
    scope :by_status, ->(status) { status.present? && status != 'all' ? where(status: status) : all }

    aasm column: 'status', no_direct_assignment: true do
      state :active, initial: true
      state :on_leave
      state :terminated

      event :place_on_leave do
        transitions from: :active, to: :on_leave
      end
      event :return_to_work do
        transitions from: :on_leave, to: :active
      end
      event :terminate do
        transitions from: %i[active on_leave], to: :terminated
      end
      event :rehire do
        transitions from: :terminated, to: :active
      end
    end

    def name
      "#{first_name} #{last_name}"
    end
    alias display_name name

    def full_name
      [first_name, legal_name == name ? nil : legal_name, last_name].compact.join(' ')
    end

    def current_pay_rate
      pay_rates.where('ended_on IS NULL OR ended_on >= ?', Date.current).order(effective_on: :desc).first
    end

    def on_payroll?
      active? && current_pay_rate.present?
    end

    def leave_balance(leave_type, year = Date.current.year)
      leave_balances.find_or_initialize_by(leave_type: leave_type, year: year) do |balance|
        balance.accrued_hours = default_accrual(leave_type)
      end
    end

    private

    def protect_consolidation_history
      return unless self.class.unscoped.where(tenant_id: tenant_id, merged_into_id: id).exists?

      errors.add(:base, 'This employee has consolidated profiles; retain the record and its history.')
      throw :abort
    end

    def associations_belong_to_workspace
      { user: User, department: People::Department, position: People::Position }.each do |association, model|
        foreign_key = "#{association}_id"
        next if self[foreign_key].blank?
        next if model.unscoped.exists?(id: self[foreign_key], tenant_id: tenant_id)

        errors.add(association, 'must belong to this workspace')
      end
    end

    def termination_after_hire
      return if hire_date.nil? || termination_date.nil?

      errors.add(:termination_date, 'must be after the hire date') if termination_date < hire_date
    end

    def default_accrual(leave_type)
      case leave_type
      when 'vacation' then 80.0
      when 'sick' then 40.0
      else 0.0
      end
    end
  end
end
