# frozen_string_literal: true

class CreateMarketingShopifyDiscounts < ActiveRecord::Migration[8.1]
  def change
    create_table :marketing_shopify_discounts do |t|
      t.string :tenant_id, null: false
      t.references :offer, null: false, index: { unique: true }, foreign_key: { to_table: :marketing_offers }
      t.string :shop_domain, null: false
      t.string :shop_id, null: false
      t.string :currency, null: false
      t.string :request_key, null: false
      t.text :request_json, null: false
      t.string :status, null: false, default: 'draft'
      t.string :remote_id
      t.string :remote_status
      t.text :remote_json
      t.text :last_error
      t.bigint :approved_by_id
      t.datetime :attempted_at
      t.datetime :checked_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index :request_key, unique: true
      t.index :tenant_id
      t.index [:tenant_id, :shop_domain, :remote_id], unique: true, name: 'marketing_shopify_remote_discount'
    end
    add_foreign_key :marketing_shopify_discounts, :users, column: :approved_by_id
    add_foreign_key :marketing_shopify_discounts, :tenants
    add_check_constraint :marketing_shopify_discounts,
      "status IN ('draft', 'creating', 'created', 'uncertain', 'failed', 'blocked')", name: 'marketing_shopify_discount_status'
  end
end
