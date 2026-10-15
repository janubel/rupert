# frozen_string_literal: true

class WorkspaceSignupEvent < ApplicationRecord
  encrypts :payload_json
  belongs_to :workspace_signup
  belongs_to :actor, class_name: 'User', optional: true
  attr_accessor :writer_checked

  validates :action, inclusion: { in: %w[requested approved rejected] }
  validates :payload_json, presence: true, length: { maximum: 16_384 }
  validate(on: :create) { errors.add(:base, 'Use the signup service to record history.') unless writer_checked }

  def data
    JSON.parse(payload_json)
  end

  def readonly?
    persisted? || super
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord, 'Signup history is append-only.' if persisted?

    super
  end
end
