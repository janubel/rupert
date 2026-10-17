# frozen_string_literal: true

require 'test_helper'

class CtraxPosTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'fixture/7', name: 'Retail fixture')
    @product = ShopifyProduct.create!(id: 'website-tea', title: 'Tea', status: 'ACTIVE', featuredImageUrl: 'https://cdn.shopify.com/tea.jpg')
    @snapshot = CtraxStockSnapshot.create!(location: @location, api_origin: 'https://fixture.api.cannatrax.net', store_id: '7', captured_at: Time.current,
      records_json: [{ 'id' => '3', 'name' => 'Tea Tin', 'product_name' => 'Tea', 'price_cents' => 1235, 'quantity' => '-2', 'manage_stock' => true, 'listed' => true }])
    post login_path, params: { email: @user.email, password: 'password' }
  end
  teardown { Current.reset }

  test 'cashier catalog uses native stock and website images with no cashier tip selector' do
    get ctrax_pos_path
    assert_response :success
    assert_select 'img[src*="cdn.shopify.com/tea.jpg"]'
    assert_select 'button', 'Demo both screens'
    assert_select 'select[name=tip_type]', count: 0
    assert_includes response.body, 'Stock: -2'
    assert_equal 'no-store', response.headers['Cache-Control']
    post pos_displays_path, params: { location_id: @location.id, demo: '1' }
    display = PosDisplaySession.last
    assert_redirected_to demo_pos_display_path(display)
    get demo_pos_display_path(display)
    assert_select 'iframe', count: 2
    assert_select 'iframe[title="Customer tipping demo"]'
    get ctrax_pos_path(location_id: @location.id, display_id: display.id)
    assert_response :success
    assert_select 'h1', 'Cashier cart'
    assert_select 'nav', count: 0
  end

  test 'only pictured products appear in categories search and pagination' do
    unseen = 25.times.map { |i| { 'id' => "hidden-#{i}", 'name' => "No image #{i}", 'product_name' => "Unpictured #{i}", 'category' => 'Hidden category', 'listed' => true, 'price_cents' => 100 } }
    @snapshot.update!(records_json: unseen + @snapshot.records)
    get ctrax_pos_path
    assert_response :success
    assert_select 'article.retail-product-card', count: 1
    assert_select 'article.retail-product-card img', count: 1
    assert_select 'select[name=category] option', text: 'Hidden category', count: 0
    assert_select 'p', /1 results/
    get ctrax_pos_path, params: { q: 'No image' }
    assert_select 'article.retail-product-card', count: 0
    get ctrax_pos_path, params: { page: 2 }
    assert_select 'article.retail-product-card', count: 0
    @product.update!(featuredImageUrl: nil)
    get ctrax_pos_path
    assert_select 'article.retail-product-card', count: 0
    @product.update!(featuredImageUrl: 'https://cdn.shopify.com/tea.jpg')
    get ctrax_pos_path
    assert_select 'article.retail-product-card', count: 1
    assert_select 'nav a[href=?]', point_of_sale_path, count: 0
    assert_select 'select#missing_image_variant option[value="hidden-0"]'
    post ctrax_pos_images_path(@location.id), params: { variant_id: 'hidden-0', product_id: @product.id }
    assert_redirected_to ctrax_pos_path(location_id: @location.id)
    follow_redirect!
    assert_select 'article.retail-product-card', count: 2
    assert_equal 26, @snapshot.reload.records.size
    assert_equal 'No image 0', @snapshot.records.find { |r| r['id'] == 'hidden-0' }['name']
  end

  test 'server prices cart and keeps choice private until customer confirmation' do
    display = PosDisplaySession.create!(user: @user, location: @location)
    quote(display, quantity: 2)
    assert_response :success
    assert_equal '24.7', response.parsed_body['subtotal']
    assert_equal '0.0', response.parsed_body['tip_amount']
    display.reload
    get customer_display_path(display_token: display.display_token)
    assert_response :success
    assert_select 'input[name=choice][checked]', count: 0
    get pos_display_path(display)
    assert_nil response.parsed_body['tip_cents']
    post customer_display_tip_path, params: { display_token: display.display_token, cart_revision: display.cart_revision, choice: '15' }, as: :json
    assert_response :success
    assert_equal 371, response.parsed_body['tip_cents']
    get pos_display_path(display)
    assert_equal 371, response.parsed_body['tip_cents']
    quote(display, quantity: 3)
    assert_response :success
    get pos_display_path(display)
    assert_nil response.parsed_body['tip_cents']
    post customer_display_tip_path, params: { display_token: display.display_token, cart_revision: display.cart_revision, choice: '20' }, as: :json
    assert_response :conflict
  end

  test 'no tip is explicit clear invalidates confirmation and customer display does not require cashier login' do
    display = PosDisplaySession.create!(user: @user, location: @location)
    quote(display)
    display.reload
    customer = ActionDispatch::Integration::Session.new(Rails.application)
    customer.get customer_display_state_path(display_token: display.display_token)
    assert_equal 200, customer.response.status
    customer.post customer_display_tip_path, params: { display_token: display.display_token, cart_revision: display.cart_revision, choice: 'none' }, as: :json
    assert_equal 200, customer.response.status
    assert_equal 0, customer.response.parsed_body['tip_cents']
    post clear_pos_display_path(display)
    assert_response :no_content
    assert_not display.reload.confirmed?
    assert_empty display.draft['lines']
    assert_equal 0, Core::Payment.count
  end

  test 'expired revoked and another cashier sessions cannot disclose or change display data' do
    display = PosDisplaySession.create!(user: @user, location: @location)
    quote(display)
    display.reload.update!(expires_at: 1.minute.ago)
    get customer_display_state_path(display_token: display.display_token)
    assert_response :gone
    display.update!(expires_at: 10.minutes.from_now)
    @user.update_permission_overrides!(%w[sales.read inventory.read])
    get customer_display_state_path(display_token: display.display_token)
    assert_response :gone
    @user.update_permission_overrides!(%w[sales.read sales.write inventory.read])
    other = User.create!(tenant: @user.tenant, email: 'other-cashier@example.test', password: 'password', role: 'cashier')
    foreign = PosDisplaySession.create!(user: other, location: @location)
    get pos_display_path(foreign)
    assert_response :not_found
    post clear_pos_display_path(foreign)
    assert_response :not_found
  end

  test 'stale source price cross-store variants malformed tips and duplicate variants are rejected' do
    display = PosDisplaySession.create!(user: @user, location: @location)
    quote(display)
    display.reload
    ['-1', '1e9', 'NaN', '1.001', '1000000'].each do |amount|
      post customer_display_tip_path, params: { display_token: display.display_token, cart_revision: display.cart_revision, choice: 'custom', amount: amount }, as: :json
      assert_response :unprocessable_entity
    end
    post customer_display_tip_path, params: { display_token: display.display_token, cart_revision: '1x', choice: 'none' }, as: :json
    assert_response :unprocessable_entity
    @snapshot.update!(captured_at: 2.hours.ago)
    quote(display)
    assert_response :unprocessable_entity
    @snapshot.update!(captured_at: Time.current)
    post quote_ctrax_pos_path(@location.id), params: { items: [{ variant_id: '999', quantity: 1 }] }, as: :json
    assert_response :unprocessable_entity
    post quote_ctrax_pos_path(@location.id), params: { items: [{ variant_id: '3', quantity: 1 }, { variant_id: '3', quantity: 2 }] }, as: :json
    assert_response :unprocessable_entity
  end

  private

  def quote(display, quantity: 1)
    post quote_ctrax_pos_path(@location.id, display_id: display.id), params: { items: [{ variant_id: '3', quantity: quantity, unit_price: '0.01' }], tip_type: 'custom', tip_amount: '500' }, as: :json
  end
end
