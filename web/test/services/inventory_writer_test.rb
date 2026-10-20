# frozen_string_literal: true

require 'test_helper'

class InventoryWriterTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @location = Location.create!(source: 'shopify', externalId: 'gid://shopify/Location/1', name: 'Store')
  end

  teardown { Current.reset }

  test 'adjust_shopify! sends one idempotent available-quantity change and raises on userErrors' do
    captured = nil
    ShopifyClient.stubs(:graphql).with { |_q, vars| captured = vars }
                 .returns({ 'inventoryAdjustQuantities' => { 'userErrors' => [] } })
    assert InventoryWriter.adjust_shopify!(inventory_item_id: 'gid://shopify/InventoryItem/9', delta: -2, location: @location,
      reference: 'count-1', idempotency_key: 'key-1', change_from: 5)
    change = captured.dig(:input, :changes).first
    assert_equal({ delta: -2, inventoryItemId: 'gid://shopify/InventoryItem/9', locationId: 'gid://shopify/Location/1', changeFromQuantity: 5 }, change)
    assert_equal 'available', captured.dig(:input, :name)
    assert_equal 'key-1', captured[:idempotencyKey]

    ShopifyClient.stubs(:graphql).returns({ 'inventoryAdjustQuantities' => { 'userErrors' => [{ 'message' => 'Stale quantity' }] } })
    error = assert_raises(ShopifyClient::Error) do
      InventoryWriter.adjust_shopify!(inventory_item_id: 'x', delta: 1, location: @location, reference: 'r', idempotency_key: 'k')
    end
    assert_equal 'Stale quantity', error.message
  end

  test 'physical_count! posts a single PHYSICAL_COUNT change with the caller idempotency key' do
    square = Location.create!(source: 'square', externalId: 'LSQ', name: 'Square')
    body = nil
    SquareClient.stubs(:request).with { |path, **opts| body = opts[:body] if path == InventoryWriter::SQUARE_COUNT_PATH }.returns({})
    InventoryWriter.physical_count!(catalog_object_id: 'VAR1', quantity: 7, location: square, reference_id: 'ref-1', idempotency_key: 'idem-1')
    assert_equal 'idem-1', body[:idempotency_key]
    change = body[:changes].first
    assert_equal 'PHYSICAL_COUNT', change[:type]
    assert_equal({ catalog: 'VAR1', qty: '7', loc: 'LSQ', ref: 'ref-1', state: 'IN_STOCK' },
      { catalog: change[:physical_count][:catalog_object_id], qty: change[:physical_count][:quantity], loc: change[:physical_count][:location_id],
        ref: change[:physical_count][:reference_id], state: change[:physical_count][:state] })
    assert body[:ignore_unchanged_counts]
  end

  test 'idempotency keys are URL-safe, bounded and distinct per adjustment' do
    assert_equal 'TEA50g', InventoryWriter.slugify('TEA-50/g')
    assert_equal 'item', InventoryWriter.slugify('')
    assert_equal 40, InventoryWriter.slugify('x' * 80).length
    Current.sync_run = SyncRun.new(id: 'run-1')
    assert_equal 'fix-TEA50-v1-run-1-5->-2', InventoryWriter.per_run_key('fix', 'TEA-50', 'v1', 5, -2)
    Current.sync_run = nil
  end
end
