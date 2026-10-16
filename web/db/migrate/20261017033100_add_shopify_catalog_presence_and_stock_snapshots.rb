# frozen_string_literal: true

class AddShopifyCatalogPresenceAndStockSnapshots < ActiveRecord::Migration[8.1]
  def change
    %i[ShopifyProduct ShopifyVariant].each do |table|
      add_column table, :catalog_present, :boolean
      add_column table, :catalog_read_at, :datetime
    end
    create_table :shopify_stock_snapshots do |t|
      t.string :tenant_id, null: false
      t.string :location_id, null: false
      t.string :shop_domain, null: false
      t.datetime :captured_at, null: false
      t.text :records_json, null: false
      t.timestamps
      t.index [:tenant_id, :location_id], unique: true
      t.index :tenant_id
    end
  end
end
