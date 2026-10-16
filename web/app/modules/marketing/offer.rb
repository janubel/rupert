# frozen_string_literal: true

module Marketing
  class Offer < Record
    self.table_name = 'marketing_offers'
    belongs_to :community
    before_validation do
      self.code = code.to_s.strip.upcase
      self.merchant_host = Urls.host(community&.campaign&.storefront_url)
    end
    before_update do
      self.verified_at = self.verified_by_id = nil if (changes.keys - %w[verified_at verified_by_id updated_at lock_version]).any?
    end
    validates :code, format: { with: /\A[A-Z0-9_-]{2,80}\z/ }, uniqueness: { scope: [:tenant_id, :merchant_host] }
    validates :terms, :starts_at, :ends_at, :destination_url, presence: true
    validates :terms, length: { maximum: 3000 }
    validate { same_tenant(:community) }
    validate { https_fields(:destination_url) }
    validate do
      errors.add(:ends_at, 'must be after start') unless starts_at && ends_at && ends_at > starts_at
      errors.add(:destination_url, 'must use the campaign storefront host') unless merchant_host.present? && Urls.host(destination_url) == merchant_host
      https_fields(:evidence_url) if evidence_url.present?
    end

    def shareable?
      starts_at && ends_at && starts_at <= Time.current && ends_at > Time.current &&
        verified_at && verified_at <= Time.current && verified_at > 24.hours.ago &&
        verified_by_id.present? && merchant_host == Urls.host(community.campaign.storefront_url) &&
        Urls.host(destination_url) == merchant_host
    end

    def referral_url
      uri = URI.parse(destination_url)
      query = URI.decode_www_form(uri.query.to_s).reject { |key, _| key.start_with?('utm_') }
      query.concat([['utm_source', "community-#{community_id}"], ['utm_medium', 'community'],
                    ['utm_campaign', "campaign-#{community.campaign_id}"], ['utm_content', "offer-#{id}"]])
      uri.query = URI.encode_www_form(query)
      uri.to_s
    end
  end
end
