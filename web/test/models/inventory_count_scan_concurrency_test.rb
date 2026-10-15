# frozen_string_literal: true

require 'test_helper'

class InventoryCountScanConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test 'concurrent scanner requests preserve increments and deduplicate repeated token' do
    tenant = Tenant.create!(name: 'Scanner concurrency', subdomain: "scanner-lock-#{SecureRandom.hex(4)}")
    Current.tenant = tenant
    product = ShopifyProduct.create!(id: SecureRandom.uuid, title: 'Concurrent scanner')
    variant = ShopifyVariant.create!(productId: product.id, title: 'Unit', sku: "SCAN-#{SecureRandom.hex(4)}")
    count = InventoryCount.create!(countedAt: Time.current)
    repeated = SecureRandom.uuid
    tokens = [repeated, repeated, SecureRandom.uuid, SecureRandom.uuid]
    gate = Queue.new
    errors = Queue.new
    threads = tokens.map do |token|
      Thread.new do
        gate.pop
        ActiveRecord::Base.connection_pool.with_connection do
          Current.tenant = tenant
          InventoryCountScan.new.record!(count: InventoryCount.find(count.id), code: variant.sku,
            quantity: '1', mode: 'increment', request_token: token, actor: 'counter@example.com')
        end
      rescue StandardError => e
        errors << e
      ensure
        Current.reset
      end
    end
    tokens.length.times { gate << true }
    threads.each(&:join)
    failures = []
    failures << errors.pop until errors.empty?
    assert_empty failures, failures.map { |e| "#{e.class}: #{e.message}" }.join("\n")
    assert_equal 3, count.items.find_by!(sku: variant.sku).quantity
    assert_equal 3, count.scan_receipts.count
  ensure
    Current.tenant = tenant
    count&.destroy!
    variant&.destroy!
    product&.destroy!
    tenant&.destroy!
    Current.reset
  end
end
