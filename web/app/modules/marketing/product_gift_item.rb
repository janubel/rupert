# frozen_string_literal: true

module Marketing
  class ProductGiftItem < Record
    self.table_name = 'marketing_product_gift_items'
    belongs_to :product_gift, inverse_of: :items
    attr_accessor :workflow_checked

    validates :source_variant_id, :product_name, presence: true
    validates :source_variant_id, uniqueness: { scope: :product_gift_id }
    validates :quantity, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 10_000 }
    validates :unit_cost_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than: 100_000_000 }, allow_nil: true
    validate { same_tenant(:product_gift) }
    validate { errors.add(:base, 'Use the gift workflow') unless workflow_checked }
  end
end
