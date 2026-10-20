# frozen_string_literal: true

class CustomerReferral < ApplicationRecord
  belongs_to :tenant
  before_validation { self.code = code.to_s.strip.upcase }
  validates :code, uniqueness: true, format: { with: /\A[A-Z0-9-]{6,40}\z/ }
  validates :tenant_id, uniqueness: true
  # Deployment-owned invitations can include existing customers billed outside
  # Stripe. Never manufacture a paid subscription to make a referral eligible.
  def self.approved_codes
    ENV.fetch('RUPERT_APPROVED_REFERRAL_CODES', '').split(',').map { |value| value.strip.upcase }.reject(&:blank?).uniq
  end

  def self.eligible(code, tenant:)
    referral = find_by(code: code.to_s.strip.upcase, active: true)
    return unless referral && referral.tenant_id != tenant.id && referral.tenant.status == 'active'
    approved = approved_codes
    return approved.include?(referral.code) ? referral : nil if approved.any?
    referral if CustomerSubscription.exists?(tenant_id: referral.tenant_id, status: 'active')
  end
end
