# frozen_string_literal: true

# Shopify `app/uninstalled`: drop the offline session so no further Admin API
# calls are attempted with a revoked token. Mirrored business data stays.
class AppUninstalledJob < ApplicationJob
  include ShopifyComplianceWebhook

  queue_as :default
  retry_on ActiveRecord::ActiveRecordError, wait: :polynomially_longer, attempts: 5

  def perform(shop_domain:, webhook:)
    removed = Shop.where(shopify_domain: shop_domain).destroy_all.length
    with_tenant_for(shop_domain) do
      ActivityLogger.log('shopify_app_uninstalled', actor: nil,
        details: "Shopify reported the app uninstalled from #{shop_domain}; #{removed} session(s) removed.")
    end
    logger.info("#{self.class}: app uninstalled from '#{shop_domain}' (#{removed} session(s) removed)")
  end
end
