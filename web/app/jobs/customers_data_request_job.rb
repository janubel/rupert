# frozen_string_literal: true

# Shopify `customers/data_request`: a customer asked the merchant for their
# data. The merchant has 30 days to answer. Rupert cannot email the customer
# itself, so it records the request in the audit trail for the operator to
# fulfil (export from Customers → the customer's page). The runbook explains
# the steps.
class CustomersDataRequestJob < ApplicationJob
  include ShopifyComplianceWebhook

  queue_as :default
  retry_on ActiveRecord::ActiveRecordError, wait: :polynomially_longer, attempts: 5

  def perform(shop_domain:, webhook:)
    with_tenant_for(shop_domain) do
      customer = webhook.fetch('customer', {}) || {}
      matches = Core::Customer.where(source: 'shopify', external_id: shopify_gids('Customer', [customer['id']])).count
      orders = Array(webhook['orders_requested']).length
      ActivityLogger.log('gdpr_data_request', actor: nil,
        details: "Shopify customers/data_request #{webhook['data_request']&.dig('id')} for customer #{customer['id']}: " \
                 "#{matches} matching profile(s), #{orders} order(s) requested. Respond within 30 days (see operator runbook).")
      logger.info("#{self.class}: recorded data request for '#{shop_domain}' customer #{customer['id']}")
    end
  end
end
