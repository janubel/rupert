# frozen_string_literal: true

module Purchasing
  # A line on a purchase order: SKU, description, quantity ordered, unit cost,
  # and how much of it has been received.
  class PurchaseOrderLine < ApplicationRecord
    include TenantScoped

    self.table_name = 'purchase_order_lines'

    belongs_to :purchase_order,
      class_name: 'Purchasing::PurchaseOrder',
      foreign_key: :purchase_order_id,
      inverse_of: :lines

    validates :name, presence: true
    validates :quantity, numericality: { only_integer: true, greater_than: 0 }
    validates :unit_cost_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :received_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    validates :received_quantity, numericality: { less_than_or_equal_to: :quantity }
    validate do
      errors.add(:purchase_order, 'must belong to this workspace') unless purchase_order&.tenant_id == tenant_id
    end

    def line_cents
      quantity * unit_cost_cents
    end
  end
end
