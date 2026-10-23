# frozen_string_literal: true

# A person's decision about two observations of stock: this Shopify variant and this C-Trax item are the same
# product (paired), or they are not (not_same, so the suggestion never comes back). Stored in Rupert only; nothing
# is written to Shopify or C-Trax. The signatures record both items as they were when decided, so a later change
# (renamed, new SKU, new size) is flagged for a fresh look instead of silently trusted.
class ProductPair < ApplicationRecord
  include TenantScoped

  DECISIONS = %w[paired not_same].freeze

  belongs_to :decided_by, class_name: 'User', optional: true

  validates :shopify_variant_id, :ctrax_location_id, :ctrax_record_id, presence: true, length: { maximum: 120 }
  validates :decision, inclusion: { in: DECISIONS }
  validates :note, length: { maximum: 500 }
  validate :one_pair_per_item, if: :paired?

  scope :paired, -> { where(decision: 'paired') }
  scope :for_ctrax_location, ->(id) { where(ctrax_location_id: id.to_s) }

  def paired? = decision == 'paired'

  # True when either item changed since the decision.
  def changed_since?(variant, record)
    (shopify_signature.present? && shopify_signature != StockIdentityFindings.shopify_signature(variant)) ||
      (ctrax_signature.present? && ctrax_signature != StockIdentityFindings.ctrax_signature(record))
  end

  def decided_label
    [decided_by&.display_name, created_at&.to_date&.strftime('%b %-d, %Y')].compact.join(', ')
  end

  private

  # A Shopify variant pairs with one C-Trax item per store, and the other way round.
  def one_pair_per_item
    others = ProductPair.paired.for_ctrax_location(ctrax_location_id).where.not(id: id)
    errors.add(:base, 'This Shopify item is already paired with another C-Trax item') if others.exists?(shopify_variant_id: shopify_variant_id)
    errors.add(:base, 'This C-Trax item is already paired with another Shopify item') if others.exists?(ctrax_record_id: ctrax_record_id)
  end
end
