# frozen_string_literal: true

module Marketing
  class ProductGift < Record
    self.table_name = 'marketing_product_gifts'
    STATUSES = %w[proposed approved ready_to_ship shipped delivered cancelled returned].freeze
    PRIVATE_FIELDS = %i[shipping_details tracking_number tracking_url].freeze
    encrypts(*PRIVATE_FIELDS)
    belongs_to :engagement
    has_many :items, class_name: 'Marketing::ProductGiftItem', inverse_of: :product_gift
    attr_accessor :workflow_checked

    validates :status, inclusion: { in: STATUSES }
    validates :currency, format: { with: /\A[A-Z]{3}\z/ }
    validates :shipping_cost_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than: 100_000_000 }, allow_nil: true
    validates :note, :shipping_details, length: { maximum: 5000 }
    validates :carrier, :tracking_number, length: { maximum: 200 }
    validate { same_tenant(:engagement) }
    validate { https_fields(:tracking_url) if tracking_url.present? }
    validate { errors.add(:base, 'Use the gift workflow') unless workflow_checked }
    before_update { self.recipient_confirmed_at = nil if will_save_change_to_shipping_details? }

    def estimated_product_cents
      rows = items.to_a
      return if rows.empty? || rows.any? { |item| item.unit_cost_cents.nil? }

      rows.sum { |item| item.quantity * item.unit_cost_cents }
    end
  end
end
