# frozen_string_literal: true

class RetentionDriveConnection < ApplicationRecord
  include TenantScoped
  encrypts :refresh_token
  encrypts :account_email
  validates :tenant_id, presence: true, uniqueness: true

  def connected?
    refresh_token.present? && generation.present?
  end
end
