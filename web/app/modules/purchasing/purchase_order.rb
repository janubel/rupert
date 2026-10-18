# frozen_string_literal: true

module Purchasing
  # A purchase order to a vendor: what's being bought, what arrived, and what's
  # owed. Lines are editable while in draft; receiving records partials and
  # marks the order received once fully arrived.
  class PurchaseOrder < ApplicationRecord
    include TenantScoped
    include AASM

    self.table_name = 'purchase_orders'

    has_many :deliveries, class_name: 'Purchasing::PurchaseDelivery', dependent: :restrict_with_exception

    belongs_to :vendor, class_name: 'Purchasing::Vendor', foreign_key: :vendor_id
    has_many :lines,
      class_name: 'Purchasing::PurchaseOrderLine',
      foreign_key: :purchase_order_id,
      dependent: :destroy,
      inverse_of: :purchase_order

    validates :vendor_id, presence: true
    validates :order_number, presence: true, uniqueness: { scope: :tenant_id }
    validates :status, presence: true

    validate do
      errors.add(:vendor, 'must belong to this workspace') unless vendor&.tenant_id == tenant_id
    end

    scope :by_status, ->(status) { status.present? && status != 'all' ? where(status: status) : all }
    scope :recent, ->(limit = 100) { order(created_at: :desc).limit(limit) }

    aasm column: 'status', no_direct_assignment: true do
      state :draft, initial: true
      state :ordered
      state :received
      state :cancelled

      event :place_order do
        transitions from: :draft, to: :ordered
      end
      event :mark_received do
        transitions from: %i[ordered draft], to: :received
      end
      event :cancel do
        transitions from: %i[draft ordered], to: :cancelled
      end
    end

    def total_cents
      lines.sum('quantity * unit_cost_cents')
    end

    def received_cents
      lines.sum('received_quantity * unit_cost_cents')
    end

    def pending_cents
      total_cents - received_cents
    end

    def fully_received?
      lines.any? && lines.all? { |line| line.received_quantity >= line.quantity }
    end

    def draft?
      status == 'draft'
    end
  end
end
