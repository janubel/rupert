# frozen_string_literal: true

require 'test_helper'
class CtraxCatalogImagesTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @location = Location.create!(source: 'ctrax', externalId: 'fixture/7', name: 'Retail')
    @product = ShopifyProduct.create!(id: 'gid://shopify/Product/42', title: 'Tea', status: 'ACTIVE', featuredImageUrl: 'https://cdn.shopify.com/tea.jpg')
    ShopifyVariant.create!(productId: @product.id, title: 'Tin', sku: 'TEA', price: 5)
  end
  teardown { Current.reset }
  test 'exact product IDs SKU and unambiguous normalized parent titles match without fuzzy guessing' do
    images = Ctrax::CatalogImages.new(@location)
    [{ 'website_product_id' => '42' }, { 'sku' => 'TEA' }, { 'product_name' => ' tea! ' }].each do |record|
      assert_includes images.url(record), 'cdn.shopify.com/tea.jpg'
    end
    assert_nil images.url('product_name' => 'Almost Tea')
    second = ShopifyProduct.create!(id: 'other-tea', title: 'Tea', status: 'ACTIVE', featuredImageUrl: 'https://cdn.shopify.com/other.jpg')
    ShopifyVariant.create!(productId: second.id, title: 'Tin', sku: 'TEA', price: 2)
    assert_nil Ctrax::CatalogImages.new(@location).url('sku' => 'TEA', 'product_name' => 'Tea')
  end
  test 'local mapping is tenant scoped and unsafe images are never rendered' do
    CtraxImageLink.create!(location: @location, variant_id: '3', shopify_product: @product)
    assert_includes Ctrax::CatalogImages.new(@location).url('id' => '3'), 'tea.jpg'
    @product.update!(featuredImageUrl: 'https://evil.example/track.jpg')
    assert_nil Ctrax::CatalogImages.new(@location).url('id' => '3')
    other = Tenant.create!(name: 'Other', subdomain: 'other-ctrax-image')
    foreign = ShopifyProduct.unscoped.create!(id: 'other-product', tenant_id: other.id, title: 'Tea', status: 'ACTIVE')
    assert_not CtraxImageLink.new(location: @location, variant_id: '4', shopify_product: foreign).valid?
  end
end
