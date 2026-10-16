# frozen_string_literal: true

module Marketing
  class InfluencerOfferWriter
    FIELDS = %i[code terms destination_url starts_at ends_at evidence_url].freeze

    def self.write(offer, attributes:, actor:, version: nil, verify: false)
      actor = CmsWriter.authorize!(actor, verify ? 'marketing.review' : 'marketing.write')
      Offer.transaction do
        engagement = Engagement.find(offer.engagement_id)
        engagement.influencer.lock!
        engagement.lock!
        CmsWriter.lock!(offer, version)
        if verify
          raise ReplyWorkflow::Invalid, 'Activate the collaboration before confirming an offer.' unless engagement.shareable?
          raise ReplyWorkflow::Invalid, 'Record merchant verification evidence first.' if offer.evidence_url.blank?

          offer.assign_attributes(verified_at: Time.current, verified_by_id: actor.id)
        else
          offer.assign_attributes(attributes.slice(*FIELDS))
        end
        offer.save!
        CmsWriter.event!(offer, actor, verify ? 'merchant_evidence_confirmed' : 'saved')
        offer
      end
    end

    def self.copy(offer, actor:)
      actor = CmsWriter.authorize!(actor)
      Offer.transaction do
        offer.engagement.influencer.lock!
        offer.engagement.lock!
        offer.lock!
        raise ReplyWorkflow::Invalid, 'Check the active dates, collaboration and merchant evidence before sharing this offer.' unless offer.shareable?

        text = "#{offer.code}\n#{offer.terms}\nExpires: #{offer.ends_at.utc.iso8601}\n#{offer.referral_url}"
        CmsWriter.event!(offer, actor, 'offer_copy', { text: text })
        text
      end
    end
  end
end
