# frozen_string_literal: true

class PosInventoryJob < ApplicationJob
  queue_as :default
  def perform(checkout_id = nil)
    rows = PosCheckout.unscoped.where(status: 'paid', demo: false)
      .where(id: PosStockAllocation.unscoped.where(status: %w[pending submitting unknown]).select(:pos_checkout_id))
    rows = rows.where(id: checkout_id) if checkout_id
    rows.limit(100).each do |checkout|
      next unless checkout.tenant&.status == 'active'
      Current.set(tenant: checkout.tenant) { apply(checkout) }
    end
  end

  private

  def apply(checkout)
    setting = PosSetting.find_by(location: checkout.location)
    return unless setting&.stock_writes_enabled
    connection = PosConnection.find_by!(provider: 'ctrax', vendor_approved: true)
    snapshot = CtraxStockSnapshot.find_by!(location: checkout.location)
    raise Pos::Error, 'Source connection changed; review stock before writing.' unless snapshot.api_origin == connection.credential_values['api_url']
    client = Ctrax::Client.new(connection.credential_values)
    client.use_store(snapshot.store_id)
    raw = client.stock(snapshot.store_id).index_by { |row| row['id'].to_s }
    active_allocation = nil
    checkout.pos_stock_allocations.where.not(status: %w[applied released held]).each do |allocation|
      history = client.inventory_adjustments(snapshot.store_id, allocation.variant_id)
      matches = history.select { |row| row['comments'] == allocation.marker }
      raise Pos::Error, 'Repeated source stock markers need review.' if matches.size > 1
      if matches.one?
        row = matches.first
        raise Pos::Error, 'Source stock adjustment does not match this sale.' unless row['action'] == 'remove' && row['quantity'].to_s == allocation.quantity.to_s
        allocation.update!(status: 'applied', source_adjustment_id: row.fetch('id').to_s, applied_at: Time.current)
        next
      end
      before = raw.dig(allocation.variant_id, 'store_stock', 'quantity')
      raise Pos::Error, 'Current native stock could not be verified.' unless before.to_s.match?(/\A-?[0-9]{1,9}\z/)
      # Claim once, before outbound mutation. Unknown outcomes only get reads.
      claimed = PosStockAllocation.where(id: allocation.id, status: 'pending', submitted_at: nil).update_all(status: 'submitting', submitted_at: Time.current, updated_at: Time.current)
      next if claimed.zero?
      active_allocation = allocation
      allocation.update!(source_quantity_before: before.to_i)
      reply = client.remove_stock(snapshot.store_id, allocation.variant_id, quantity: allocation.quantity, reference: allocation.marker)
      stock = reply['stock']
      if stock.is_a?(Hash) && stock['store_id'].to_s == snapshot.store_id && stock['product_variant_id'].to_s == allocation.variant_id && stock['quantity'].to_s == (before.to_i - allocation.quantity).to_s
        allocation.update!(status: 'applied', applied_at: Time.current)
      else
        allocation.update!(status: 'unknown')
      end
      # A lost response is resolved only through an exact durable native marker.
    end
    Ctrax::StockSync.call(connection: connection.reload)
  rescue Ctrax::Client::Error, Pos::Error, ActiveRecord::RecordNotFound => e
    PosStockAllocation.where(id: active_allocation.id, status: 'submitting').update_all(status: 'unknown', updated_at: Time.current) if active_allocation
    ActivityLogger.log('pos_inventory_needs_review', subject: checkout, details: e.message)
  end
end
