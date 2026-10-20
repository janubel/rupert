# frozen_string_literal: true

# Shopify `shop/redact`: 48 hours after uninstall Shopify asks the app to erase
# the shop's data. Rupert is the merchant's own self-hosted system of record,
# so business data is NOT deleted automatically; the Shopify session (offline
# token) is removed and the request is written to the audit trail so the
# operator can decide on a data purge.
class ShopRedactJob < ApplicationJob
  include ShopifyComplianceWebhook

  queue_as :default
  retry_on ActiveRecord::ActiveRecordError, wait: :polynomially_longer, attempts: 5

  def perform(shop_domain:, webhook:)
    removed = Shop.where(shopify_domain: shop_domain).destroy_all.length
    with_tenant_for(shop_domain) do
      ActivityLogger.log('gdpr_shop_redacted', actor: nil,
        details: "Shopify shop/redact for #{shop_domain} (shop id #{webhook['shop_id']}): #{removed} session(s) removed; " \
                 'business records retained pending operator review.')
    end
    logger.info("#{self.class}: removed #{removed} session(s) for '#{shop_domain}'")
  end
end
