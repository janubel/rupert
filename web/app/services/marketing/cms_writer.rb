# frozen_string_literal: true

module Marketing
  class CmsWriter
    INFLUENCER_FIELDS = %i[name platform handle profile_url topics stage owner_id next_follow_up_at notes].freeze
    ENGAGEMENT_FIELDS = %i[campaign_id title status deliverables due_at destination_url].freeze

    def self.authorize!(actor, permission = 'marketing.write', contacts: false)
      actor = User.find_by(id: actor&.id, active: true)
      unless actor && Current.tenant&.status == 'active' && FeatureFlag.enabled?(:marketing) &&
          (actor.super_admin? || actor.tenant_id == Current.tenant_id) && actor.can?('marketing.read') && actor.can?(permission) &&
          (!contacts || actor.can?('marketing.contacts'))
        raise Pundit::NotAuthorizedError
      end
      actor
    end

    def self.lock!(record, version)
      raise ActiveRecord::RecordNotFound unless record.new_record? || record.tenant_id == Current.tenant_id

      if record.persisted?
        record.lock!
        unless version.to_s.match?(/\A\d+\z/) && record.lock_version == version.to_i
          raise ReplyWorkflow::Invalid, 'This record changed. Reload before continuing.'
        end
      else
        record.tenant_id = Current.tenant_id
      end
    end

    def self.event!(record, actor, action, payload = nil)
      CmsEvent.create!(tenant_id: Current.tenant_id, actor_id: actor.id, subject_type: record.class.name,
        subject_id: record.id, action: action, payload_json: JSON.generate(payload || record.attributes))
    end

    def self.write(record, attributes:, actor:, version: nil)
      raise ArgumentError, 'Unsupported CMS record' unless record.is_a?(Influencer) || record.is_a?(Engagement)

      private_input = record.is_a?(Influencer) && (attributes.keys.map(&:to_sym) & Influencer::PRIVATE_FIELDS).any?
      actor = authorize!(actor, contacts: private_input)
      record.class.transaction do
        lock!(record, version)
        fields = record.is_a?(Influencer) ? INFLUENCER_FIELDS + Influencer::PRIVATE_FIELDS : ENGAGEMENT_FIELDS
        if record.is_a?(Engagement) && record.persisted? && attributes[:campaign_id].present? && attributes[:campaign_id].to_i != record.campaign_id
          raise ReplyWorkflow::Invalid, 'Create a separate collaboration to use another campaign.'
        end
        record.assign_attributes(attributes.slice(*fields))
        record.save!
        event!(record, actor, 'saved')
        record
      end
    end

    def self.log_interaction(influencer, attributes:, actor:)
      actor = authorize!(actor, contacts: true)
      Influencer.transaction do
        influencer.lock!
        raise ActiveRecord::RecordNotFound unless influencer.tenant_id == Current.tenant_id

        influencer.interactions.create!(attributes.slice(:kind, :body, :occurred_at).merge(tenant_id: Current.tenant_id, actor_id: actor.id))
        event!(influencer, actor, 'interaction_recorded', { kind: attributes[:kind], occurred_at: attributes[:occurred_at] })
      end
    end

    def self.copy_engagement(engagement, actor:)
      actor = authorize!(actor)
      raise ActiveRecord::RecordNotFound unless engagement.tenant_id == Current.tenant_id

      Engagement.transaction do
        engagement.influencer.lock!
        engagement.lock!
        raise ReplyWorkflow::Invalid, 'Activate this collaboration and check the influencer contact status before sharing.' unless engagement.shareable?

        url = engagement.referral_url
        event!(engagement, actor, 'referral_copy', { url: url })
        url
      end
    end
  end
end
