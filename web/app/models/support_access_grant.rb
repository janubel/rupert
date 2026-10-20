# frozen_string_literal: true

class SupportAccessGrant < ApplicationRecord
  encrypts :reason
  belongs_to :tenant
  belongs_to :granted_by, class_name: 'User'
  belongs_to :support_user, class_name: 'User'
  validates :reason, presence: true, length: { maximum: 300 }
  validate do
    errors.add(:granted_by, 'must administer this workspace') unless granted_by&.active? && granted_by&.admin? && granted_by.tenant_id == tenant_id
    errors.add(:support_user, 'must be an active platform administrator') unless support_user&.active? && support_user&.super_admin?
    errors.add(:expires_at, 'must be within the next 24 hours') unless expires_at && expires_at > Time.current && expires_at <= 24.hours.from_now
  end
  scope :current, -> { where(revoked_at: nil).where('expires_at > ?', Time.current) }
end
