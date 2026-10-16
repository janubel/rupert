# frozen_string_literal: true

require 'test_helper'

class CtraxCountComparisonTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @location = Location.create!(source: 'ctrax', externalId: 'fixture/7', name: 'C-Trax fixture store')
    @snapshot = CtraxStockSnapshot.create!(location: @location, api_origin: 'https://fixture.api.cannatrax.net',
      store_id: '7', captured_at: Time.current, records_json: [row('1', nil, '-3'), row('2', 'ZERO', '0'), row('3', 'UNKNOWN', nil), row('4', 'WEIGHT', '1.25')])
    @count = InventoryCount.create!(locationId: @location.id, countedAt: Time.current)
  end

  teardown { Current.reset }

  test 'prepared sheet uses native IDs for missing SKUs and retains signed stock' do
    items = InventoryCountComparison.prepared_items(@count)
    assert_equal %w[ctrax:1 ctrax:2], items.map(&:sku)
    assert_equal [-3, 0], items.map(&:previousQuantity)
    assert_equal [0, 0], items.map(&:quantity)
    assert_equal 'ctrax', items.first.comparison['source']
    assert_equal '7', items.first.comparison['source_store_id']
    assert_equal '1', items.first.comparison['source_item_id']
    assert_nil items.first.comparison['source_sku']
    assert_equal 'Variant 1', items.first.inventory_title
    assert_nil items.first.inventory_thumbnail
  end

  test 'submission freezes count delta and native source identity across later syncs' do
    item = @count.items.create!(sku: 'ctrax:1', quantity: 2)
    @count.snapshot_previous!
    assert_equal 5, item.reload.delta
    frozen = item.comparison.deep_dup
    @snapshot.update!(records_json: [row('1', nil, '100')])
    assert_equal frozen, item.reload.comparison
    assert_equal 5, item.delta
  end

  test 'unknown fractional duplicate and alias stock pools have no numerical comparison' do
    @count.items.create!(sku: 'UNKNOWN', quantity: 1)
    @count.items.create!(sku: 'WEIGHT', quantity: 1)
    @count.items.create!(sku: 'ZERO', quantity: 1)
    @count.items.create!(sku: 'ctrax:2', quantity: 1)
    @count.snapshot_previous!
    @count.items.each do |item|
      assert_nil item.previousQuantity
      assert_nil item.delta
    end
    @count.items.destroy_all
    2.times { @count.items.create!(sku: 'ctrax:1', quantity: 1) }
    @count.snapshot_previous!
    @count.items.each { |item| assert_nil item.previousQuantity }
  end

  test 'changed identity and cross-tenant snapshot are unavailable' do
    item = @count.items.create!(sku: 'ZERO', quantity: 0,
      comparison_snapshot: { source: 'ctrax', source_item_id: 'old-id' })
    @count.snapshot_previous!
    assert_nil item.reload.delta
    assert_match(/identity changed/, item.comparison['reason'])
    other = Tenant.create!(name: 'Other C-Trax tenant', subdomain: 'ctrax-snapshot-other')
    @snapshot.update_column(:tenant_id, other.id)
    result = InventoryCountComparison.snapshot(count: @count, item: item)
    assert_nil result[:previousQuantity]
  end

  test 'scanner resolves only this stores native variants and rejects ambiguous barcodes' do
    result = InventoryCountScan.new.record!(count: @count, code: 'code-1', quantity: '2', mode: 'set',
      request_token: 'ctrax_request_12345', actor: 'test')
    assert_equal 'ctrax:1', result[:sku]
    assert_equal 2, @count.items.first.quantity
    assert_equal '1', @count.items.first.comparison['source_item_id']
    @snapshot.update!(records_json: [row('1', nil, '0'), row('2', 'SECOND', '0').merge('barcode' => 'code-1')])
    assert_raises(InventoryCountScan::Error) do
      InventoryCountScan.new.record!(count: @count, code: 'code-1', quantity: '1', mode: 'set',
        request_token: 'ctrax_request_23456', actor: 'test')
    end
  end

  test 'scanning a manual SKU updates its existing native pool instead of creating an alias row' do
    @count.items.create!(sku: 'ZERO', quantity: 3)
    InventoryCountScan.new.record!(count: @count, code: 'code-2', quantity: '2', mode: 'increment',
      request_token: 'ctrax_manual_123456', actor: 'test')
    assert_equal 1, @count.items.count
    assert_equal 'ctrax:2', @count.items.first.sku
    assert_equal 5, @count.items.first.quantity
  end

  private

  def row(id, sku, quantity)
    { 'id' => id, 'sku' => sku, 'barcode' => "code-#{id}", 'name' => "Variant #{id}", 'quantity' => quantity,
      'manage_stock' => true }
  end
end
