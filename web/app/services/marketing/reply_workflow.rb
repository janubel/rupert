# frozen_string_literal: true

require 'digest'

module Marketing
  class ReplyWorkflow
    class Invalid < StandardError; end

    def self.call(reply, action:, actor:, version: nil, attributes: {}, note: nil, published_url: nil)
      permission = %w[approve reject changes].include?(action) ? 'marketing.review' : 'marketing.write'
      unless actor&.active? && actor.can?('marketing.read') && actor.can?(permission) &&
          Current.tenant&.status == 'active' && (actor.super_admin? || actor.tenant_id == Current.tenant_id)
        raise Pundit::NotAuthorizedError
      end
      raise Invalid, 'Reply belongs to another workspace' unless reply.tenant_id == Current.tenant_id || reply.new_record?

      Reply.transaction do
        # All reply operations serialize on the campaign first, then dependencies.
        thread = Thread.find(reply.thread_id)
        community = Community.find(thread.community_id)
        campaign = Campaign.lock.find(community.campaign_id)
        community.lock!
        thread.lock!
        reply.lock! if reply.persisted?
        if reply.persisted? && (version.to_s !~ /\A\d+\z/ || reply.lock_version != version.to_i)
          raise Invalid, 'This reply changed. Reload before continuing.'
        end
        reply.workflow_write = true
        reply.assign_attributes(attributes.slice(:body, :affiliation, :offer_id)) if action == 'save'
        offer = Offer.lock.find(reply.offer_id)
        raise Invalid, 'Offer must belong to this thread community' unless offer.community_id == community.id

        context = {
          body: reply.body, affiliation: reply.affiliation,
          campaign: campaign.attributes.slice('id', 'name', 'storefront_url', 'topics', 'lock_version'),
          community: community.attributes.except('created_at', 'updated_at'),
          thread: thread.attributes.except('created_at', 'updated_at'),
          offer: offer.attributes.except('created_at', 'updated_at'),
          text: "#{reply.body}\n\n#{reply.affiliation}\nCode: #{offer.code}\n#{offer.terms}\nOffer ends: #{offer.ends_at&.utc&.iso8601}\n#{offer.referral_url}"
        }
        digest = Digest::SHA256.hexdigest(JSON.generate(context))
        case action
        when 'save'
          raise Invalid, 'Published or removed replies cannot be edited' if %w[published removed].include?(reply.status)

          reply.assign_attributes(status: 'draft', snapshot_json: nil, snapshot_digest: nil)
        when 'submit'
          require_status!(reply, %w[draft rejected])
          require_eligible!(thread, offer)
          reply.assign_attributes(status: 'pending_review', snapshot_json: JSON.generate(context), snapshot_digest: digest)
        when 'approve', 'copy', 'publish'
          require_status!(reply, action == 'approve' ? ['pending_review'] : ['approved'])
          require_eligible!(thread, offer)
          raise Invalid, 'Context or offer changed. Edit and submit a fresh review.' unless reply.snapshot_digest == digest

          reply.status = 'approved' if action == 'approve'
          if action == 'publish'
            raise Invalid, 'Add the published reply URL' if published_url.blank?

            reply.assign_attributes(status: 'published', published_url: published_url, published_at: Time.current)
          end
        when 'reject', 'changes'
          require_status!(reply, ['pending_review'])
          raise Invalid, 'Add a review note' if note.blank?

          reply.status = action == 'reject' ? 'rejected' : 'draft'
        when 'remove'
          require_status!(reply, ['published'])
          raise Invalid, 'Add a removal note' if note.blank?

          reply.status = 'removed'
        else
          raise Invalid, 'Unknown reply action'
        end
        raise Invalid, 'Note is too long' if note.to_s.length > 3000

        reply.save!
        reply.review_events.create!(tenant_id: Current.tenant_id, actor_id: actor.id, action: action,
          payload_json: JSON.generate({ revision: reply.lock_version, note: note,
                                      body: reply.body, affiliation: reply.affiliation, offer_id: reply.offer_id,
                                      snapshot: reply.snapshot_json, published_url: reply.published_url }))
        action == 'copy' ? JSON.parse(reply.snapshot_json).fetch('text') : reply
      end
    end

    def self.require_status!(reply, states)
      raise Invalid, 'This action is unavailable in the current state' unless states.include?(reply.status)
    end

    def self.require_eligible!(thread, offer)
      raise Invalid, 'Review current group rules and an open, relevant thread (within 7 days)' unless thread.eligible?
      raise Invalid, 'Verify an active group offer within the last 24 hours' unless offer.shareable?
    end
  end
end
