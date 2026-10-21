# frozen_string_literal: true

# One capacity pool per platform item and location. SKU links never merge pools.
# Snapshot labels retain an understandable audit trail if a mirror disappears.
class StockReservationPool < ApplicationRecord
  include TenantScoped

  has_many :stock_reservations, dependent: :restrict_with_exception
  has_many :source_requests, class_name: 'StockRequest', foreign_key: :source_pool_id, dependent: :restrict_with_exception
  has_many :destination_requests, class_name: 'StockRequest', foreign_key: :destination_pool_id, dependent: :restrict_with_exception

  attr_readonly :tenant_id, :source, :location_id, :source_item_id

  validates :tenant_id, :source, :location_id, :source_item_id, :location_name, :item_label, presence: true
  validates :source, inclusion: { in: %w[shopify square] }

  def self.for_level!(level)
    source = level.source
    item = source == 'shopify' ? level.shopify_variant : level.square_variation
    location = level.location
    opposite_item_id = source == 'shopify' ? level.squareVariationId : level.shopifyVariantId
    unless Current.tenant_id.present? && opposite_item_id.nil? &&
        %w[shopify square].include?(source) && location&.tenant_id == Current.tenant_id &&
        location.source == source && item&.tenant_id == Current.tenant_id
      raise ActiveRecord::RecordNotFound, 'This inventory pool is unavailable.'
    end

    create_or_find_by!(tenant_id: Current.tenant_id, source: source, location_id: location.id, source_item_id: item.id) do |pool|
      pool.location_name = location.name.presence || location.id
      pool.item_label = [item.sku.presence, source == 'shopify' ? item.title : item.name].compact.join(' · ').presence || item.id
    end
  end

  def inventory_level
    item_key = source == 'shopify' ? :shopifyVariantId : :squareVariationId
    opposite_key = source == 'shopify' ? :squareVariationId : :shopifyVariantId
    InventoryLevel.find_by(tenant_id: tenant_id, source: source, locationId: location_id, item_key => source_item_id, opposite_key => nil)
  end

  def mirrored_available
    level = inventory_level
    level&.local_capacity || 0
  end

  def held_quantity(at: Time.current)
    stock_reservations.active_at(at).sum(:quantity)
  end

  def available_to_promise(at: Time.current)
    # Warehouse checkouts do not yet choose a location. Charge every local
    # Shopify pool conservatively rather than promising their stock twice.
    warehouse = source == 'shopify' ? WarehouseStockHold.held.where(variant_id: source_item_id).sum(:quantity) : 0
    [mirrored_available - held_quantity(at: at) - warehouse, 0].max
  end

  def serialize_allocation
    self.class.transaction do
      # Write before reading availability so SQLite acquires its writer lock
      # without a read-to-write upgrade race.
      self.class.where(id: id).update_all('lock_version = lock_version + 1')
      yield
    end
  end
end
