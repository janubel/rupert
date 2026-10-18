# frozen_string_literal: true

require 'test_helper'

# Separate connections need committed fixtures, so this class deliberately does
# not use transactional tests. It creates and removes its own tenant and mirrors.
class StockReservationConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @tenant = Tenant.create!(name: 'Concurrent holds', subdomain: "concurrent-holds-#{SecureRandom.hex(4)}")
    Current.tenant = @tenant
    @product = ShopifyProduct.create!(id: SecureRandom.uuid, title: 'Concurrent product')
    @variant = ShopifyVariant.create!(productId: @product.id, sku: 'CONCURRENT', title: 'Concurrent widget')
    @location = Location.create!(source: 'shopify', externalId: 'concurrent', name: 'Warehouse')
    @level = InventoryLevel.create!(source: 'shopify', locationId: @location.id,
      shopifyVariantId: @variant.id, quantity: 5, available: 5)
  end

  teardown do
    Current.tenant = @tenant
    StockRequestEvent.delete_all
    StockRequest.delete_all
    StockReservation.delete_all
    StockReservationPool.delete_all
    @level&.destroy!
    @variant&.destroy!
    @product&.destroy!
    @location&.destroy!
    @tenant&.destroy!
    Current.reset
  end

  test 'simultaneous first holds cannot exceed one platform location capacity' do
    holds = race { |number| { quantity: 4, reference: "Concurrent #{number}" } }
    assert_equal 1, holds.count(&:persisted?)
    assert_equal 1, StockReservationPool.count
    assert_equal 4, StockReservation.active_at.sum(:quantity)
    refused = holds.find { |hold| !hold.persisted? }
    assert_match(/1 units available/, refused.errors[:quantity].join)
    assert_equal 5, @level.reload.quantity
  end

  test 'simultaneous replay with spare capacity produces one hold' do
    token = SecureRandom.uuid
    holds = race { { quantity: 2, reference: 'Same request', request_token: token } }
    assert holds.all?(&:persisted?)
    assert_equal 1, holds.map(&:id).uniq.size
    assert_equal 1, StockReservation.count
    assert_equal 2, StockReservation.active_at.sum(:quantity)
    assert_equal 3, holds.first.stock_reservation_pool.available_to_promise
  end

  test 'backorder allocation and advisory reservation compete for the same capacity' do
    actor = User.create!(email: "allocator-#{SecureRandom.hex(4)}@example.com", password: 'password123', role: 'admin', tenant: @tenant)
    request = StockRequestWorkflow.new(actor: actor).create(attributes: {
      request_kind: 'backorder', inventory_level_id: @level.id, quantity: 4, reference: 'Concurrent demand'
    }, token: SecureRandom.uuid)
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = 2.times.map do |number|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Current.tenant = @tenant
          ready << true
          start.pop
          if number.zero?
            result = StockReservationService.reserve(inventory_level_id: @level.id, attributes: { quantity: 4, reference: 'Concurrent hold' }, actor: actor.email)
            results << result.persisted?
          else
            StockRequestWorkflow.new(actor: actor).transition(request: StockRequest.find(request.id), action: 'allocated', token: SecureRandom.uuid)
            results << true
          end
        ensure
          Current.reset
        end
      rescue StockRequestWorkflow::Error
        results << false
      rescue StandardError => e
        results << e
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each { |thread| assert thread.join(15), 'concurrent allocation timed out' }
    outcome = 2.times.map { results.pop }
    outcome.each { |result| refute_kind_of Exception, result, result.inspect }
    assert_equal 1, outcome.count(true)
    assert_equal 4, StockReservation.active_at.sum(:quantity)
    assert_equal 5, @level.reload.quantity
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    actor&.destroy!
  end

  private

  def race(&attributes)
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = Array.new(2) do |number|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Current.tenant = @tenant
          ready << true
          start.pop
          results << StockReservationService.reserve(inventory_level_id: @level.id,
            attributes: attributes.call(number), actor: 'counter@example.com')
        ensure
          Current.reset
        end
      rescue StandardError => e
        results << e
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each { |thread| assert thread.join(15), 'concurrent reservation timed out' }
    Array.new(2) { results.pop }.tap do |holds|
      holds.each { |result| refute_kind_of Exception, result, result.inspect }
    end
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end
end
