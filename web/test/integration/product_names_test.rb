# frozen_string_literal: true

require 'test_helper'
require 'tempfile'

class ProductNamesTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    at = Time.current.change(usec: 0)
    product = ShopifyProduct.create!(id: 'names-product', title: 'Rest Gummies', status: 'ACTIVE', catalog_present: true, catalog_read_at: at)
    @variant = ShopifyVariant.create!(id: 'names-variant', product: product, title: '15 Count', sku: 'REST15', tracked: true,
      catalog_present: true, catalog_read_at: at)
    other = ShopifyProduct.create!(id: 'names-other', title: 'Glass Bowl - small', status: 'ACTIVE', catalog_present: true, catalog_read_at: at)
    ShopifyVariant.create!(id: 'names-bowl', product: other, title: 'Default Title', sku: 'BOWL', tracked: true, catalog_present: true, catalog_read_at: at)
    knife = ShopifyProduct.create!(id: 'names-knife', title: 'Hot Knife Pro', status: 'ACTIVE', catalog_present: true, catalog_read_at: at)
    ShopifyVariant.create!(id: 'names-knife-v', product: knife, title: 'Default Title', sku: 'KNIFEPRO', tracked: true, catalog_present: true, catalog_read_at: at)
    item = SquareItem.create!(id: 'sq-item', name: '15 Count')
    square = SquareVariation.create!(id: 'sq-var', item: item, name: '15 Count', sku: 'REST15')
    SkuLink.create!(shopifyVariantId: @variant.id, squareVariationId: square.id, sku: 'REST15', matchSource: 'sku')
    retail = Location.create!(source: 'ctrax', externalId: 'fixture/names', name: 'Retail')
    CtraxStockSnapshot.create!(location: retail, api_origin: 'https://fixture.api.cannatrax.net', store_id: '1', captured_at: at,
      records_json: [{ 'id' => 'ct-1', 'sku' => nil, 'name' => 'Glass bowl small', 'quantity' => '2', 'listed' => true },
                     { 'id' => 'ct-2', 'sku' => nil, 'name' => 'Mystery Item', 'quantity' => '1', 'listed' => true }])
    @file = Tempfile.new(['swipesimple', '.tsv'])
    @file.write("name\tsku\tprice\ttax\tcount\ttracked\tcategory\nRest - Gummies 15 Count\tREST15\t$30.00\tTaxable\t4\ttracked\tEdibles\nHot Knife\t\t$40.00\tTaxable\tN/A\tnot tracked\t\n")
    @file.flush
    @previous = ENV['PRODUCT_NAMES_SWIPESIMPLE_FILE']
    ENV['PRODUCT_NAMES_SWIPESIMPLE_FILE'] = @file.path
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown do
    ENV['PRODUCT_NAMES_SWIPESIMPLE_FILE'] = @previous
    @file.close!
    Current.reset
  end

  test 'website name is primary and secondary names match by SKU or normalized name' do
    rows = ProductNameCrosswalk.new.rows.index_by { |r| r[:variant_id] }
    rest = rows.fetch('names-variant')
    assert_equal 'Rest Gummies - 15 Count', rest[:name]
    assert_equal 'SKU link', rest.dig(:square, :how)
    assert_equal 'SKU', rest.dig(:swipesimple, :how)
    assert_equal 'Rest - Gummies 15 Count', rest.dig(:swipesimple, :name)
    assert_equal 'Glass bowl small', rows.fetch('names-bowl').dig(:ctrax, :name)
    assert_equal 'Name (exact normalized)', rows.fetch('names-bowl').dig(:ctrax, :how)
  end

  test 'unmatched secondary items are listed and normalization unifies units' do
    crosswalk = ProductNameCrosswalk.new
    assert_equal ['Mystery Item'], crosswalk.unmatched[:ctrax].map { |i| i[:name] }
    assert_equal ['Hot Knife'], crosswalk.unmatched[:swipesimple].map { |i| i[:name] }
    assert_equal 'Hot Knife Pro', crosswalk.unmatched[:swipesimple].first[:suggestion]
    assert_equal %w[Hot\ Knife Mystery\ Item], crosswalk.unmatched_list.map { |i| i[:name] }
    assert_equal ProductNameCrosswalk.normalize('Big Dipper (Hybrid- 31.45% THCA) - 1 Gram'), ProductNameCrosswalk.normalize('big dipper - 1g')
    assert_equal ProductNameCrosswalk.normalize('Tea & Honey - 1 ounce'), ProductNameCrosswalk.normalize('tea and honey 1oz')
  end

  test 'missing SwipeSimple file leaves that system empty without error' do
    ENV['PRODUCT_NAMES_SWIPESIMPLE_FILE'] = '/nonexistent/items.tsv'
    crosswalk = ProductNameCrosswalk.new
    assert_not crosswalk.swipesimple_available?
    assert_nil crosswalk.rows.first[:swipesimple]
    get product_names_path
    assert_response :success
    assert_includes response.body, 'No catalog loaded'
  end

  test 'page, CSV and print sheets are read-only and never contact providers' do
    ShopifyClient.expects(:graphql).never
    Ctrax::StockSync.expects(:call).never
    InventoryWriter.expects(:adjust_shopify!).never
    get product_names_path
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select 'h1', 'Product names'
    assert_select 'a', text: 'Print: Names to verify'
    assert_includes response.body, 'Rest Gummies - 15 Count'
    assert_equal ['Website (Shopify)', 'SwipeSimple', 'Square', 'C-Trax'], css_select('thead th').map { |th| th.text.strip }
    assert_select 'th[scope=rowgroup]', text: /Not on the website/
    assert_select 'tr[data-unmatched-row]', 2
    assert_select 'tr[data-unmatched-row] span.italic', text: '(Hot Knife Pro)'
    get product_names_path(filter: 'unmatched')
    assert_includes response.body, 'Mystery Item'
    get product_names_path(format: :csv)
    assert_equal 'text/csv', response.media_type
    assert_includes response.body, 'Primary website name (Shopify)'
    ProductNamePdf::SHEETS.each_key do |sheet|
      get pdf_product_names_path(sheet: sheet)
      assert_response :success
      assert_equal 'application/pdf', response.media_type
      assert response.body.start_with?('%PDF'), "#{sheet} is not a PDF"
    end
    get pdf_product_names_path(sheet: 'nope')
    assert_response :not_found
  end
end
