# frozen_string_literal: true

# A private employee problem report. No email, external message or job is sent.
class EmployeeWorkReport < ApplicationRecord
  include TenantScoped
  KINDS = { 'time' => 'Hours or time clock', 'pay' => 'Pay', 'time_off' => 'Time off', 'other' => 'Something else' }.freeze
  STATUSES = %w[open in_review resolved].freeze
  belongs_to :employee, class_name: 'People::Employee'
  belongs_to :requester, class_name: 'User', optional: true
  belongs_to :reviewer, class_name: 'User', optional: true
  attr_readonly :tenant_id, :employee_id, :requester_id, :kind, :details, :request_key
  validates :kind, inclusion: { in: KINDS.keys }
  validates :status, inclusion: { in: STATUSES }
  validates :details, presence: true, length: { maximum: 2000 }
  validates :response, length: { maximum: 2000 }
  validates :request_key, format: { with: /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i }
  validate :same_workspace

  private

  def same_workspace
    errors.add(:employee, 'must belong to this workspace') unless employee && employee.tenant_id == tenant_id
    errors.add(:requester, 'must belong to this workspace') if requester && requester.tenant_id != tenant_id
    errors.add(:reviewer, 'must belong to this workspace') if reviewer && !reviewer.super_admin? && reviewer.tenant_id != tenant_id
  end
end
