# frozen_string_literal: true

class SupportAccessEvent < ApplicationRecord
  belongs_to :tenant
  belongs_to :actor, class_name: 'User'
  belongs_to :support_access_grant, optional: true
  validates :action, inclusion: { in: %w[granted revoked viewed denied] }
  def readonly?
    persisted? || super
  end
end
