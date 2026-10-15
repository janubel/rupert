# frozen_string_literal: true

require 'test_helper'

class PointOfSaleTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    @product = ShopifyProduct.create!(id: 'pos-product', title: 'Image Tea', status: 'ACTIVE',
      featuredImageUrl: 'https://cdn.example.com/tea.jpg')
    @variant = ShopifyVariant.create!(productId: @product.id, title: 'Tin', sku: 'POS-TEA', price: 12.35)
    post login_path, params: { email: @user.email, password: 'password' }
  end

  teardown { Current.reset }

  test 'catalog has product images variant quantity controls and honest preview labels' do
    get point_of_sale_path
    assert_response :success
    assert_select 'h1', 'POS preview'
    assert_select 'img[alt="Image Tea"][src*="tea.jpg"]'
    assert_select 'input[name="items[0][variant_id]"][value=?]', @variant.id
    assert_select 'input[name="items[0][quantity]"][min="1"][max="999"]'
    assert_select 'p', /creates no sale, payment, receipt or stock reservation/
    assert_select 'p', /currency code is not mirrored yet/
    assert_select 'legend', 'Optional tip'
    assert_select 'select[name=tip_type] option[selected][value=none]'
    assert_select 'p', /no tip is collected/
    assert_select 'meta[name=turbo-cache-control][content=no-cache]'
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  test 'quote uses current server catalog prices ignores client prices and creates no records' do
    @variant.update!(price: 14.70)
    counts = [Core::Order.count, Core::Payment.count, InventoryMovement.count, StockReservation.count]
    post quote_point_of_sale_path, params: { items: [{
      variant_id: @variant.id, quantity: 3, unit_price: '0.01', line_total: '0.03', title: 'Tampered',
      thumbnail_url: 'https://evil.example/image.jpg', source: 'square'
    }], subtotal: '0.03', currency_code: 'USD' }, as: :json
    assert_response :success
    result = response.parsed_body
    assert_equal '44.1', result['subtotal']
    assert_equal '0.0', result['tip_amount']
    assert_equal '44.1', result['preview_total']
    line = result.fetch('lines').first
    assert_equal '14.7', line['unit_price']
    assert_equal 3, line['quantity']
    assert_equal 'Image Tea', line['product_title']
    assert_equal 'Tin', line['title']
    assert_match(%r{https://cdn.example.com/tea.jpg}, line['thumbnail_url'])
    assert_equal 'shopify', result['source']
    assert_nil result['currency_code']
    %w[tax_calculated payment_processed stock_reserved sale_created].each { |flag| assert_equal false, result[flag] }
    assert_equal counts, [Core::Order.count, Core::Payment.count, InventoryMovement.count, StockReservation.count]
  end

  test 'decimal arithmetic remains exact and zero-price items are supported' do
    @variant.update!(price: 0.10)
    free = ShopifyVariant.create!(productId: @product.id, title: 'Sample', sku: 'POS-SAMPLE', price: 0)
    post quote_point_of_sale_path, params: { items: [
      { variant_id: @variant.id, quantity: '3' }, { variant_id: free.id, quantity: '1' }
    ] }, as: :json
    assert_response :success
    assert_equal '0.3', response.parsed_body['subtotal']
    assert_equal '0.0', response.parsed_body['lines'].last['line_total']
  end

  test 'HTML preview shows selected product image quantities and subtotal' do
    post quote_point_of_sale_path, params: { items: { '0' => { variant_id: @variant.id, quantity: '2' } } }
    assert_response :success
    assert_select '[data-pos-cart-target=items] img[alt="Image Tea"]'
    assert_select '[data-pos-cart-target=items] input[name="items[0][quantity]"][value="2"]'
    assert_select '[data-pos-cart-target=subtotal]', '24.70'
  end

  test 'missing foreign-tenant inactive and orphaned products cannot be quoted' do
    other = Tenant.create!(name: 'Other POS store', subdomain: 'other-pos-store')
    foreign_product = ShopifyProduct.create!(id: 'other-pos-product', title: 'Private POS item', tenant_id: other.id)
    foreign = ShopifyVariant.create!(productId: foreign_product.id, title: 'Private', sku: 'PRIVATE-POS', price: 1, tenant_id: other.id)
    [foreign.id, 'unknown-variant'].each do |id|
      post_quote(id)
      assert_response :unprocessable_entity
      assert_not_includes response.body, 'Private POS item'
    end
    @product.update!(status: 'ARCHIVED')
    post_quote(@variant.id)
    assert_response :unprocessable_entity
    @product.update!(status: 'ACTIVE')
    @variant.update!(productId: 'missing-product')
    post_quote(@variant.id)
    assert_response :unprocessable_entity
  end

  test 'duplicate variant rows and ambiguous catalog SKUs cannot be quoted' do
    post quote_point_of_sale_path, params: { items: [
      { variant_id: @variant.id, quantity: 1 }, { variant_id: @variant.id, quantity: 2 }
    ] }, as: :json
    assert_response :unprocessable_entity
    ShopifyVariant.create!(productId: @product.id, title: 'Duplicate', sku: @variant.sku, price: 1)
    post_quote(@variant.id)
    assert_response :unprocessable_entity
    get point_of_sale_path
    assert_response :success
    assert_select 'p', /Conflicting SKU/
    assert_select 'input[name="items[0][variant_id]"][value=?]', @variant.id, count: 0
  end

  test 'strict positive whole quantities bounded cart and malformed rows are rejected' do
    [nil, '', '0', '-1', '1.5', '1000', '99999999999999999999999999999'].each do |quantity|
      post_quote(@variant.id, quantity: quantity)
      assert_response :unprocessable_entity
    end
    [[], 'bad', [{ quantity: '1' }], Array.new(51) { { variant_id: @variant.id, quantity: 1 } }].each do |items|
      post quote_point_of_sale_path, params: { items: items }, as: :json
      assert_response :unprocessable_entity
    end
    post_quote(@variant.id, quantity: '999')
    assert_response :success
  end

  test 'unsupported prices are unavailable and unsafe image URLs are excluded' do
    [nil, -1, 1000000, 1.234].each do |price|
      @variant.update!(price: price)
      post_quote(@variant.id)
      assert_response :unprocessable_entity
    end
    @variant.update!(price: 10)
    @product.update!(featuredImageUrl: 'javascript:alert(1)')
    post_quote(@variant.id)
    assert_response :success
    assert_nil response.parsed_body['lines'].first['thumbnail_url']
  end

  test 'catalog search stays tenant scoped and includes product titles' do
    other = Tenant.create!(name: 'Other catalog', subdomain: 'other-pos-catalog')
    foreign_product = ShopifyProduct.create!(id: 'private-pos-product', title: 'Image Private', tenant_id: other.id)
    ShopifyVariant.create!(productId: foreign_product.id, title: 'Secret', sku: 'SECRET-POS', price: 1, tenant_id: other.id)
    get point_of_sale_path, params: { q: 'image' }
    assert_response :success
    assert_select 'h2', 'Image Tea'
    assert_not_includes response.body, 'Image Private'
    get point_of_sale_path, params: { q: '%' }
    assert_response :success
    assert_select 'h2', text: 'Image Tea', count: 0
  end

  test 'catalog pages contain at most twenty-four stable variant tiles' do
    25.times do |number|
      ShopifyVariant.create!(productId: @product.id, title: "Page item #{number}",
        sku: format('POS-PAGE-%02d', number), price: 1)
    end
    get point_of_sale_path, params: { q: 'POS-PAGE' }
    assert_response :success
    assert_select 'form[data-action="submit->pos-cart#add"]', count: 24
    get point_of_sale_path, params: { q: 'POS-PAGE', page: 2 }
    assert_response :success
    assert_select 'form[data-action="submit->pos-cart#add"]', count: 1
    assert_select 'article p', /POS-PAGE-24/
  end

  test 'cashiers can preview while missing sales write or inventory read forbids access' do
    @user.update!(role: 'cashier')
    get point_of_sale_path
    assert_response :success
    %w[sales.write inventory.read].each do |missing|
      @user.update_permission_overrides!(%w[sales.read sales.write inventory.read] - [missing])
      get point_of_sale_path
      assert_redirected_to root_path
      post_quote(@variant.id)
      assert_response :forbidden
    end
  end

  test 'percentage tipping uses server subtotal and half-up rounding' do
    @variant.update!(price: 0.05)
    post quote_point_of_sale_path, params: {
      items: [{ variant_id: @variant.id, quantity: 1, unit_price: '100' }],
      tip_type: 'percentage', tip_percentage: '10', subtotal: '100', tip_amount: '10', preview_total: '110'
    }, as: :json
    assert_response :success
    assert_equal '0.05', response.parsed_body['subtotal']
    assert_equal '0.01', response.parsed_body['tip_amount']
    assert_equal '0.06', response.parsed_body['preview_total']
    assert_equal '10.0', response.parsed_body['tip_percentage']
    assert_equal false, response.parsed_body['payment_processed']
  end

  test 'custom tip rounds decimal amount and adds only to preview total' do
    post quote_point_of_sale_path, params: {
      items: [{ variant_id: @variant.id, quantity: 1 }], tip_type: 'custom', tip_amount: '1.005'
    }, as: :json
    assert_response :success
    assert_equal '1.01', response.parsed_body['tip_amount']
    assert_equal '13.36', response.parsed_body['preview_total']
    assert_nil response.parsed_body['tip_percentage']
    assert_equal false, response.parsed_body['sale_created']
  end

  test 'invalid or excessive tip values are rejected without sale or payment' do
    counts = [Core::Order.count, Core::Payment.count]
    ['-1', 'NaN', 'Infinity', '1e99', '999999999999999999999999999', '', '1000000'].each do |amount|
      post quote_point_of_sale_path, params: {
        items: [{ variant_id: @variant.id, quantity: 1 }], tip_type: 'custom', tip_amount: amount
      }, as: :json
      assert_response :unprocessable_entity
    end
    %w[-1 101 NaN Infinity 9999999999999999].each do |percentage|
      post quote_point_of_sale_path, params: {
        items: [{ variant_id: @variant.id, quantity: 1 }], tip_type: 'percentage', tip_percentage: percentage
      }, as: :json
      assert_response :unprocessable_entity
    end
    post quote_point_of_sale_path, params: {
      items: [{ variant_id: @variant.id, quantity: 1 }], tip_type: 'unrecognized'
    }, as: :json
    assert_response :unprocessable_entity
    @variant.update!(price: 999999.99)
    post quote_point_of_sale_path, params: {
      items: [{ variant_id: @variant.id, quantity: 2 }], tip_type: 'percentage', tip_percentage: '100'
    }, as: :json
    assert_response :unprocessable_entity
    assert_equal counts, [Core::Order.count, Core::Payment.count]
  end

  private

  def post_quote(variant_id, quantity: '1')
    post quote_point_of_sale_path, params: { items: [{ variant_id: variant_id, quantity: quantity }] }, as: :json
  end
end
