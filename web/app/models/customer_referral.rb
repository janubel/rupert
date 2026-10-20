# frozen_string_literal: true

class CustomerReferral < ApplicationRecord
  belongs_to :tenant
  before_validation { self.code = code.to_s.strip.upcase }
  validates :code, uniqueness: true, format: { with: /\A[A-Z0-9-]{6,40}\z/ }
  validates :tenant_id, uniqueness: true
  def self.eligible(code, tenant:)
    referral = find_by(code: code.to_s.strip.upcase, active: true)
    return unless referral && referral.tenant_id != tenant.id && referral.tenant.status == 'active'
    referral if CustomerSubscription.exists?(tenant_id: referral.tenant_id, status: 'active')
  end
end
