# frozen_string_literal: true

# Discount codes on each order (Shopify discount codes, Square discount names), so staff coupon and referral
# bonuses can be matched to sales (#465). Older orders stay empty (nil) until a sync re-reads them.
class AddDiscountCodesToOrders < ActiveRecord::Migration[8.1]
  def change
    add_column :orders, :discount_codes, :json
    change_column_default :orders, :discount_codes, from: nil, to: []
  end
end
