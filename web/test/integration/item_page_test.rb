# frozen_string_literal: true

require 'test_helper'

# The item page: real name instead of "Default Title", centered photo and name, cost, margin and stock everywhere.
class ItemPageTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    post login_path, params: { email: users(:regular_user).email, password: 'password' }
    @product = ShopifyProduct.create!(id: 'item-tea', title: 'Herbal Tea', status: 'ACTIVE', featuredImageUrl: 'https://cdn.example.test/tea.png',
      vendor: 'Leaf Farms', productType: 'Tea', tags: 'loose, calm')
    @variant = ShopifyVariant.create!(id: 'gid://shopify/ProductVariant/item-1', product: @product, title: 'Default Title', sku: 'TEA-50',
      barcode: '0123', price: 20.0, tracked: true, inventoryQuantity: 4)
    store = Location.create!(source: 'ctrax', externalId: 'item/1', name: 'Main Street')
    CtraxStockSnapshot.create!(location: store, api_origin: 'https://fixture.api.cannatrax.net', store_id: '1', captured_at: Time.current,
      records_json: [{ 'id' => 'ct-tea', 'sku' => 'TEA-50', 'name' => 'Herbal Tea 50g', 'quantity' => '6', 'manage_stock' => true, 'cost_cents' => 600 }])
  end

  teardown { Current.reset }

  test 'a single-variant item shows its product name, centered photo, price, cost and margin, not Default Title' do
    get shopify_variant_path(@variant)
    assert_response :success
    assert_select 'h1', 'Herbal Tea'
    assert_select 'title', /Herbal Tea/
    assert_not_includes response.body, 'Default Title'
    assert_select '.item-hero .item-hero-image img[src="https://cdn.example.test/tea.png"]'
    assert_select '.item-hero-facts', /Price.*\$20\.00/m
    assert_select '.item-hero-facts', /Cost of goods.*\$6\.00.*As entered in C-Trax \(same sku\)/m
    assert_select '.item-hero-facts', /Margin per unit.*\$14\.00 \(70\.0%\)/m
    assert_select 'section[aria-labelledby=item-source-title]', /Leaf Farms.*Tea.*Herbal Tea 50g/m
    assert_select 'section[aria-labelledby=item-stock-title] tr', /C-Trax.*Main Street.*6/m
  end

  test 'cost stays unknown when the C-Trax item has none, and a variant option is shown under the name' do
    CtraxStockSnapshot.sole.update!(records_json: [{ 'id' => 'ct-tea', 'sku' => 'TEA-50', 'name' => 'Herbal Tea 50g', 'quantity' => '6', 'manage_stock' => true }])
    @variant.update!(title: '50g')
    get shopify_variant_path(@variant)
    assert_select 'h1', 'Herbal Tea · 50g'
    assert_select '.item-hero-option', '50g'
    assert_select '.item-hero-facts', /Cost of goods.*Unknown.*Not entered in C-Trax/m
    assert_select '.item-hero-facts', /Margin per unit.*Unknown/m
  end

  test 'ItemProfile drops Shopify and Square placeholder titles' do
    assert_equal 'Herbal Tea', ItemProfile.display_name(@variant)
    @variant.title = 'Regular'
    assert_equal 'Herbal Tea', ItemProfile.display_name(@variant)
    @variant.title = '100g'
    assert_equal 'Herbal Tea · 100g', ItemProfile.display_name(@variant)
  end
end
