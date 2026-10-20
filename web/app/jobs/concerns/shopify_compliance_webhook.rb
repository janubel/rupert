# frozen_string_literal: true

# Shared helpers for the Shopify GDPR/compliance webhook jobs. Every job
# resolves the workspace from the shop domain and runs with that tenant in
# context so TenantScoped models see the right rows.
module ShopifyComplianceWebhook
  extend ActiveSupport::Concern

  private

  def with_tenant_for(shop_domain)
    tenant = Tenant.find_by(shopify_shop_domain: shop_domain.to_s.downcase)
    if tenant.nil?
      logger.warn("#{self.class}: no workspace is linked to shop '#{shop_domain}'; nothing to do")
      return
    end

    # Current.user= clears the tenant, so only the tenant is set here (jobs never have a user).
    Current.set(tenant: tenant) { yield tenant }
  end

  # Shopify sends numeric ids in compliance payloads; mirrors store GraphQL
  # gids. Match both spellings.
  def shopify_gids(kind, ids)
    Array(ids).filter_map { |id| id.to_s.presence }.flat_map { |id| [id, "gid://shopify/#{kind}/#{id}"] }.uniq
  end
end
