# frozen_string_literal: true

require 'test_helper'

class RetailWorkspaceTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'retail-ui/7', name: 'Retail UI fixture')
    CtraxStockSnapshot.create!(location: @location, api_origin: 'https://fixture.api.cannatrax.net', store_id: '7', captured_at: Time.current,
      records_json: [{ 'id' => '3', 'name' => 'Tea Tin', 'product_name' => 'Tea', 'price_cents' => 1000, 'quantity' => '-2', 'manage_stock' => true, 'listed' => true },
                    { 'id' => '4', 'name' => 'Coffee Tin', 'product_name' => 'Coffee', 'price_cents' => 2000, 'quantity' => nil, 'manage_stock' => true, 'listed' => true }])
    %w[Tea Coffee].each do |title|
      ShopifyProduct.create!(id: "retail-image-#{title.downcase}", title: title, status: 'ACTIVE', featuredImageUrl: "https://cdn.shopify.com/#{title.downcase}.jpg")
    end
    post login_path, params: { email: @user.email, password: 'password' }
    Current.tenant = @tenant
  end
  teardown { Current.reset }

  test 'POS exposes a reachable cart unique quantity fields and preserves source stock' do
    get ctrax_pos_path
    assert_response :success
    assert_select '.app-rail', count: 0
    assert_select 'a[href=?]', ctrax_days_path, count: 0
    assert_select 'a.pos-cart-jump[href="#retail-cart"]'
    assert_select '#retail-cart[tabindex="-1"]'
    assert_select 'button.pos-tile', count: 2
    assert_select 'input[type=number][id=pos_item_quantity][min="1"][max="999"][required]'
    assert_select '.pos-stock[title="Stock: -2"]', 'Out'
    assert_select '.pos-stock[title="Stock: Unknown"]', 'Unknown'
    assert_select '[data-pos-cart-target=count]', count: 2
    ids = Nokogiri::HTML(response.body).css('[id]').map { |node| node['id'] }
    assert_equal ids.uniq, ids
    assert_equal 'no-store', response.headers['Cache-Control']
    get ctrax_pos_path, params: { q: 'not-in-the-fixture' }
    assert_select '.empty-state-title', 'No products match these filters'
    assert_select 'a', 'Clear'
  end

  test 'stale stock is explained before an add action and admin setup stays role filtered' do
    CtraxStockSnapshot.find_by!(location: @location).update!(captured_at: 2.hours.ago)
    get ctrax_pos_path
    assert_select 'dialog#pos-item-dialog button.pos-add[type=submit][disabled]', 'Add to cart'
    assert_includes response.body, 'Stock read stale'
    @user.update_permission_overrides!(%w[dashboard.read sales.read sales.write inventory.read])
    get ctrax_pos_path
    assert_select 'a[href=?]', pos_connection_path('ctrax'), count: 0
    assert_select 'details', text: /Website image link/, count: 0
  end

  test 'daily close summarizes completed source orders without adding tender or tip money' do
    day = create_day
    get ctrax_days_path, params: { date: day.business_date }
    assert_response :success
    assert_select 'article[aria-label="Retail UI fixture daily close"]', text: /Recorded sales.*\$10.00.*1 completed order.*Recorded tips.*\$2.00/m
    get ctrax_day_path(day)
    assert_response :success
    assert_select '[aria-label="Daily sales summary"]', text: /Recorded sales.*\$10.00.*Tax included.*\$1.00.*Tips.*\$2.00.*Completed orders.*1/m
    assert_select '[role=region][tabindex="0"][aria-label="Daily source checks"] table caption'
    assert_select 'th[scope=row]', 'Card terminal tender'
    assert_not_includes response.body, 'standaloneCardTerminal tender'
    assert_select 'section#close-registers'
    assert_select 'form[action=?] input[name=source_digest]', review_ctrax_day_path(day)
    assert_select 'textarea.retail-notes'
    day.update!(currency: 'EUR', orders_json: day.orders.map { |order| order.merge('total' => nil) })
    get ctrax_day_path(day)
    assert_select '[aria-label="Daily sales summary"]', text: /Recorded sales.*Unknown.*Tax included.*EUR 1.00/m
  end

  test 'readers can inspect daily checks without review forms or register refresh actions' do
    day = create_day
    register = Sales::PosSession.create!(name: 'Read-only drawer', location: @location, opened_at: Time.current, opening_cash_cents: 5000)
    @user.update_permission_overrides!(%w[sales.read])
    get ctrax_day_path(day)
    assert_response :success
    assert_select '#close-review', count: 0
    get sales_pos_session_path(register)
    assert_response :success
    assert_select 'form[action=?]', refresh_sales_pos_session_path(register), count: 0
    assert_select 'form[action=?]', close_sales_pos_session_path(register), count: 0
  end

  test 'register form selects the native Rupert location and asks for a physical dollar count' do
    get new_sales_pos_session_path, params: { location_id: @location.id }
    assert_response :success
    assert_select 'select[name="pos_session[location_id]"] option[selected][value=?]', @location.id
    assert_difference 'Sales::PosSession.count', 1 do
      post sales_pos_sessions_path, params: { pos_session: { name: 'Opened from UI', location_id: @location.id, opening_cash: '50.00' } }
    end
    assert_equal @location, Sales::PosSession.last.location
    assert_equal 5000, Sales::PosSession.last.opening_cash_cents
    register = Sales::PosSession.create!(name: 'UI drawer', location: @location, opened_at: Time.current, opening_cash_cents: 5000)
    get sales_pos_session_path(register)
    assert_select 'input[name=counted_cash][required][step="0.01"]:not([value])'
    assert_select 'input[name=counted_cents]', count: 0
    post close_sales_pos_session_path(register), params: { counted_cash: '50.01' }
    assert_redirected_to sales_pos_session_path(register)
    assert register.reload.closed?
    assert_equal 5001, register.counted_cash_cents
    assert_equal 1, register.variance_cents
  end

  test 'blank malformed and fractional-cent counts never close a register' do
    register = Sales::PosSession.create!(name: 'Count guard', location: @location, opened_at: Time.current, opening_cash_cents: 5000)
    ['', '-1', '1e3', '50.001', 'NaN', 'word'].each do |value|
      post close_sales_pos_session_path(register), params: { counted_cash: value }
      assert_redirected_to sales_pos_session_path(register)
      assert register.reload.open?, value
      assert_nil register.counted_cash_cents
    end
    post close_sales_pos_session_path(register), params: { counted_cents: 'word' }
    assert register.reload.open?
    post close_sales_pos_session_path(register), params: { counted_cents: 5000 }
    assert register.reload.closed?
    assert_equal 5000, register.counted_cash_cents
  end

  private

  def create_day
    now = Time.current.in_time_zone('America/New_York').change(hour: 12)
    order = { 'id' => '41', 'receipt' => 'FIXTURE-41', 'status' => 'completed', 'deleted' => false,
      'completed_at' => now.iso8601, 'register_session_id' => '9', 'total' => 1000, 'tax' => 100, 'discount' => 0,
      'tip' => 200, 'refund_count' => 0, 'lines' => [{ 'id' => '31', 'name' => 'Tea', 'variant_name' => 'Tin', 'price' => 900 }],
      'payments' => [{ 'id' => '5', 'status' => 'completed', 'type' => 'cash', 'amount' => 1000, 'total_amount' => 1200, 'tip_amount' => 200, 'surcharge_amount' => 0, 'deleted' => false }] }
    CtraxDay.create!(location: @location, business_date: now.to_date, api_origin: 'https://fixture.api.cannatrax.net',
      store_id: '7', currency: 'USD', timezone: 'America/New_York', source_digest: 'retail-ui-fixture', captured_at: now,
      orders_json: [order, order.merge('id' => '42', 'status' => 'pending', 'total' => 9900), order.merge('id' => '43', 'deleted' => true, 'total' => 8800)],
      sessions_json: [], controls_json: {})
  end
end
