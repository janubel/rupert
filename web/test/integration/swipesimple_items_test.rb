# frozen_string_literal: true

require 'test_helper'
require_relative '../support/swipesimple_web_stubs'

class SwipesimpleItemsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    product = ShopifyProduct.create!(id: 'ss-product', title: 'Blue Dream Flower', status: 'ACTIVE', catalog_present: true)
    @variant = ShopifyVariant.create!(id: 'ss-variant', productId: product.id, title: '3.5g', sku: 'BD-35', price: 35, tracked: true, catalog_present: true)
    ShopifyVariant.create!(id: 'ss-gummy', productId: product.id, title: '10 count', sku: 'GUM-10', price: 20, tracked: true, catalog_present: true)
    SquareItem.create!(id: 'sq-bd', name: 'Blue Dream')
    SquareVariation.create!(id: 'sq-bd-35', itemId: 'sq-bd', name: '3.5g', sku: 'BD-35')
    SkuLink.create!(sku: 'BD-35', shopifyVariantId: @variant.id, squareVariationId: 'sq-bd-35')
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end
  teardown { Current.reset }

  def upload(csv)
    post swipesimple_items_path, params: { merchant_account: 'Main register',
      file: Rack::Test::UploadedFile.new(StringIO.new(csv), 'text/csv', original_filename: 'items.csv') }
  end

  test 'imports a SwipeSimple item list and lines it up with Shopify and Square names' do
    get swipesimple_items_path
    assert_response :success
    assert_select 'h1', 'SwipeSimple items'

    assert_no_difference ['ShopifyVariant.count', 'SquareVariation.count', 'SkuLink.count'] do
      upload("Name,Variant,SKU,Quantity\nBlue Dream,3.5g,BD-35,12\nMystery Item,,ZZ-1,\n")
    end
    snapshot = SwipesimpleItemSnapshot.sole
    assert_redirected_to swipesimple_items_path(snapshot_id: snapshot.id)
    follow_redirect!
    assert_response :success
    assert_select '[data-controller=report-table] table'
    assert_includes response.body, 'Blue Dream Flower 3.5g'
    assert_includes response.body, 'Blue Dream · 3.5g'
    assert_includes response.body, 'Different name'
    assert_includes response.body, 'Not matched'

    rows = SwipesimpleItemMatch.new(snapshot).rows.index_by(&:swipesimple_name)
    assert_equal ['Matched', 'SKU candidate', 'ss-variant', 'Blue Dream Flower 3.5g'], rows['Blue Dream 3.5g'].to_h.values_at(:status, :identity, :shopify_id, :suggested_name)
    assert_equal 'Not matched', rows['Mystery Item'].status

    get swipesimple_items_path(format: :csv)
    assert_response :success
    assert_includes response.body, 'Suggested SwipeSimple name'
    assert_includes response.body, 'Blue Dream Flower 3.5g'
  end

  test 'a bad file changes nothing and explains why' do
    upload("SKU,Quantity\nBD-35,1\n")
    assert_redirected_to swipesimple_items_path
    assert_match(/Nothing was imported/, flash[:alert])
    assert_equal 0, SwipesimpleItemSnapshot.count
  end

  test 'an automatically pulled item list shows when it was pulled and each item tax' do
    records = SwipesimpleWeb::ItemsWorkbook.parse(Class.new { include SwipesimpleWebStubs }.new.items_xlsx)
    items = SwipesimpleWeb::Client::ItemsSnapshot.new(records: records, sha256: 'fixture-sha', exported_at: Time.current.iso8601)
    assert SwipesimpleWeb::ReportStore.replace_items!(items, merchant_account: 'Example Wholesale')
    refute SwipesimpleWeb::ReportStore.replace_items!(items, merchant_account: 'Example Wholesale')
    get swipesimple_items_path
    assert_response :success
    assert_includes response.body, 'Pulled automatically at'
    assert_select 'th[data-col=tax]', 'Tax'
    assert_includes response.body, 'Taxable · PA Tax (6.0%)'
    assert_includes response.body, 'Not taxed · No Tax'
    assert_includes response.body, 'Upload an item list by hand (fallback)'
    assert_includes response.body, 'Blue Dream Flower 3.5g'
    assert_not_includes response.body, 'Old Lighter'
  end

  test 'SwipeSimple items sit in the Stock area' do
    assert_equal 'stock', ModuleRegistry.area_key_for('swipesimple_items')
  end
end
