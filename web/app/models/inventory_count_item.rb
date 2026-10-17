# frozen_string_literal: true

class InventoryCountItem < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = 'InventoryCountItem'
  self.primary_key = 'id'

  serialize :comparison_snapshot, coder: JSON

  belongs_to :count, class_name: 'InventoryCount', foreign_key: 'countId', optional: false
  belongs_to :shopify_variant, class_name: 'ShopifyVariant', foreign_key: 'shopifyVariantId', optional: true
  belongs_to :square_variation, class_name: 'SquareVariation', foreign_key: 'squareVariationId', optional: true

  validates :sku, presence: true
  validates :quantity,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 2_147_483_647 }

  def delta
    return nil if previousQuantity.nil? || comparison['status'] != 'matched'

    quantity - previousQuantity
  end

  def comparison
    comparison_snapshot.is_a?(Hash) ? comparison_snapshot : {}
  end

  def shopify_source_identity_token
    return unless comparison['source'] == 'shopify' && comparison['source_item_id'].present?

    identity = comparison.slice('source', 'source_item_id', 'location_id', 'source_location_id', 'shop_domain', 'inventory_item_id')
      .merge('tenant_id' => tenant_id || Current.tenant_id, 'sku' => sku)
    Rails.application.message_verifier('shopify_count_identity').generate(identity)
  end

  def comparison_label
    return 'Legacy total · pool not verified' if comparison.empty? && !previousQuantity.nil?
    return comparison['reason'] || 'Comparison captured on submission' unless comparison['status'] == 'matched'

    "#{comparison['source'].to_s.titleize} · #{comparison['location_name']} · mirrored #{comparison['quantity_basis'].to_s.humanize.downcase}"
  end

  # Resolves the linked Shopify variant (snapshotted id, or by sku for drafts)
  # so the count sheet can show a product name and thumbnail.
  def resolved_variant
    return nil if comparison['source'] == 'ctrax' || count.location&.source == 'ctrax'

    @resolved_variant ||= shopify_variant || ShopifyVariant.find_by(sku: sku)
  end

  def inventory_title
    return comparison['product_name'] if comparison['source'] == 'ctrax'

    resolved_variant&.title
  end

  def inventory_thumbnail
    resolved_variant&.product&.thumbnail_url
  end
end
