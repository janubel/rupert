# frozen_string_literal: true

module Marketing
  class Engagement < Record
    self.table_name = 'marketing_engagements'
    STATUSES = %w[draft active completed cancelled].freeze
    belongs_to :influencer
    belongs_to :campaign
    has_many :product_gifts, class_name: 'Marketing::ProductGift'
    has_many :offers, class_name: 'Marketing::Offer'
    has_many :documents, class_name: 'Marketing::Document'
    validates :title, presence: true, length: { maximum: 200 }
    validates :deliverables, length: { maximum: 5000 }
    validates :status, inclusion: { in: STATUSES }
    validate { same_tenant(:influencer, :campaign) }
    validate { https_fields(:destination_url) }
    validate do
      errors.add(:destination_url, 'must use the campaign storefront host') unless Urls.host(destination_url).present? && Urls.host(destination_url) == Urls.host(campaign&.storefront_url)
    end

    def shareable?
      status == 'active' && influencer.contactable? && Urls.host(destination_url) == Urls.host(campaign.storefront_url)
    end

    def referral_url
      ReferralUrl.build(destination_url, source: "influencer-#{influencer_id}", campaign: campaign_id, content: "engagement-#{id}")
    end
  end
end
