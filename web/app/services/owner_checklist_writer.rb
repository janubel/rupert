# frozen_string_literal: true

require 'json'
require 'securerandom'

# Local encrypted references and owner attestations only. Nothing here contacts
# a domain/vendor, verifies ownership, stores credentials or changes readiness.
class OwnerChecklistWriter
  class << self
    def create(attributes:, actor:)
      actor, tenant = context!(actor)
      checklist = OwnerChecklist.new(tenant_id: tenant.id, created_by: actor, updated_by: actor, writer_checked: true)
      fields = permitted(attributes, OwnerChecklist::METADATA_FIELDS, checklist)
      value = OwnerChecklist::METADATA_FIELDS.index_with { '' }.merge(fields)
      value['domain'] = value['domain'].strip.downcase if value['domain'].is_a?(String) && value['domain'].valid_encoding?
      value.merge!('services' => {}, 'feature_reviews' => {})
      return checklist unless prepare(checklist, value)
      return checklist if checklist.errors.any?

      OwnerChecklist.transaction do
        checklist.save!
        history!(checklist, actor, 'create', before: {}, after: value)
      end
      checklist.writer_checked = false
      checklist
    end

    def update(checklist:, attributes:, lock_version:, actor:)
      actor, checklist, version = editable!(checklist, lock_version, actor)
      fields = permitted(attributes, OwnerChecklist::METADATA_FIELDS, checklist)
      value = checklist.data.deep_dup
      before = value.slice(*OwnerChecklist::METADATA_FIELDS)
      value.merge!(fields)
      value['domain'] = value['domain'].strip.downcase if value['domain'].is_a?(String) && value['domain'].valid_encoding?
      persist(checklist, value, version, actor, 'update', before: before,
        after: value.slice(*OwnerChecklist::METADATA_FIELDS))
    end

    def save_service(checklist:, service_id: nil, attributes:, lock_version:, actor:)
      actor, checklist, version = editable!(checklist, lock_version, actor)
      fields = permitted(attributes, OwnerChecklist::SERVICE_FIELDS, checklist)
      value = checklist.data.deep_dup
      if service_id.nil? || service_id == ''
        service_id = SecureRandom.uuid
        before = {}
        service = OwnerChecklist::SERVICE_FIELDS.index_with { '' }.merge(
          'renewal_cadence' => 'unspecified', 'review_cadence' => 'unspecified', 'mfa_status' => 'unknown', 'archived' => false)
      elsif service_id.is_a?(String) && OwnerChecklist::UUID.match?(service_id) && value['services'].key?(service_id)
        before = value['services'].fetch(service_id).deep_dup
        service = before.deep_dup
      else
        checklist.errors.add(:base, 'Choose a saved service belonging to this checklist.')
        return checklist
      end
      service.merge!(fields)
      service['archived'] = strict_boolean(service['archived'])
      value['services'][service_id] = service
      persist(checklist, value, version, actor, 'save_service', before: before, after: service, service_id: service_id)
    end

    def review_feature(checklist:, feature_id:, attributes:, lock_version:, actor:, expected_catalog_fingerprint: nil)
      actor, checklist, version = editable!(checklist, lock_version, actor)
      fields = permitted(attributes, %w[status evidence tested_on attest_scope], checklist)
      feature = OwnerChecklist.features.find { |entry| entry['id'] == feature_id }
      unless feature
        checklist.errors.add(:base, 'Choose a feature from the current published catalog.')
        return checklist
      end
      current_fingerprint = OwnerChecklist.catalog_fingerprint(feature)
      if (expected_catalog_fingerprint.nil? && %w[passed not_required].include?(fields['status'])) ||
          (!expected_catalog_fingerprint.nil? && expected_catalog_fingerprint != current_fingerprint)
        checklist.errors.add(:base, 'Published feature scope changed or was not confirmed. Reload it and review the current scope before saving.')
        return checklist
      end
      value = checklist.data.deep_dup
      before = value['feature_reviews'].fetch(feature_id, {}).deep_dup
      review = { 'status' => 'not_reviewed', 'evidence' => '', 'tested_on' => '', 'attest_scope' => false }.merge(fields)
      review.merge!('reviewer' => actor.email.to_s, 'attest_scope' => strict_boolean(review['attest_scope']),
        'catalog_fingerprint' => current_fingerprint, 'catalog_name' => feature.fetch('name'),
        'catalog_scope' => feature.fetch('scope'), 'catalog_status' => feature.fetch('status'))
      value['feature_reviews'][feature_id] = review
      persist(checklist, value, version, actor, 'review_feature', before: before, after: review, feature_id: feature_id)
    end

    private

    def context!(actor)
      raise ActiveRecord::RecordNotFound unless actor.is_a?(User) && actor.persisted? && Current.tenant_id.present?

      fresh_actor = User.find_by(id: actor.id, active: true)
      tenant = Tenant.unscoped.find_by(id: Current.tenant_id, status: 'active')
      unless fresh_actor && tenant && %w[admin super_admin].include?(fresh_actor.role) &&
          (fresh_actor.super_admin? || fresh_actor.tenant_id == tenant.id)
        raise ActiveRecord::RecordNotFound
      end

      [fresh_actor, tenant]
    end

    def editable!(checklist, lock_version, actor)
      actor, tenant = context!(actor)
      unless checklist.is_a?(OwnerChecklist) && checklist.persisted? && checklist.tenant_id == tenant.id
        raise ActiveRecord::RecordNotFound
      end

      text = lock_version.to_s
      unless (lock_version.is_a?(String) || lock_version.is_a?(Integer)) && text.match?(/\A(?:0|[1-9][0-9]{0,9})\z/) && text.to_i < 2_147_483_647
        raise ActiveRecord::StaleObjectError.new(checklist, 'update')
      end
      # Refresh before constructing the merged JSON. Supplying a newer version
      # alongside an old Ruby object must not discard another section's edits.
      fresh = OwnerChecklist.where(tenant_id: tenant.id).find(checklist.id)
      version = text.to_i
      raise ActiveRecord::StaleObjectError.new(fresh, 'update') unless fresh.lock_version == version

      fresh.writer_checked = true
      [actor, fresh, version]
    end

    def permitted(attributes, allowed, checklist)
      unless attributes.is_a?(Hash) && attributes.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }
        checklist.errors.add(:base, 'Checklist input must contain supported fields.')
        return {}
      end
      fields = attributes.stringify_keys
      checklist.errors.add(:base, 'Checklist input contains unsupported fields. Store vault item labels instead of credentials.') unless (fields.keys - allowed).empty?
      fields.slice(*allowed)
    end

    def strict_boolean(value)
      return true if value == true || value == '1'
      return false if value == false || value == '0' || value.nil?

      value
    end

    def prepare(checklist, value)
      checklist.payload_json = JSON.generate(value)
      input_errors = checklist.errors.full_messages
      checklist.valid?
      input_errors.each { |error| checklist.errors.add(:base, error) }
      checklist.errors.empty?
    rescue JSON::GeneratorError, JSON::NestingError, EncodingError
      checklist.errors.add(:base, 'Checklist input must be valid text within its field limits.')
      false
    end

    def persist(checklist, value, version, actor, action, **event)
      return checklist unless prepare(checklist, value)

      # The first statement in the transaction is the conditional write. This
      # avoids SQLite read-to-write lock upgrades, and detects competing forms.
      OwnerChecklist.transaction do
        updated = OwnerChecklist.where(tenant_id: checklist.tenant_id, id: checklist.id, lock_version: version).update_all(
          payload_json: checklist.payload_json, updated_by_id: actor.id, updated_at: Time.current, lock_version: version + 1)
        raise ActiveRecord::StaleObjectError.new(checklist, 'update') unless updated == 1

        history!(checklist, actor, action, **event)
      end
      checklist.reload
      checklist.writer_checked = false
      checklist
    end

    def history!(checklist, actor, action, before:, after:, service_id: nil, feature_id: nil)
      OwnerChecklistEvent.create!(tenant_id: checklist.tenant_id, owner_checklist: checklist, actor: actor, action: action,
        payload_json: JSON.generate('before' => before, 'after' => after, 'service_id' => service_id, 'feature_id' => feature_id,
          'actor_name' => actor.display_name.to_s.truncate(500, omission: ''), 'actor_email' => actor.email.to_s), writer_checked: true)
    end
  end
end
