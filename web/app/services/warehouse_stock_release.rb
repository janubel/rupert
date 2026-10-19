# frozen_string_literal: true

# A staff attestation, not a source-platform mutation. Keep the hold until a
# source read is newer than the confirmed adjustment, avoiding stale restocks.
class WarehouseStockRelease
  class Error < StandardError; end

  def self.call(order:, actor:, fulfilled:, source_confirmed:, adjusted_at:, reference:)
    unless order.tenant_id == Current.tenant_id && actor&.active? &&
        (actor.tenant_id == order.tenant_id || actor.super_admin?) && %w[sales.read sales.write inventory.read inventory.write].all? { |permission| actor.can?(permission) }
      raise Error, 'Sales and inventory read and write permissions are required in this workspace.'
    end
    raise Error, 'Confirm fulfillment and the source stock adjustment first.' unless fulfilled == '1' && source_confirmed == '1'
    time = Time.zone.parse(adjusted_at.to_s)
    raise Error, 'Enter a valid source adjustment time in the past.' unless time && time <= Time.current
    raise Error, 'Enter the source stock adjustment reference (up to 500 characters).' unless reference.to_s.strip.length.between?(1, 500)

    Core::Order.transaction do
      Tenant.where(id: Current.tenant_id).update_all(updated_at: Arel.sql('updated_at'))
      order.lock!
      raise Error, 'This is not a paid warehouse checkout.' unless order.source == 'online' && order.channel == 'warehouse' && %w[paid fulfilled refunded].include?(order.status)
      holds = order.warehouse_stock_holds.held.lock.to_a
      return 0 if holds.empty?

      latest = holds.map { |hold| hold.warehouse_payment_attempt&.submitted_at || order.occurred_at }.max
      raise Error, 'Source adjustment must be after the held checkout.' if time < latest
      levels = InventoryLevel.unscoped.where(tenant_id: order.tenant_id, source: 'shopify', shopifyVariantId: holds.map(&:variant_id))
      stamps = levels.group(:shopifyVariantId).minimum(:updatedAt)
      latest_stamps = levels.group(:shopifyVariantId).maximum(:updatedAt)
      unless holds.all? { |hold| stamps[hold.variant_id] && stamps[hold.variant_id] >= time && latest_stamps[hold.variant_id] <= Time.current }
        raise Error, 'Refresh Shopify inventory after the source adjustment before releasing these holds; future-dated reads are invalid.'
      end
      holds.each do |hold|
        hold.update!(status: 'released', release_reason: 'fulfilled_source_adjusted', released_at: Time.current,
          released_by: actor, fulfillment_confirmed_at: Time.current, source_adjusted_at: time, source_refreshed_at: stamps[hold.variant_id], source_adjustment_reference: reference.to_s.strip)
      end
      order.fulfill! if order.may_fulfill?
      order.advance_fulfillment_status!('completed')
      ActivityLogger.log('warehouse_stock_released', subject: order, actor: actor, details: "#{holds.size} locally held lines released after staff confirmation and refreshed source stock")
      holds.size
    end
  rescue ArgumentError, TypeError
    raise Error, 'Enter a valid source adjustment time.'
  end
end
