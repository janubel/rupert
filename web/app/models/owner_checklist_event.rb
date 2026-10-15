# frozen_string_literal: true

require 'json'

class OwnerChecklistEvent < ApplicationRecord
  include TenantScoped

  PAYLOAD_FIELDS = %w[before after service_id feature_id actor_name actor_email].freeze

  encrypts :payload_json
  belongs_to :owner_checklist
  belongs_to :actor, class_name: 'User', optional: true

  validates :tenant_id, presence: true
  validates :action, inclusion: { in: %w[create update save_service review_feature] }
  validate :valid_history_payload
  validate :same_tenant_checklist
  validate :checked_writer, on: :create
  attr_accessor :writer_checked

  def data
    value = JSON.parse(payload_json.presence || '{}', max_nesting: 12)
    value.is_a?(Hash) ? value : {}
  rescue JSON::ParserError
    {}
  end

  def readonly?
    persisted? || super
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord, 'Checklist history is append-only.' if persisted?

    super
  end

  private

  def checked_writer
    errors.add(:base, 'Encrypted checklist history must be written with its checklist change.') unless writer_checked
  end

  def valid_history_payload
    value = data
    valid = payload_json.is_a?(String) && payload_json.valid_encoding? && payload_json.bytesize <= OwnerChecklist::MAX_PAYLOAD_BYTES &&
      value.keys.sort == PAYLOAD_FIELDS.sort && value['before'].is_a?(Hash) && value['after'].is_a?(Hash) &&
      value['actor_name'].is_a?(String) && value['actor_name'].length <= 500 &&
      value['actor_email'].is_a?(String) && value['actor_email'].length <= 254 &&
      (value['service_id'].nil? || (value['service_id'].is_a?(String) && OwnerChecklist::UUID.match?(value['service_id']))) &&
      (value['feature_id'].nil? || (value['feature_id'].is_a?(String) && value['feature_id'].match?(/\AF[0-9]{2,5}\z/)))
    errors.add(:base, 'Encrypted history must contain a bounded change and recorded operator snapshot.') unless valid
  end

  def same_tenant_checklist
    unless owner_checklist && owner_checklist.tenant_id == tenant_id
      errors.add(:owner_checklist, 'must belong to the same store')
    end
  end
end
