# frozen_string_literal: true

# Global search across the ERP: orders, customers, and SKUs. Returns a small,
# ranked list of results for the command-palette dropdown.
require 'digest'

class SearchService
  Result = Struct.new(:type, :label, :sub_label, :path, keyword_init: true)

  class << self
    def search(query, limit: 8)
      term = query.to_s.strip
      return [] if term.length < 2

      user = Current.user
      user_key = Current.user&.id || 'anonymous'
      key = "global_search/#{Current.tenant_id || 'no-tenant'}/#{user_key}/permissions-#{user&.permissions_signature || 'none'}/#{Digest::SHA256.hexdigest(term.downcase)}/#{limit}"
      DataCache.fetch(key, ttl: 2.minutes) do
        results = []
        results.concat(search_orders(term)) if user&.can?('sales.read')
        results.concat(search_customers(term)) if user&.can?('customers.read')
        results.concat(search_variants(term)) if user&.can?('inventory.read')
        results.concat(search_employees(term)) if user&.can?('hr.read')
        results.first(limit)
      end
    end

    private

    def search_orders(term)
      SearchSql.match(
        Core::Order.where(tenant_id: Current.tenant_id), model: Core::Order,
        fts_table: 'rupert_orders_fts', columns: %w[order_number source_order_id], term: term
      )
                 .order(occurred_at: :desc)
                 .limit(5)
                 .map do |order|
                   Result.new(
                     type: 'order',
                     label: order.display_number,
                     sub_label: "#{order.channel} · #{number(order.gross_cents / 100.0)}",
                     path: Rails.application.routes.url_helpers.order_path(order)
                   )
                 end
    end

    def search_customers(term)
      SearchSql.match(
        Core::Customer.where(tenant_id: Current.tenant_id), model: Core::Customer,
        fts_table: 'rupert_customers_fts', columns: %w[first_name last_name email phone], term: term
      )
                    .order(:first_name)
                    .limit(5)
                    .map do |customer|
                      Result.new(
                        type: 'customer',
                        label: customer.name,
                        sub_label: customer.email.presence || customer.phone.presence || customer.source,
                        path: Rails.application.routes.url_helpers.customer_path(customer)
                      )
                    end
    end

    def search_variants(term)
      SearchSql.match(
        ShopifyVariant.where(tenant_id: Current.tenant_id), model: ShopifyVariant,
        fts_table: 'rupert_shopifyvariant_fts',
        columns: %w["ShopifyVariant".sku "ShopifyVariant".title], term: term,
        row_key: 'rowid'
      )
                    .joins(:product)
                    .order(:sku)
                    .limit(5)
                    .map do |variant|
                      Result.new(
                        type: 'sku',
                        label: variant.sku.presence || variant.title,
                        sub_label: "#{variant.product&.title} · #{number(variant.price.to_f)}",
                        path: Rails.application.routes.url_helpers.shopify_variant_path(variant)
                      )
                    end
    end

    def search_employees(term)
      SearchSql.match(
        People::Employee.where(tenant_id: Current.tenant_id), model: People::Employee,
        fts_table: 'rupert_people_employees_fts',
        columns: %w[first_name last_name employee_number email], term: term
      )
                      .order(:last_name)
                      .limit(5)
                      .map do |employee|
                        Result.new(
                          type: 'employee',
                          label: employee.name,
                          sub_label: employee.department&.name.presence || employee.position&.name.presence || employee.status.tr(
                            '_', ' '
                          ),
                          path: Rails.application.routes.url_helpers.people_employee_path(employee)
                        )
                      end
    end

    def number(value)
      ActiveSupport::NumberHelper.number_to_currency(value, unit: '$')
    end
  end
end
