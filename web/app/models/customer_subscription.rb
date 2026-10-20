# frozen_string_literal: true

class CustomerSubscription < ApplicationRecord
  belongs_to :tenant
  validates :tenant_id, uniqueness: true
  validates :plan, inclusion: {in: %w[free monthly referral_year]}
  validates :status, inclusion: {in: %w[free incomplete incomplete_expired trialing active past_due canceled unpaid paused]}
  def paid?
    status == 'active'
  end
end
