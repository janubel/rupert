# frozen_string_literal: true

require 'test_helper'

class CtraxSalesSyncTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @origin = 'https://fixture.api.cannatrax.net'
    @connection = PosConnection.create!(provider: 'ctrax', vendor_approved: true,
      credentials_json: { api_url: @origin, api_username: 'reader', api_password: 'fixture-secret' }.to_json)
    stub_request(:post, "#{@origin}/api/auth/login").to_return(response(token: 'fixture-token', permissions: { accessible_stores: { '7' => 'Fixture' } }))
    stub_request(:get, "#{@origin}/api/v1/stores/7").to_return(response(timezone_identifier: 'America/New_York'))
    @order = { id: 41, store_id: 7, register_session_id: 9, status: 'completed', completed_at: '2026-10-15T15:00:00Z', updated_at: '2026-10-15T15:00:00Z',
      total: 1000, subtotal: 900, tax: 100, discount: 0, tip: 0, refunds: [], customer: { email: 'private@example.test' },
      payments: [{ id: 5, order_id: 41, status: 'completed', type: 'cash', amount: 1000, total_amount: 1000, tip_amount: 0, surcharge_amount: 0, tendered_amount: 2000, change_back_amount: 1000, cardholder_name: 'PRIVATE-NAME' }],
      line_items: [{ id: 31, product_variant_id: 3, product_name: 'Tea', product_variant_name: 'Tin', price: 900, tax_amount: 100 }] }
    @controls = Ctrax::SalesSync::CONTROL_FIELDS.to_h { |key| [key, 0] }.merge('order_count' => 1, 'orders_totals_sum' => 1000, 'orders_subtotals_sum' => 900, 'orders_taxes_sum' => 100, 'cash_payments_amount_sum' => 1000)
    @session = { id: 9, register_id: 2, register_name: 'Front', opened_at: '2026-10-15T12:00:00Z', closed_at: '2026-10-15T23:00:00Z', opening_cash: 5000, closing_cash: 5900 }
    stub_sources
  end
  teardown { Current.reset }

  test 'native sale and register import uses store timezone integer cents and excludes private fields' do
    assert_equal({ stores: 1, orders: 1, date: '2026-10-15' }, sync)
    day = CtraxDay.first
    assert_equal 'America/New_York', day.timezone
    assert_equal 1000, day.orders.first['total']
    raw = CtraxDay.connection.select_value("SELECT orders_json FROM ctrax_days WHERE id = #{day.id}")
    assert_not_includes raw, 'Tea'
    assert_not_includes raw, 'completed_at'
    assert_not_includes day.orders_json.to_json, 'PRIVATE-NAME'
    assert_not_includes day.orders_json.to_json, 'private@example'
    result = Ctrax::Reconciliation.new(day)
    assert result.matched?
    assert_equal 0, result.session_rows.first['variance']
    assert_requested :get, "#{@origin}/api/v1/stores/7/orders", headers: { 'X-Store-Timezone' => 'America/New_York' },
      query: { page: '1', per_page: '50', include_extended_details: '1', override_timezone: 'store', completed_between: '2026-10-15 00:00:00->2026-10-16 00:00:00' }
    assert_not_requested :post, /orders|payments|registerSessions/
  end

  test 'idempotent imports preserve review but changed source facts invalidate it' do
    sync
    day = CtraxDay.first
    day.update!(reviewed_at: Time.current, reviewed_digest: day.source_digest, reviewed_by: users(:regular_user))
    sync
    assert_equal 1, CtraxDay.count
    assert day.reload.reviewed?
    @order[:total] = 1100
    stub_sources
    sync
    assert_not day.reload.reviewed?
    assert_not Ctrax::Reconciliation.new(day).matched?
  end

  test 'failed page and changed credential configuration retain previous complete day' do
    sync
    original = CtraxDay.first.attributes
    stub_request(:get, "#{@origin}/api/v2/analytics/reports/sales.general.summary").with(query: hash_including(format: 'raw_json')).to_return(status: 500, body: 'private-source-error')
    error = assert_raises(Ctrax::Client::Error) { sync }
    assert_not_includes error.message, 'private-source-error'
    assert_equal original, CtraxDay.first.attributes
    stub_sources
    stub_request(:get, "#{@origin}/api/v1/stores/7/orders").with(query: hash_including(page: '1')).to_return do
      @connection.reload.update!(credentials_json: '{}')
      response(data: [@order], total: 1, current_page: 1, last_page: 1)
    end
    assert_raises(Ctrax::Client::Error) { Ctrax::SalesSync.call(connection: @connection, date: '2026-10-15') }
    assert_equal original, CtraxDay.first.attributes
  end

  test 'half-open store day excludes following midnight and repeated IDs reject the entire snapshot' do
    other = @order.deep_dup.merge(id: 42, completed_at: '2026-10-16T04:00:00Z')
    stub_sources(orders: [@order, other])
    sync
    assert_equal ['41'], CtraxDay.first.orders.pluck('id')
    stub_sources(orders: [@order, @order])
    assert_raises(Ctrax::Client::Error) { sync }
    assert_equal ['41'], CtraxDay.first.orders.pluck('id')
  end

  test 'unknown source amounts refunds and cross-day sessions never yield a false cash variance' do
    @order[:payments].first[:amount] = nil
    @controls['refund_count'] = 1
    @session[:opened_at] = '2026-10-14T12:00:00Z'
    stub_sources
    sync
    result = Ctrax::Reconciliation.new(CtraxDay.first)
    assert_not result.matched?
    assert_nil result.session_rows.first['variance']
    assert_includes result.warnings.join(' '), 'refunds'
    assert_nil result.checks.find { |row| row[:label] == 'cash tender' }[:delta]
  end

  test 'store-local fall DST day includes the twenty-fifth hour' do
    @order[:completed_at] = '2026-11-02T04:30:00Z'
    stub_sources
    Ctrax::SalesSync.call(connection: @connection.reload, date: '2026-11-01')
    assert_equal ['41'], CtraxDay.first.orders.pluck('id')
  end

  test 'foreign tenant connection cannot issue business reads' do
    Current.tenant = Tenant.create!(name: 'Other', subdomain: 'ctrax-sales-other')
    assert_raises(Ctrax::Client::Error) { sync }
    assert_empty CtraxDay.unscoped.all
    assert_not_requested :get, /orders/
  end

  private

  def sync = Ctrax::SalesSync.call(connection: @connection.reload, date: '2026-10-15')
  def response(body) = { status: 200, headers: { 'Content-Type' => 'application/json' }, body: body.to_json }

  def stub_sources(orders: [@order])
    stub_request(:get, "#{@origin}/api/v1/stores/7/orders").with(query: hash_including(page: '1')).to_return(response(data: orders, current_page: 1, last_page: 1, total: orders.size))
    stub_request(:get, "#{@origin}/api/v1/registerSessions").with(query: hash_including(store_id: '7')).to_return(response(data: [@session], current_page: 1, last_page: 1, total: 1))
    stub_request(:get, "#{@origin}/api/v1/registerSessions/9/cashDrops").with(query: hash_including(page: '1')).to_return(response(data: [{ id: 1, amount: 100, created_at: '2026-10-15T20:00:00Z' }], current_page: 1, last_page: 1, total: 1))
    stub_request(:get, "#{@origin}/api/v2/analytics/reports/sales.general.summary").with(query: hash_including(format: 'raw_json')).to_return(response(rows: [@controls]))
  end
end
