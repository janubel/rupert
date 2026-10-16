# frozen_string_literal: true

require 'digest'
class EmployeeAppSession < ApplicationRecord
  include TenantScoped
  belongs_to :user
  belongs_to :employee, -> { unscope(where: :tenant_id) }, class_name: 'People::Employee'
  validates :device_name, length: { in: 1..80 }
  validates :token_digest, :expires_at, :password_fingerprint, presence: true

  def self.issue!(user:, device_name:)
    employee = TimeClockService.worker_for(user)
    raise TimesheetWorkflow::Error, 'Ask an administrator to link one active employee record to your account.' unless employee
    secret = "rupert_employee_#{SecureRandom.urlsafe_base64(32)}"
    session = create!(user: user, employee: employee, device_name: device_name.to_s.strip,
      token_digest: Digest::SHA256.hexdigest(secret), expires_at: 30.days.from_now,
      password_fingerprint: Digest::SHA256.hexdigest(user.password_digest))
    [session, secret]
  end

  def self.authenticate(secret)
    return unless secret.to_s.match?(/\Arupert_employee_[A-Za-z0-9_-]{43}\z/)
    record = unscoped.includes(:user, :tenant, :employee).find_by(token_digest: Digest::SHA256.hexdigest(secret))
    record if record&.usable?
  end

  def usable?
    revoked_at.nil? && expires_at > Time.current && user&.active? && tenant&.status == 'active' &&
      user.tenant_id == tenant_id && employee&.active? && employee.tenant_id == tenant_id && employee.user_id == user_id &&
      People::Employee.unscoped.where(tenant_id: tenant_id, user_id: user_id, status: 'active').count == 1 &&
      ActiveSupport::SecurityUtils.secure_compare(password_fingerprint, Digest::SHA256.hexdigest(user.password_digest))
  end
end
