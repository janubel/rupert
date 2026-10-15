# frozen_string_literal: true

# Local advisory holds only. Sales channels can still sell the same stock.
class StockReservationService
  def self.reserve(inventory_level_id:, attributes:, actor:)
    level = InventoryLevel.find(inventory_level_id)
    pool = StockReservationPool.for_level!(level)
    reservation = StockReservation.new(attributes.slice(:quantity, :reference, :expires_at, :request_token).merge(
      stock_reservation_pool: pool, tenant_id: Current.tenant_id, created_by: actor
    ))

    result = pool.serialize_allocation do
      existing = StockReservation.find_by(request_token: reservation.request_token)
      if existing
        replay(existing, reservation)
      else
        reservation.allocation_checked = true
        if reservation.valid?
          available = pool.available_to_promise
          if reservation.quantity > available
            reservation.errors.add(:quantity, "exceeds the #{available} units available in this platform/location pool")
          else
            reservation.save!
          end
        end
        reservation
      end
    end
    result
  rescue ActiveRecord::RecordNotUnique
    existing = StockReservation.find_by!(request_token: reservation.request_token)
    replay(existing, reservation)
  end

  def self.release(reservation, actor:)
    raise ActiveRecord::RecordNotFound unless Current.tenant_id.present? && reservation.tenant_id == Current.tenant_id

    reservation.stock_reservation_pool.serialize_allocation do
      reservation.reload
      if reservation.status != 'released'
        reservation.update!(status: 'released', released_at: Time.current, released_by: actor)
      end
    end
    reservation
  end

  def self.replay(existing, requested)
    fields = %w[stock_reservation_pool_id quantity reference expires_at created_by]
    return existing if fields.all? { |field| existing[field] == requested[field] }

    requested.errors.add(:base, 'This request was already used. Reload the form to make a different reservation.')
    requested
  end
  private_class_method :replay
end
