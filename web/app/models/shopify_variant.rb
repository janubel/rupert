# frozen_string_literal: true

class ShopifyVariant < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = 'ShopifyVariant'
  self.primary_key = 'id'

  belongs_to :product,
    class_name: 'ShopifyProduct',
    foreign_key: 'productId',
    inverse_of: :variants,
    optional: true

  has_many :sku_links,
    class_name: 'SkuLink',
    foreign_key: 'shopifyVariantId',
    dependent: :nullify
  has_many :movements, class_name: 'InventoryMovement', foreign_key: 'shopifyVariantId'
  has_many :alerts, class_name: 'StockAlert', foreign_key: 'shopifyVariantId'
  has_many :levels, class_name: 'InventoryLevel', foreign_key: 'shopifyVariantId'

  scope :tracked, -> { where(tracked: true) }
  scope :current_catalog, -> { where(catalog_present: true).where(productId: ShopifyProduct.where(status: 'ACTIVE', catalog_present: true).select(:id)) }
  scope :search, lambda { |q|
    return all if q.blank?

    where(sku: q).or(where('sku LIKE ?', "%#{q}%")).or(where('title LIKE ?', "%#{q}%"))
  }
end
