# frozen_string_literal: true

require 'test_helper'

class SquareClientTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    SquareClient.stubs(:token).returns('synthetic')
  end

  teardown { Current.reset }

  test 'orders search filters and sorts on updated_at so refunds and returns re-select the order' do
    stub = stub_request(:post, 'https://connect.squareup.com/v2/orders/search')
      .with do |req|
        body = JSON.parse(req.body)
        body.dig('query', 'filter', 'date_time_filter').key?('updated_at') && body.dig('query', 'sort', 'sort_field') == 'UPDATED_AT'
      end
      .to_return(status: 200, body: { orders: [{ id: 'o1' }] }.to_json)
    assert_equal [{ 'id' => 'o1' }], SquareClient.orders(['L1'], '2026-01-01T00:00:00Z')
    assert_requested stub
  end

  test 'catalog follows the cursor and skips deleted items and variations' do
    page1 = { objects: [{ type: 'ITEM', id: 'I1', item_data: { name: 'Tea', variations: [
      { id: 'V1', item_variation_data: { sku: 'TEA-1', name: '50g' } }, { id: 'V2', is_deleted: true, item_variation_data: { sku: 'OLD' } }] } },
      { type: 'ITEM', id: 'I2', is_deleted: true, item_data: { name: 'Gone', variations: [{ id: 'V3' }] } }], cursor: 'c1' }
    page2 = { objects: [{ type: 'ITEM', id: 'I3', item_data: { name: 'Mug', variations: [{ id: 'V4', item_variation_data: {} }] } }] }
    stub_request(:get, 'https://connect.squareup.com/v2/catalog/list?limit=1000&types=ITEM').to_return(status: 200, body: page1.to_json)
    stub_request(:get, 'https://connect.squareup.com/v2/catalog/list?cursor=c1&limit=1000&types=ITEM').to_return(status: 200, body: page2.to_json)
    rows = SquareClient.catalog
    assert_equal %w[V1 V4], rows.map { |r| r[:variationId] }
    assert_equal({ variationId: 'V4', itemId: 'I3', sku: '', name: 'Mug' }, rows.last)
  end

  test 'inventory_counts sums IN_STOCK counts per variation and per location in batches of 100' do
    ids = (1..150).map { |i| "V#{i}" }
    stub_request(:post, 'https://connect.squareup.com/v2/inventory/counts/batch-retrieve')
      .with { |req| JSON.parse(req.body)['catalog_object_ids'].length <= 100 }
      .to_return(status: 200, body: { counts: [
        { catalog_object_id: 'V1', location_id: 'L1', state: 'IN_STOCK', quantity: '3' },
        { catalog_object_id: 'V1', location_id: 'L2', state: 'IN_STOCK', quantity: '2' },
        { catalog_object_id: 'V2', location_id: 'L1', state: 'SOLD', quantity: '9' },
        { catalog_object_id: 'V3', location_id: 'L1', state: 'IN_STOCK', quantity: nil }] }.to_json)
    result = SquareClient.inventory_counts(%w[L1 L2], ids)
    assert_equal 10, result[:counts]['V1'], 'two batches each returned the stub'
    assert_equal 0, result[:counts]['V2']
    assert_equal 6, result[:counts_by_location]['L1']['V1']
    assert_requested :post, 'https://connect.squareup.com/v2/inventory/counts/batch-retrieve', times: 2
  end

  test 'inventory_counts follows every cursor while keeping location pools independent' do
    endpoint = 'https://connect.squareup.com/v2/inventory/counts/batch-retrieve'
    stub_request(:post, endpoint)
      .with { |req| JSON.parse(req.body).exclude?('cursor') }
      .to_return(status: 200, body: { counts: [
        { catalog_object_id: 'V1', location_id: 'L1', state: 'IN_STOCK', quantity: '5' }
      ], cursor: 'counts-page-2' }.to_json)
    stub_request(:post, endpoint)
      .with { |req| JSON.parse(req.body)['cursor'] == 'counts-page-2' }
      .to_return(status: 200, body: { counts: [
        { catalog_object_id: 'V1', location_id: 'L2', state: 'IN_STOCK', quantity: '2' }
      ] }.to_json)

    result = SquareClient.inventory_counts(%w[L1 L2], ['V1'])

    assert_equal 7, result[:counts]['V1']
    assert_equal 5, result[:counts_by_location]['L1']['V1']
    assert_equal 2, result[:counts_by_location]['L2']['V1']
    assert_requested :post, endpoint, times: 2
  end

  test 'inventory_counts fails instead of returning an incomplete snapshot when a page fails' do
    endpoint = 'https://connect.squareup.com/v2/inventory/counts/batch-retrieve'
    stub_request(:post, endpoint)
      .with { |req| JSON.parse(req.body).exclude?('cursor') }
      .to_return(status: 200, body: { counts: [
        { catalog_object_id: 'V1', location_id: 'L1', state: 'IN_STOCK', quantity: '5' }
      ], cursor: 'counts-page-2' }.to_json)
    stub_request(:post, endpoint)
      .with { |req| JSON.parse(req.body)['cursor'] == 'counts-page-2' }
      .to_return(status: 503, body: '{}')

    assert_raises(SquareClient::Error) { SquareClient.inventory_counts(%w[L1 L2], ['V1']) }
    assert_requested :post, endpoint, times: 1 do |req|
      JSON.parse(req.body).exclude?('cursor')
    end
    assert_requested :post, endpoint, times: HttpRetry::MAX_ATTEMPTS do |req|
      JSON.parse(req.body)['cursor'] == 'counts-page-2'
    end
  end

  test 'inventory_counts rejects a repeated cursor instead of looping on replayed pages' do
    endpoint = 'https://connect.squareup.com/v2/inventory/counts/batch-retrieve'
    stub_request(:post, endpoint)
      .with { |req| JSON.parse(req.body).exclude?('cursor') }
      .to_return(status: 200, body: { counts: [], cursor: 'same-cursor' }.to_json)
    stub_request(:post, endpoint)
      .with { |req| JSON.parse(req.body)['cursor'] == 'same-cursor' }
      .to_return(status: 200, body: { counts: [], cursor: 'same-cursor' }.to_json)

    error = assert_raises(SquareClient::Error) { SquareClient.inventory_counts(['L1'], ['V1']) }

    assert_equal :response, error.reason
    assert_requested :post, endpoint, times: 2
  end

  test 'locations keeps only ACTIVE locations, environment picks the sandbox host, configured? needs a token' do
    stub_request(:get, 'https://connect.squareup.com/v2/locations')
      .to_return(status: 200, body: { locations: [{ id: 'L1', status: 'ACTIVE' }, { id: 'L2', status: 'INACTIVE' }] }.to_json)
    assert_equal ['L1'], SquareClient.locations.map { |l| l['id'] }
    SquareClient.stubs(:environment).returns('sandbox')
    assert_equal 'https://connect.squareupsandbox.com/v2', SquareClient.base_url
    SquareClient.unstub(:token)
    EnvStore.clear_cache!
    assert_not SquareClient.configured?
  end

  test 'orders reads every location in groups of ten and drops repeats' do
    seen = []
    stub_request(:post, 'https://connect.squareup.com/v2/orders/search').to_return do |req|
      ids = JSON.parse(req.body)['location_ids']
      seen << ids
      { status: 200, body: { orders: [{ id: "o-#{ids.first}" }, { id: 'shared' }] }.to_json }
    end
    locations = (1..12).map { |n| "L#{n}" }
    orders = SquareClient.orders(locations, '2026-01-01T00:00:00Z')
    assert_equal [locations.first(10), locations.last(2)], seen
    assert_equal %w[o-L1 shared o-L11], orders.map { |order| order['id'] }
  end

  test 'orders past the cap fail instead of returning a partial list' do
    stub_request(:post, 'https://connect.squareup.com/v2/orders/search')
      .to_return(status: 200, body: { orders: [{ id: 'a' }, { id: 'b' }, { id: 'c' }], cursor: 'next' }.to_json)
    error = assert_raises(SquareClient::Error) { SquareClient.orders(['L1'], '2026-01-01T00:00:00Z', max: 2) }
    assert_includes error.message, 'nothing was imported'
  end
end
