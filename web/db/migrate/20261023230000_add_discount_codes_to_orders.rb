# frozen_string_literal: true

# Discount codes on each order (Shopify discount codes, Square discount names), so staff coupon and referral
# bonuses can be matched to sales (#465).
class AddDiscountCodesToOrders < ActiveRecord::Migration[8.1]
  def change
    add_column :orders, :discount_codes, :json, default: [], null: false
  end
end
