# frozen_string_literal: true

class EmployeeSourceIdentity < ApplicationRecord
  include TenantScoped
  belongs_to :employee, class_name: 'People::Employee'
  validates :source, :external_id, presence: true
  validates :external_id, uniqueness: { scope: %i[tenant_id source] }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validate :same_workspace

  private

  def same_workspace
    errors.add(:employee, 'must belong to this workspace') unless employee && employee.tenant_id == tenant_id
  end
end
