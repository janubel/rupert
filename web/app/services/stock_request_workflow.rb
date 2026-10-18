# frozen_string_literal: true

require 'digest'

class StockRequestWorkflow
  class Error < StandardError; end

  def initialize(actor:)
    @actor = actor
    unless Current.tenant_id.present? && actor&.active? && (actor.tenant_id == Current.tenant_id || actor.super_admin?) &&
        actor.can?('inventory.read') && actor.can?('inventory.write')
      raise Error, 'Inventory read and write permissions are required.'
    end
  end

  def create(attributes:, token:)
    attributes = attributes.symbolize_keys.slice(:request_kind, :inventory_level_id, :destination_location_id, :quantity, :reference, :due_on)
    payload = attributes.transform_values(&:to_s).sort.to_h
    serialized do
      prior = replay(token, 'created', payload)
      return prior.stock_request if prior

      level = InventoryLevel.find(attributes[:inventory_level_id])
      pool = StockReservationPool.for_level!(level)
      destination = destination_pool(pool, attributes[:destination_location_id]) if attributes[:request_kind] == 'transfer'
      request = StockRequest.new(attributes.slice(:request_kind, :quantity, :reference, :due_on).merge(
        tenant_id: Current.tenant_id, source_pool: pool, destination_pool: destination, created_by: @actor.email,
        source_location_external_id: level.location.externalId, destination_location_external_id: destination&.inventory_level&.location&.externalId
      ))
      request.workflow_checked = true
      request.save!
      allocate!(request, token) if request.transfer?
      record!(request, token, 'created', payload, quantity: request.quantity)
      request
    end
  rescue ActiveRecord::RecordInvalid => e
    raise Error, e.record.errors.full_messages.to_sentence
  end

  def transition(request:, action:, token:, quantity: nil, confirmed: nil, adjusted_at: nil, reference: nil)
    raise ActiveRecord::RecordNotFound unless request.tenant_id == Current.tenant_id

    payload = { quantity: quantity.to_s, confirmed: confirmed.to_s, adjusted_at: adjusted_at.to_s, reference: reference.to_s.strip }
    serialized do
      prior = replay(token, action, payload, request: request)
      return request.reload if prior

      request.reload
      request.workflow_checked = true
      details = case action
      when 'allocated'
        raise Error, 'Only pending backorders can be allocated.' unless !request.transfer? && request.status == 'pending'

        allocate!(request, token)
        { quantity: request.quantity }
      when 'dispatched'
        raise Error, 'Only allocated transfers can be dispatched.' unless request.transfer? && request.status == 'allocated'

        destination = request.destination_pool.inventory_level
        unless destination&.location&.active && destination.location.externalId == request.destination_location_external_id
          raise Error, 'Review the original destination stock pool before dispatch.'
        end
        evidence = source_evidence!(request, request.source_pool, adjusted_at, reference, confirmed, since: request.created_at)
        release!(request)
        request.update!(status: 'dispatched')
        evidence.merge(quantity: request.quantity)
      when 'received'
        raise Error, 'Only dispatched transfers can be received.' unless request.transfer? && request.status == 'dispatched'
        unless quantity.to_s.match?(/\A[1-9]\d*\z/) && quantity.to_i <= request.outstanding_quantity
          raise Error, "Enter whole units between 1 and #{request.outstanding_quantity}."
        end
        dispatched = request.events.find_by!(action: 'dispatched')
        evidence = source_evidence!(request, request.destination_pool, adjusted_at, reference, confirmed, since: dispatched.source_adjusted_at)
        total = request.received_quantity + quantity.to_i
        request.update!(received_quantity: total, status: total == request.quantity ? 'completed' : 'dispatched')
        evidence.merge(quantity: quantity.to_i)
      when 'fulfilled'
        raise Error, 'Only allocated backorders can be fulfilled.' unless !request.transfer? && request.status == 'allocated'

        evidence = source_evidence!(request, request.source_pool, adjusted_at, reference, confirmed, since: request.stock_reservation.created_at)
        release!(request)
        request.update!(received_quantity: request.quantity, status: 'completed')
        evidence.merge(quantity: request.quantity)
      when 'cancelled'
        raise Error, 'Dispatched or completed stock cannot be cancelled; resolve its receipt first.' unless %w[pending allocated].include?(request.status)

        release!(request) if request.stock_reservation
        request.update!(status: 'cancelled')
        { quantity: request.outstanding_quantity }
      else
        raise Error, 'Unknown inventory action.'
      end
      record!(request, token, action, payload, **details)
      request
    end
  rescue ActiveRecord::RecordInvalid => e
    raise Error, e.record.errors.full_messages.to_sentence
  end

  private

  def serialized
    StockRequest.transaction do
      # Also used by warehouse checkout and advisory holds: one allocation lock.
      Tenant.where(id: Current.tenant_id).update_all(updated_at: Arel.sql('updated_at'))
      yield
    end
  end

  def destination_pool(pool, location_id)
    key = pool.source == 'shopify' ? :shopifyVariantId : :squareVariationId
    level = InventoryLevel.find_by(source: pool.source, locationId: location_id, key => pool.source_item_id)
    raise Error, 'Choose a destination with a mirrored pool for the same native item and source.' unless level && level.locationId != pool.location_id

    StockReservationPool.for_level!(level)
  end

  def allocate!(request, token)
    level = request.source_pool.inventory_level
    unless level&.location&.active && level.location.externalId == request.source_location_external_id && level.updatedAt.between?(1.hour.ago, Time.current)
      raise Error, 'Refresh this active source/location stock pool before allocating (within one hour).'
    end
    if request.source_pool.source == 'shopify'
      variant = level.shopify_variant
      unless variant && variant.catalog_present != false && variant.product&.status == 'ACTIVE' && variant.product.catalog_present != false
        raise Error, 'This Shopify item is retired or inactive. Review its catalog identity before allocating.'
      end
    end
    hold = StockReservationService.reserve(inventory_level_id: level.id, attributes: {
      quantity: request.quantity, reference: "#{request.request_kind.capitalize} ##{request.id}: #{request.reference}".truncate(200),
      request_token: "workflow-#{Digest::SHA256.hexdigest(token.to_s)}"
    }, actor: @actor.email)
    raise Error, hold.errors.full_messages.to_sentence unless hold.persisted?

    request.update!(stock_reservation: hold, status: 'allocated')
  end

  def release!(request)
    StockReservationService.release(request.stock_reservation, actor: @actor.email, stock_request: request)
  end

  def source_evidence!(request, pool, adjusted_at, reference, confirmed, since:)
    raise Error, 'Confirm the physical movement and source stock adjustment.' unless confirmed == '1'
    raise Error, 'Enter a source adjustment reference (up to 500 characters).' unless reference.to_s.strip.length.between?(1, 500)

    stamp = Time.zone.parse(adjusted_at.to_s)
    raise Error, 'Adjustment time must be after allocation/dispatch and in the past.' unless stamp && stamp >= since && stamp <= Time.current

    level = pool.inventory_level
    native_location = pool.id == request.source_pool_id ? request.source_location_external_id : request.destination_location_external_id
    unless level&.location&.active && level.location.externalId == native_location && level.updatedAt >= stamp && level.updatedAt <= Time.current
      raise Error, 'Refresh the same source item/location after the confirmed adjustment.'
    end
    { reference: reference.to_s.strip, source_adjusted_at: stamp, source_refreshed_at: level.updatedAt }
  rescue ArgumentError, TypeError
    raise Error, 'Enter a valid source adjustment time.'
  end

  def replay(token, action, payload, request: nil)
    raise Error, 'Reload the form for a valid request token.' unless token.to_s.match?(/\A[\w-]{1,100}\z/)

    event = StockRequestEvent.find_by(request_token: token)
    return unless event
    unless event.action == action && event.actor == @actor.email && event.payload_digest == digest(payload) && (!request || event.stock_request_id == request.id)
      raise Error, 'This request token was already used for a different action. Reload the form.'
    end
    event
  end

  def digest(payload)
    Digest::SHA256.hexdigest(payload.to_json)
  end

  def record!(request, token, action, payload, **details)
    request.events.create!(tenant_id: request.tenant_id, request_token: token, action: action,
      actor: @actor.email, payload_digest: digest(payload), **details)
  end
end
