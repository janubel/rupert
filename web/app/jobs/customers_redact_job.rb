# frozen_string_literal: true

# Shopify `customers/redact`: 48 hours after a merchant deletes a customer (or
# 10 days after uninstall) Shopify asks the app to erase that customer's
# personal data. Rupert keeps the order history (it is the merchant's sales
# record) but strips every personal field from the customer profile and the
# listed orders' shipping details.
class CustomersRedactJob < ApplicationJob
  include ShopifyComplianceWebhook

  queue_as :default
  retry_on ActiveRecord::ActiveRecordError, wait: :polynomially_longer, attempts: 5

  CUSTOMER_FIELDS = { first_name: nil, last_name: nil, email: nil, phone: nil, preferred_name: nil, notes: nil, tags: nil }.freeze
  ORDER_FIELDS = %i[shipping_name shipping_address1 shipping_address2 shipping_city shipping_province shipping_zip
    shipping_country shipping_phone].index_with(nil).freeze

  def perform(shop_domain:, webhook:)
    with_tenant_for(shop_domain) do
      customer = webhook.fetch('customer', {}) || {}
      customers = Core::Customer.where(source: 'shopify')
      ids = shopify_gids('Customer', [customer['id']])
      email = customer['email'].to_s.strip.downcase
      scope = customers.where(external_id: ids)
      scope = scope.or(customers.where('lower(email) = ?', email)) if email.present?
      redacted_customers = scope.update_all(CUSTOMER_FIELDS.merge(updated_at: Time.current))

      order_ids = shopify_gids('Order', webhook['orders_to_redact'])
      redacted_orders = if order_ids.any?
        Core::Order.where(source: 'shopify', source_order_id: order_ids).update_all(ORDER_FIELDS.merge(updated_at: Time.current))
      else
        0
      end

      ActivityLogger.log('gdpr_customer_redacted', actor: nil,
        details: "Shopify customers/redact for customer #{customer['id']}: #{redacted_customers} profile(s), #{redacted_orders} order shipping record(s) cleared")
      logger.info("#{self.class}: redacted #{redacted_customers} customer(s) and #{redacted_orders} order(s) for '#{shop_domain}'")
    end
  end
end
