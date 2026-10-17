# frozen_string_literal: true

require 'digest'
class EmployeeAccessGrant < ApplicationRecord
  include TenantScoped
  belongs_to :user
  belongs_to :employee, -> { unscope(where: :tenant_id) }, class_name: 'People::Employee'

  def self.issue!(employee)
    transaction do
      Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at')
      employee = People::Employee.find(employee.id)
      raise TimesheetWorkflow::Error, 'An active staff member with an email address is required.' unless employee.active? && employee.email.present?
      if employee.source_identities.exists? && !employee.source_identities.where(source_active: [true, nil]).exists?
        raise TimesheetWorkflow::Error, 'All source accounts are inactive; confirm employment before issuing access.'
      end
      email = employee.email.strip.downcase
      if People::Employee.where('LOWER(TRIM(email)) = ?', email).where.not(id: employee.id).exists?
        raise TimesheetWorkflow::Error, 'This email is shared by multiple staff; confirm identity or use an individual email.'
      end
      user = employee.user
      if user
        raise TimesheetWorkflow::Error, 'Manage this existing account through Accounts; setup links are only for the staff role.' unless user.employee? && user.active? && user.tenant_id == Current.tenant_id
      else
        raise TimesheetWorkflow::Error, 'An account already uses this email. Link the verified existing account through the staff record.' if User.where('LOWER(TRIM(email)) = ?', email).exists?
        user = User.create!(tenant: Current.tenant, email: email, name: employee.name,
          role: 'employee', password: SecureRandom.urlsafe_base64(48))
        employee.update!(user: user)
      end
      where(user_id: user.id, used_at: nil).update_all(used_at: Time.current)
      secret = SecureRandom.urlsafe_base64(32)
      create!(user: user, employee: employee, token_digest: Digest::SHA256.hexdigest(secret), expires_at: 24.hours.from_now)
      secret
    end
  end

  def self.lookup(secret)
    return unless secret.to_s.match?(/\A[A-Za-z0-9_-]{43}\z/)
    unscoped.includes(:user, :employee, :tenant).find_by(token_digest: Digest::SHA256.hexdigest(secret))
  end

  def usable?
    used_at.nil? && expires_at > Time.current && tenant&.status == 'active' && user&.active? && user.employee? &&
      employee&.active? && employee.user_id == user_id && employee.tenant_id == tenant_id && user.tenant_id == tenant_id
  end
end
