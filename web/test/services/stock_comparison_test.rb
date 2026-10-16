# frozen_string_literal: true

require 'test_helper'

class StockComparisonTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @at = Time.current.change(usec: 0)
    @product = ShopifyProduct.create!(id: 'compare-product', title: 'Tea', status: 'ACTIVE', catalog_present: true, catalog_read_at: @at)
    @variant = ShopifyVariant.create!(id: 'gid://shopify/ProductVariant/compare', product: @product, title: '30 count', sku: 'TEA',
      tracked: true, catalog_present: true, catalog_read_at: @at)
    @online = Location.create!(source: 'shopify', externalId: 'online', name: 'Online')
    @retail = Location.create!(source: 'ctrax', externalId: 'fixture/1', name: 'Retail')
    @s = ShopifyStockSnapshot.create!(location: @online, shop_domain: 'fixture.myshopify.com', captured_at: @at,
      records_json: [{ 'id' => @variant.id, 'available' => 3, 'on_hand' => 5, 'committed' => 2 }])
    @c = CtraxStockSnapshot.create!(location: @retail, api_origin: 'https://fixture.api.cannatrax.net', store_id: '1', captured_at: @at,
      records_json: [{ 'id' => 'ct-1', 'sku' => ' tea ', 'name' => 'Tea 30 count', 'quantity' => '0', 'manage_stock' => true }])
  end

  teardown { Current.reset }

  test 'compares signed native states without summing shared quantities' do
    row = report.rows.first
    assert_equal 'SKU candidate', row[:identity]
    assert_equal 5, row[:on_hand]
    assert_equal 3, row[:available]
    assert_equal 2, row[:committed]
    assert_equal 0, row[:ctrax_quantity]
    assert_equal(-5, row[:difference])
    @c.update!(records_json: [@c.records.first.merge('quantity' => '-3')])
    assert_includes report.rows.first[:issues], 'Negative stock'
    assert_equal(-8, report.rows.first[:difference])
  end

  test 'missing stock is unknown and never converted to zero' do
    @c.update!(records_json: [@c.records.first.merge('quantity' => nil)])
    assert_nil report.rows.first[:ctrax_quantity]
    assert_nil report.rows.first[:difference]
    assert_includes report.rows.first[:issues], 'Unknown stock'
  end

  test 'stale fractional untracked and wrong-epoch observations have no difference' do
    @c.update!(captured_at: @at - 2.hours)
    assert_nil report.rows.first[:difference]
    @c.update!(captured_at: @at, records_json: [@c.records.first.merge('quantity' => '1.5')])
    assert_nil report.rows.first[:difference]
    @c.update!(records_json: [@c.records.first.merge('quantity' => '1', 'manage_stock' => false)])
    assert_nil report.rows.first[:difference]
    @variant.update!(catalog_read_at: @at + 1.minute)
    assert_nil report.rows.first[:on_hand]
  end

  test 'missing archived untracked and Square records do not become current sellable stock' do
    @variant.update!(catalog_present: false)
    assert report.rows.all? { |r| r[:shopify_id].nil? }
    @variant.update!(catalog_present: true, tracked: false)
    assert report.rows.all? { |r| r[:shopify_id].nil? }
    @variant.update!(tracked: true)
    @product.update!(status: 'ARCHIVED')
    assert report.rows.all? { |r| r[:shopify_id].nil? }
  end

  test 'duplicate source SKUs and native claims remain unpaired' do
    ShopifyVariant.create!(id: 'duplicate-compare', product: @product, title: 'Other pack', sku: 'TEA', tracked: true,
      catalog_present: true, catalog_read_at: @at)
    assert report.rows.none? { |r| r[:paired] }
    assert report.rows.all? { |r| r[:difference].nil? }
    @c.update!(records_json: [@c.records.first.merge('website_variant_id' => @variant.id),
      @c.records.first.merge('id' => 'ct-2', 'website_variant_id' => @variant.id)])
    assert report.rows.none? { |r| r[:paired] }
  end

  test 'conflicting native source ID cannot be replaced by a SKU and orphan source rows stay visible' do
    @c.update!(records_json: [@c.records.first.merge('website_variant_id' => 'other-native-id')])
    assert_equal 2, report.rows.size
    assert report.rows.none? { |r| r[:paired] }
  end

  test 'cross-tenant location selection is rejected and multiple stores need explicit selection' do
    other = Tenant.create!(name: 'Other compare', subdomain: 'other-compare')
    other_location = Location.unscoped.create!(tenant_id: other.id, source: 'shopify', externalId: 'other', name: 'Secret')
    assert_raises(ActiveRecord::RecordNotFound) { StockComparison.new(shopify_location_id: other_location.id) }
    location = Location.create!(source: 'ctrax', externalId: 'fixture/2', name: 'Second')
    CtraxStockSnapshot.create!(location: location, api_origin: @c.api_origin, store_id: '2', captured_at: @at, records_json: [])
    assert_nil report.ctrax
    assert report.rows.all? { |r| r[:difference].nil? }
  end

  test 'a conflicting native product link prevents a SKU candidate' do
    @c.update!(records_json: [@c.records.first.merge('website_product_id' => 'another-product')])
    assert_equal 2, report.rows.size
    assert report.rows.none? { |r| r[:paired] }
    assert report.rows.all? { |r| r[:difference].nil? }
    assert_includes report.rows.find { |r| r[:shopify_id] }[:issues], 'Conflicting source product ID'
  end

  test 'CSV export is inert and includes source timestamps and negative quantities' do
    @product.update!(title: '=HYPERLINK("bad")')
    @c.update!(records_json: [@c.records.first.merge('quantity' => '-3')])
    csv = CSV.parse(report.csv)
    assert csv[1][0].start_with?("'=")
    assert_includes csv.first, 'Shopify read time'
    assert_equal '-3', csv[1][10]
  end

  private

  def report
    StockComparison.new(at: @at)
  end
end
