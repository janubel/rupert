# frozen_string_literal: true

require 'test_helper'

class StockIdentityFindingsTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @at = Time.current.change(usec: 0)
    @product = ShopifyProduct.create!(id: 'findings-product', title: 'Copper Disposable Vape', status: 'ACTIVE', catalog_present: true)
    @variant = ShopifyVariant.create!(id: 'findings-variant', product: @product, title: 'Guava', sku: 'COPPER-G', price: 40,
      tracked: true, catalog_present: true, catalog_read_at: @at, inventoryQuantity: 17)
    online = Location.create!(source: 'shopify', externalId: 'findings-online', name: 'Online')
    retail = Location.create!(source: 'ctrax', externalId: 'findings-retail', name: 'Retail')
    @shopify = ShopifyStockSnapshot.create!(location: online, shop_domain: 'fixture.myshopify.com', captured_at: @at,
      records_json: [{ 'id' => @variant.id, 'on_hand' => 8, 'available' => 7, 'committed' => 1 }])
    @record = { 'id' => 'findings-native', 'name' => 'Copper Guava', 'product_name' => 'Copper', 'quantity' => '-2', 'manage_stock' => true }
    @ctrax = CtraxStockSnapshot.create!(location: retail, api_origin: 'https://fixture.api.cannatrax.net', store_id: '1', captured_at: @at, records_json: [@record])
  end

  teardown { Current.reset }

  test 'encrypted dated findings add an investigated family candidate without changing stock or SKUs' do
    assert report.rows.none? { |row| row[:paired] }
    publish
    row = report.rows.first
    assert_equal 'Investigated family candidate', row[:identity]
    assert row[:paired]
    assert_nil row[:difference]
    assert_includes row[:issues], 'Package equivalence unverified; quantity difference withheld'
    assert_equal 'Description supports the product family; retail package size is not specified', row[:finding_notes].first[:text]
    assert row[:finding_notes].first[:current]
    assert_equal 17, @variant.reload.inventoryQuantity
    assert_equal 'COPPER-G', @variant.sku
    assert_equal @record, @ctrax.reload.records.first
    encrypted = Setting.find_by!(key: StockIdentityFindings.key(@shopify, @ctrax), tenant_id: Current.tenant_id).read_attribute_before_type_cast(:value)
    refute_includes encrypted, 'Description supports'
    assert_equal 1, StockComparison.new(filter: 'findings', at: @at).rows.size
    assert_equal 1, StockComparison.new(filter: 'candidates', at: @at).rows.size
    csv = CSV.parse(report.csv)
    assert_includes csv.first, 'Investigation findings'
    assert_nil csv[1][11]
  end

  test 'changed catalog identities withhold candidates and retain clearly dated findings' do
    publish
    @variant.update!(sku: 'CHANGED')
    rows = report.rows
    assert rows.none? { |row| row[:paired] }
    assert rows.any? { |row| row[:finding_notes].any? && !row[:finding_notes].first[:current] }
    assert rows.all? { |row| row[:difference].nil? }
  end

  test 'expired source review withholds links but preserves notes as history' do
    publish
    comparison = StockComparison.new(at: @at + 8.days)
    assert comparison.rows.none? { |row| row[:paired] }
    assert comparison.rows.any? { |row| row[:finding_notes].any? }
    assert comparison.rows.flat_map { |row| row[:finding_notes] }.none? { |note| note[:current] }
    assert_includes comparison.findings.status, 'fresh source review'
  end

  test 'scope changes and another tenant cannot reuse saved investigation evidence' do
    publish
    @ctrax.update!(api_origin: 'https://another.api.cannatrax.net')
    assert report.rows.none? { |row| row[:paired] }
    assert report.rows.all? { |row| row[:finding_notes].empty? }
    other = Tenant.create!(name: 'Other findings', subdomain: 'other-findings')
    Current.tenant = other
    assert_raises(ArgumentError) { publish }
    assert_empty StockComparison.new(at: @at).rows
  end

  test 'an explicit investigated identifier candidate can disambiguate a reused SKU without editing it' do
    @product.update!(title: '30mg Guava Gummies')
    @variant.update!(title: '12 Count', sku: 'SHARED')
    product = ShopifyProduct.create!(id: 'other-findings-product', title: '30mg Lychee Gummies', status: 'ACTIVE', catalog_present: true)
    other = ShopifyVariant.create!(id: 'other-findings-variant', product: product, title: '12 Count', sku: 'SHARED', tracked: true, catalog_present: true)
    @record = @record.merge('name' => 'Guava Gummies 30mg 12ct', 'sku' => 'SHARED')
    @ctrax.update!(records_json: [@record])
    assert report.rows.none? { |row| row[:paired] }
    publish(kind: 'identifier')
    rows = report.rows
    assert_equal 1, rows.count { |row| row[:paired] }
    chosen = rows.find { |row| row[:shopify_id] == @variant.id }
    assert_equal 'Investigated identifier candidate', chosen[:identity]
    assert_nil chosen[:difference]
    assert_nil rows.find { |row| row[:shopify_id] == other.id }[:ctrax_id]
    assert_equal %w[SHARED SHARED], [@variant.reload.sku, other.reload.sku]
  end

  test 'investigations cannot override conflicting source IDs, explicit packages or a stronger current claim' do
    @ctrax.update!(records_json: [@record.merge('website_variant_id' => 'elsewhere')])
    publish
    assert report.rows.none? { |row| row[:paired] }
    @variant.update!(title: '7g')
    @record = @record.merge('name' => 'Copper Guava 14g')
    @ctrax.update!(records_json: [@record])
    publish
    assert report.rows.none? { |row| row[:paired] }
    @variant.update!(title: 'Guava')
    @record = @record.merge('sku' => 'STRONGER')
    @ctrax.update!(records_json: [@record])
    other = ShopifyVariant.create!(id: 'stronger-findings', product: @product, title: 'Other', sku: 'STRONGER', tracked: true, catalog_present: true)
    publish
    assert_nil report.rows.find { |row| row[:shopify_id] == @variant.id }[:ctrax_id]
    assert_equal @record['id'], report.rows.find { |row| row[:shopify_id] == other.id }[:ctrax_id]
  end

  test 'invalid and duplicate candidate imports fail before replacing saved findings' do
    publish
    original = Setting.find_by!(key: StockIdentityFindings.key(@shopify, @ctrax), tenant_id: Current.tenant_id).value
    assert_raises(ArgumentError) { StockIdentityFindings.publish!(shopify: @shopify, ctrax: @ctrax, reviewed_at: @at.iso8601, notes: [], candidates: [proposal, proposal]) }
    assert_raises(ArgumentError) { StockIdentityFindings.publish!(shopify: @shopify, ctrax: @ctrax, reviewed_at: @at.iso8601, notes: [], candidates: [proposal.merge('ctrax_id' => 'unknown')]) }
    assert_equal original, Setting.find_by!(key: StockIdentityFindings.key(@shopify, @ctrax), tenant_id: Current.tenant_id).value
  end

  private

  def report = StockComparison.new(at: @at)

  def proposal(kind = 'family')
    { 'shopify_id' => @variant.id, 'ctrax_id' => @record['id'], 'kind' => kind, 'evidence' => 'Source description explicitly supports this family; package is not approved' }
  end

  def publish(kind: 'family')
    StockIdentityFindings.publish!(shopify: @shopify, ctrax: @ctrax, reviewed_at: @at.iso8601,
      notes: [{ 'shopify_id' => @variant.id, 'ctrax_id' => @record['id'], 'text' => 'Description supports the product family; retail package size is not specified', 'severity' => 'warning' }], candidates: [proposal(kind)])
  end
end
