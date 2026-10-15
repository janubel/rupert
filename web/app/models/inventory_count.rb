# frozen_string_literal: true

# A manual physical inventory worksheet. The counter records the actual on-hand
# quantity per SKU; approving a count records it as an audit worksheet for the
# future, when Rupert becomes the source of truth. Until then it never mutates
# mirrored inventory — Square is the source of truth today (see #apply_override!).
class InventoryCount < ApplicationRecord
  include HasCuid
  include TenantScoped
  include AASM

  self.table_name = 'InventoryCount'
  self.primary_key = 'id'

  has_many :items, class_name: 'InventoryCountItem', foreign_key: 'countId',
    dependent: :destroy, inverse_of: :count
  has_many :scan_receipts, class_name: 'InventoryCountScanReceipt', foreign_key: :count_id, dependent: :destroy
  belongs_to :location, class_name: 'Location', foreign_key: 'locationId', optional: true

  validates :countedAt, presence: true
  validate :location_belongs_to_tenant

  scope :recent, ->(limit = 30) { order(countedAt: :desc).limit(limit) }
  scope :by_status, ->(status) { status.present? ? where(status: status) : all }

  aasm column: 'status', no_direct_assignment: true do
    state :draft, initial: true
    state :pending
    state :approved
    state :rejected

    event :submit do
      transitions from: :draft, to: :pending
    end
    event :approve do
      transitions from: :pending, to: :approved
    end
    event :reject do
      transitions from: :pending, to: :rejected
    end
    event :reopen do
      transitions from: :rejected, to: :draft
    end
  end

  def total_quantity
    items.sum(:quantity)
  end

  def applied_items
    items.where(applied: true)
  end

  # Freeze one local mirror pool and its identity when submitted. Unknown or
  # ambiguous pools keep a reason and no numerical variance.
  def snapshot_previous!
    transaction do
      InventoryCountComparison.capture_all!(self)
    end
    self
  end

  # Record-only for now. Square is the source of truth until this app takes
  # over (the roadmap goal), so approving a count is captured as an audit
  # record/worksheet and never mutates mirrored inventory. When Rupert becomes
  # the source of truth, re-enable applying counted quantities here.
  def apply_override!(actor: 'user')
    return false unless approved?

    update!(appliedAt: Time.current)
    true
  end

  private

  def location_belongs_to_tenant
    return if locationId.blank? || Location.unscoped.exists?(id: locationId, tenant_id: tenant_id)

    errors.add(:locationId, 'must belong to this workspace')
  end
end
