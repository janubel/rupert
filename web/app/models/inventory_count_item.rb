# frozen_string_literal: true

class InventoryCountItem < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = 'InventoryCountItem'
  self.primary_key = 'id'

  belongs_to :count, class_name: 'InventoryCount', foreign_key: 'countId', optional: false
  belongs_to :shopify_variant, class_name: 'ShopifyVariant', foreign_key: 'shopifyVariantId', optional: true
  belongs_to :square_variation, class_name: 'SquareVariation', foreign_key: 'squareVariationId', optional: true

  validates :sku, presence: true
  validates :quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 2_147_483_647 }

  def delta
    return nil if previousQuantity.nil?

    quantity - previousQuantity
  end

  # Resolves the linked Shopify variant (snapshotted id, or by sku for drafts)
  # so the count sheet can show a product name and thumbnail.
  def resolved_variant
    @resolved_variant ||= shopify_variant || ShopifyVariant.find_by(sku: sku)
  end

  def inventory_title
    resolved_variant&.title
  end

  def inventory_thumbnail
    resolved_variant&.product&.thumbnail_url
  end
end
