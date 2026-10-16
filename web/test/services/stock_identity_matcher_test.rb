# frozen_string_literal: true

require 'test_helper'

class StockIdentityMatcherTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @at = Time.current.change(usec: 0)
    @product = ShopifyProduct.create!(id: 'match-product', title: 'Mountain Berry Indoor (Hybrid - 25.87% THCA)', status: 'ACTIVE', catalog_present: true, catalog_read_at: @at)
    @variant = ShopifyVariant.create!(id: 'match-variant', product: @product, title: '7 Grams', sku: 'WEB-7', tracked: true,
      catalog_present: true, catalog_read_at: @at, price: 60, inventoryQuantity: 19)
    @online = Location.create!(source: 'shopify', externalId: 'match-online', name: 'Online')
    @retail = Location.create!(source: 'ctrax', externalId: 'fixture/match', name: 'Retail')
    ShopifyStockSnapshot.create!(location: @online, shop_domain: 'fixture.myshopify.com', captured_at: @at,
      records_json: [{ 'id' => @variant.id, 'available' => 4, 'on_hand' => 5, 'committed' => 1 }])
    @record = { 'id' => 'match-native', 'product_name' => 'Mountain Berry', 'name' => 'Mountain Berry 7g',
      'quantity' => '2', 'manage_stock' => true, 'price_cents' => 6000 }
    @snapshot = CtraxStockSnapshot.create!(location: @retail, api_origin: 'https://fixture.api.cannatrax.net', store_id: '1', captured_at: @at,
      records_json: [@record])
  end

  teardown { Current.reset }

  test 'unique exact product words and explicit package produce a review candidate without a stock delta' do
    row = report.rows.first
    assert row[:paired]
    assert_equal 'Name/package candidate', row[:identity]
    assert_equal 5, row[:on_hand]
    assert_equal 2, row[:ctrax_quantity]
    assert_nil row[:difference]
    assert row[:evidence].any? { |e| e.include?('7 g') }
    assert_includes row[:issues], 'Potency/grade details differ or are missing'
    assert_equal @record['name'], row[:ctrax_label]
    assert_equal 19, @variant.reload.inventoryQuantity
    assert_equal '2', @snapshot.reload.records.first['quantity']
  end

  test 'package amount form flavor strength tier and explicit potency conflicts do not produce name candidates' do
    ['Mountain Berry 14g', 'Mountain Berry Resin 7g', 'Mountain Cherry 7g', 'Mountain Berry 7g 10mg',
     'Mountain Berry (27% THCA) 7g', 'Mountain Berry Outdoor 7g'].each do |name|
      @snapshot.update!(records_json: [@record.merge('name' => name)])
      assert report.rows.none? { |r| r[:paired] }, name
    end
    @product.update!(title: 'Mountain Berry Tier 2 Rosin')
    @snapshot.update!(records_json: [@record.merge('name' => 'Mountain Berry Tier 1 Rosin 7g')])
    assert report.rows.none? { |r| r[:paired] }
  end

  test 'duplicates remain ambiguous even with matching prices and no name-only package guesses' do
    @snapshot.update!(records_json: [@record, @record.merge('id' => 'duplicate-native')])
    assert report.rows.none? { |r| r[:paired] }
    @snapshot.update!(records_json: [@record.merge('name' => 'Mountain Berry')])
    assert report.rows.none? { |r| r[:paired] }
    @snapshot.update!(records_json: [@record])
    ShopifyVariant.create!(id: 'other-package-claim', product: @product, title: '7g', tracked: false, catalog_present: true, catalog_read_at: @at)
    assert report.rows.none? { |r| r[:paired] }
  end

  test 'valid cross-field GTINs match while invalid numeric identifiers do not' do
    @variant.update!(sku: '012345678905')
    @snapshot.update!(records_json: [@record.merge('barcode' => '0012345678905', 'name' => 'Other supplier description')])
    row = report.rows.first
    assert_equal 'Barcode candidate', row[:identity]
    assert_equal(-3, row[:difference])
    @variant.update!(sku: '012345678906')
    @snapshot.update!(records_json: [@record.merge('barcode' => '012345678906', 'name' => 'Other supplier description')])
    assert report.rows.none? { |r| r[:paired] }
  end

  test 'duplicate aliases and contradictory barcodes are not replaced by name evidence' do
    @variant.update!(sku: 'SHARED')
    @snapshot.update!(records_json: [@record.merge('sku' => 'SHARED'), @record.merge('id' => 'second-alias', 'sku' => 'SHARED', 'name' => 'Other 14g')])
    assert report.rows.none? { |r| r[:paired] }
    @variant.update!(barcode: '012345678905')
    @snapshot.update!(records_json: [@record.merge('sku' => 'SHARED', 'barcode' => '036000291452')])
    assert report.rows.none? { |r| r[:paired] }
    assert report.rows.any? { |r| r[:identity] == 'Conflicting barcode identifiers' }
  end

  test 'native claims take priority and conflicting source links block weaker evidence' do
    @snapshot.update!(records_json: [@record.merge('website_variant_id' => @variant.id)])
    assert_equal 'Source variant ID', report.rows.first[:identity]
    @snapshot.update!(records_json: [@record.merge('website_variant_id' => 'another-current-id')])
    assert report.rows.none? { |r| r[:paired] }
    @snapshot.update!(records_json: [@record.merge('website_product_id' => 'another-product-id')])
    assert report.rows.none? { |r| r[:paired] }
  end

  test 'an exact identifier with inconsistent package observations has no quantity difference' do
    @snapshot.update!(records_json: [@record.merge('sku' => @variant.sku, 'name' => 'Mountain Berry 14g')])
    row = report.rows.first
    assert row[:paired]
    assert_nil row[:difference]
    assert_includes row[:issues], 'Package sizes differ; quantity difference withheld'
  end

  test 'historical candidates explain unmatched source items without restoring old Shopify stock' do
    @variant.update!(catalog_present: false)
    row = report.rows.first
    assert_nil row[:shopify_id]
    assert_equal 'Historical Shopify candidate only', row[:identity]
    assert_equal @variant.id, row[:historical].first[:id]
    assert_nil row[:difference]
    assert_equal 19, @variant.reload.inventoryQuantity
    assert_equal 1, StockComparison.new(filter: 'historical', at: @at).rows.size
  end

  test 'historical evidence cannot expose another workspace' do
    @variant.update!(catalog_present: false)
    other = Tenant.create!(name: 'Other matching', subdomain: 'other-matching')
    product = ShopifyProduct.unscoped.create!(tenant_id: other.id, id: 'secret-product', title: @product.title)
    ShopifyVariant.unscoped.create!(tenant_id: other.id, id: 'secret-variant', productId: product.id, title: '7g', tracked: true)
    assert_equal [@variant.id], report.rows.first[:historical].map { |v| v[:id] }
  end

  test 'search and CSV include both source names and the matching evidence' do
    @snapshot.update!(records_json: [@record.merge('product_name' => 'Mountain Berry', 'name' => 'Mountain Berry MB 7g')])
    rows = StockComparison.new(query: 'MB 7g', filter: 'candidates', at: @at).rows
    assert_equal 1, rows.size
    csv = CSV.parse(StockComparison.new(filter: 'candidates', at: @at).csv)
    assert_includes csv.first, 'Match evidence'
    assert_includes csv.first, 'C-Trax item'
    assert_equal 'Name/package candidate', csv[1][4]
    assert_nil csv[1][11]
  end

  private

  def report = StockComparison.new(at: @at)
end
