# frozen_string_literal: true

# Where a product comes from (Shopify vendor) and its product type, shown on the item page.
class AddVendorAndTypeToShopifyProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :ShopifyProduct, :vendor, :string
    add_column :ShopifyProduct, :productType, :string
  end
end
