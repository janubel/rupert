# frozen_string_literal: true

module Marketing
  class ShopifyDiscount < Record
    self.table_name = 'marketing_shopify_discounts'
    STATUSES = %w[draft creating created uncertain failed blocked].freeze
    belongs_to :offer
    encrypts :request_json, :remote_json, :last_error
    validates :shop_domain, :shop_id, :currency, :request_key, :request_json, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :offer_id, :request_key, uniqueness: true
    validates :shop_domain, format: { with: /\A[a-z0-9][a-z0-9-]*\.myshopify\.com\z/ }
    validate { same_tenant(:offer) }
    validate do
      errors.add(:offer, 'must be an influencer offer') unless offer&.engagement_id && offer.community_id.nil?
      if persisted? && (changed & %w[tenant_id offer_id shop_domain shop_id currency request_key request_json]).any?
        errors.add(:base, 'Create a new draft to change the reviewed Shopify offer')
      end
    end

    def input
      JSON.parse(request_json)
    end

    def ready?
      status == 'created' && remote_status == 'ACTIVE' && checked_at && checked_at <= Time.current && checked_at > 24.hours.ago
    end

    def admin_url
      return unless remote_id.to_s.match?(%r{\Agid://shopify/DiscountCodeNode/\d+\z})

      "https://#{shop_domain}/admin/discounts/#{remote_id.split('/').last}"
    end
  end
end
