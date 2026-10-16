# frozen_string_literal: true

module Marketing
  class Offer < Record
    self.table_name = 'marketing_offers'
    belongs_to :community, optional: true
    belongs_to :engagement, optional: true
    before_validation do
      self.code = code.to_s.strip.upcase
      self.merchant_host = Urls.host(campaign&.storefront_url)
    end
    before_update do
      self.verified_at = self.verified_by_id = nil if (changes.keys - %w[verified_at verified_by_id updated_at lock_version]).any?
    end
    validates :code, format: { with: /\A[A-Z0-9_-]{2,80}\z/ }, uniqueness: { scope: [:tenant_id, :merchant_host] }
    validates :terms, :starts_at, :ends_at, :destination_url, presence: true
    validates :terms, length: { maximum: 3000 }
    validate do
      errors.add(:base, 'Choose exactly one group or influencer collaboration') unless community_id.present? ^ engagement_id.present?
      same_tenant(:community) if community_id.present?
      same_tenant(:engagement) if engagement_id.present?
    end
    validate { https_fields(:destination_url) }
    validate do
      errors.add(:ends_at, 'must be after start') unless starts_at && ends_at && ends_at > starts_at
      errors.add(:destination_url, 'must use the campaign storefront host') unless merchant_host.present? && Urls.host(destination_url) == merchant_host
      https_fields(:evidence_url) if evidence_url.present?
    end

    def shareable?
      starts_at && ends_at && starts_at <= Time.current && ends_at > Time.current &&
        verified_at && verified_at <= Time.current && verified_at > 24.hours.ago &&
        verified_by_id.present? && merchant_host == Urls.host(campaign&.storefront_url) &&
        (engagement_id.nil? || engagement&.shareable?) &&
        Urls.host(destination_url) == merchant_host
    end

    def campaign
      community&.campaign || engagement&.campaign
    end

    def referral_url
      if engagement_id
        return ReferralUrl.build(destination_url, source: "influencer-#{engagement.influencer_id}", campaign: engagement.campaign_id, content: "offer-#{id}")
      end

      uri = URI.parse(destination_url)
      query = URI.decode_www_form(uri.query.to_s).reject { |key, _| key.start_with?('utm_') }
      query.concat([['utm_source', "community-#{community_id}"], ['utm_medium', 'community'],
                    ['utm_campaign', "campaign-#{community.campaign_id}"], ['utm_content', "offer-#{id}"]])
      uri.query = URI.encode_www_form(query)
      uri.to_s
    end
  end
end
