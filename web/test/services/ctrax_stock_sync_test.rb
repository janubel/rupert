# frozen_string_literal: true

require 'test_helper'

class CtraxStockSyncTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @origin = 'https://fixture-store.api.cannatrax.net'
    @credentials = { 'api_url' => @origin, 'api_username' => 'read-user', 'api_password' => 'private-password' }
    @connection = PosConnection.create!(provider: 'ctrax', vendor_approved: true,
      credentials_json: @credentials.to_json)
    stub_login
  end

  teardown { Current.reset }

  test 'stock sync retains native identity missing SKUs zero negative and unknown stock' do
    rows = [variant(1, sku: nil, quantity: -2), variant(2, sku: 'ZERO', quantity: 0),
            variant(3, sku: 'UNKNOWN', quantity: nil)]
    stub_stock(rows)
    assert_equal({ stores: 1, variants: 3 }, Ctrax::StockSync.call(connection: @connection))
    snapshot = CtraxStockSnapshot.first
    assert_equal 'ctrax', snapshot.location.source
    assert_equal 'fixture-store.api.cannatrax.net/7', snapshot.location.externalId
    assert_equal '-2', snapshot.records.first['quantity']
    assert_nil snapshot.records.first['sku']
    assert_nil snapshot.records.last['quantity']
    assert_equal '0', snapshot.records.second['quantity']
    assert_equal 'verified', @connection.reload.last_check_status
    assert_equal 1, PosConnection.count
    assert_not_includes snapshot.records_json.to_json, 'private-password'
    assert_requested :post, "#{@origin}/api/auth/login",
      body: { username: 'read-user', password: 'private-password' }.to_json
    assert_requested :get, "#{@origin}/api/v1/stores/7/productVariants?page=1&per_page=100",
      headers: { Authorization: 'Bearer fixture-token' }
    assert_not_requested :post, /paymentVendors|inventoryAdjustments/
  end

  test 'all pages are validated and replacement does not duplicate items' do
    stub_stock([variant(1)])
    Ctrax::StockSync.call(connection: @connection)
    first_id = CtraxStockSnapshot.first.id
    stub_request(:get, "#{@origin}/api/v1/stores/7/productVariants").with(query: { page: '1', per_page: '100' })
                                                                    .to_return(json_response(data: [variant(2)],
                                                                      current_page: 1, last_page: 2, total: 2))
    stub_request(:get, "#{@origin}/api/v1/stores/7/productVariants").with(query: { page: '2', per_page: '100' })
                                                                    .to_return(json_response(data: [variant(3)],
                                                                      current_page: 2, last_page: 2, total: 2))
    Ctrax::StockSync.call(connection: @connection.reload)
    assert_equal 1, CtraxStockSnapshot.count
    assert_equal first_id, CtraxStockSnapshot.first.id
    assert_equal %w[2 3], CtraxStockSnapshot.first.records.pluck('id')
    assert_equal 1, Location.where(source: 'ctrax').count
  end

  test 'failed later page leaves prior snapshot intact and records sanitized failure' do
    stub_stock([variant(1)])
    Ctrax::StockSync.call(connection: @connection)
    original = CtraxStockSnapshot.first.attributes
    stub_request(:get, "#{@origin}/api/v1/stores/7/productVariants").with(query: { page: '1', per_page: '100' })
                                                                    .to_return(json_response(data: [variant(2)],
                                                                      current_page: 1, last_page: 2, total: 2))
    stub_request(:get, "#{@origin}/api/v1/stores/7/productVariants").with(query: { page: '2', per_page: '100' })
                                                                    .to_return(status: 403, body: 'private upstream error')
    error = assert_raises(Ctrax::Client::Error) { Ctrax::StockSync.call(connection: @connection.reload) }
    assert_not_includes error.message, 'private upstream error'
    assert_equal original, CtraxStockSnapshot.first.attributes
    assert_equal 'failed', @connection.reload.last_check_status
    assert_not_includes @connection.last_check_message, 'private upstream error'
  end

  test 'duplicate IDs changed totals missing pagination and malformed stock do not publish' do
    documents = [
      { data: [variant(1), variant(1)], current_page: 1, last_page: 1, total: 2 },
      { data: [variant(1)], current_page: 1, last_page: 1, total: 2 },
      { data: [variant(1)], total: 1 },
      { data: [variant(1, quantity: 'unknown')], current_page: 1, last_page: 1, total: 1 }
    ]
    documents.each do |document|
      stub_request(:get,
        "#{@origin}/api/v1/stores/7/productVariants").with(query: { page: '1',
                                                                               per_page: '100' }).to_return(json_response(document))
      assert_raises(Ctrax::Client::Error) { Ctrax::StockSync.call(connection: @connection.reload) }
      assert_empty CtraxStockSnapshot.all
      assert_empty Location.where(source: 'ctrax')
    end
  end

  test 'origin validation rejects HTTP credentials paths redirects and hostname suffix tricks' do
    ['http://fixture-store.api.cannatrax.net', 'https://127.0.0.1', 'https://fixture-store.api.cannatrax.net.evil.test',
     'https://fixture-store.api.cannatrax.net/path', 'https://user:password@fixture-store.api.cannatrax.net',
     'https://fixture-store.api.cannatrax.net?token=secret'].each do |url|
      assert_raises(Ctrax::Client::Error) { Ctrax::Client.new(@credentials.merge('api_url' => url)) }
    end
    stub_request(:post, "#{@origin}/api/auth/login").to_return(status: 302, headers: { Location: 'https://evil.test' })
    assert_raises(Ctrax::Client::Error) { Ctrax::Client.new(@credentials).stores }
    assert_not_requested :any, /evil\.test/
  end

  test 'malformed authentication and oversized response are rejected without leaking secrets' do
    [{ token: "bad\ntoken", permissions: { accessible_stores: { '7' => 'Store' } } },
     { token: 'token', permissions: 'bad' }, { token: 'token', permissions: { accessible_stores: [] } }].each do |document|
      stub_request(:post, "#{@origin}/api/auth/login").to_return(json_response(document))
      assert_raises(Ctrax::Client::Error) { Ctrax::Client.new(@credentials).stores }
    end
    stub_request(:post, "#{@origin}/api/auth/login").to_return(status: 200,
      headers: { 'Content-Type' => 'application/json', 'Content-Length' => (Ctrax::Client::MAX_BYTES + 1).to_s }, body: '{}')
    assert_raises(Ctrax::Client::Error) { Ctrax::Client.new(@credentials).stores }
  end

  test 'credentials changed during fetch cannot publish into current configuration' do
    stub_request(:get,
      "#{@origin}/api/v1/stores/7/productVariants").with(query: { page: '1', per_page: '100' }).to_return do
      PosConnection.find(@connection.id).update!(credentials_json: '{}', hourly_sync_enabled: false)
      json_response(data: [variant(1)], current_page: 1, last_page: 1, total: 1)
    end
    assert_raises(Ctrax::Client::Error) { Ctrax::StockSync.call(connection: @connection) }
    assert_empty CtraxStockSnapshot.all
    assert_empty @connection.reload.credential_values
    assert_nil @connection.last_check_status
  end

  test 'store overrides and unsupported fractions retain source values honestly' do
    stub_request(:post, "#{@origin}/api/auth/login").to_return(json_response(token: 'fixture-token',
      permissions: { accessible_stores: { '7' => 'Fixture store' } }, feature_flags: [{ name: 'FLAG_MASTER_PRODUCT_LIST' }]))
    row = variant(1, quantity: '2.5')
    row[:attribute_store_overrides] = { sku: 'STORE-SKU', barcode: 'STORE-BARCODE', manage_stock: false }
    stub_stock([row])
    Ctrax::StockSync.call(connection: @connection)
    record = CtraxStockSnapshot.first.records.first
    assert_equal 'STORE-SKU', record['sku']
    assert_equal 'STORE-BARCODE', record['barcode']
    assert_equal '2.5', record['quantity']
    assert_equal false, record['manage_stock']
  end

  test 'store overrides are ignored when the native master product feature is disabled' do
    row = variant(1, sku: 'BASE-SKU', quantity: 4)
    row[:attribute_store_overrides] = { sku: 'DISABLED-SKU', manage_stock: false }
    stub_stock([row])
    Ctrax::StockSync.call(connection: @connection)
    assert_equal 'BASE-SKU', CtraxStockSnapshot.first.records.first['sku']
    assert_equal true, CtraxStockSnapshot.first.records.first['manage_stock']
  end

  test 'merchant read check summarizes account counts without persisting merchant credentials' do
    stub_request(:get, "#{@origin}/api/v1/stores/7/paymentVendors/trx/connectionStatus")
      .to_return(json_response(production: [{ password: 'merchant-secret', client_id: 'private-client' }], sandbox: []))
    result = PaymentProviders::CtraxCheck.call(credentials: @credentials)
    assert_equal 'verified', result[:status]
    assert_includes result[:message], '1 production'
    assert_not_includes result.to_json, 'merchant-secret'
    assert_not_includes result.to_json, 'private-client'
    assert_empty CtraxStockSnapshot.all
  end

  test 'tenant mismatch cannot read or publish with another workspace connection' do
    other = Tenant.create!(name: 'Other store', subdomain: 'ctrax-other')
    Current.tenant = other
    assert_raises(Ctrax::Client::Error) { Ctrax::StockSync.call(connection: @connection) }
    assert_empty CtraxStockSnapshot.unscoped.all
    assert_not_requested :get, /productVariants/
  end

  private

  def stub_login
    stub_request(:post, "#{@origin}/api/auth/login")
      .to_return(json_response(token: 'fixture-token', permissions: { accessible_stores: { '7' => 'Fixture store' } }))
  end

  def stub_stock(rows)
    stub_request(:get, "#{@origin}/api/v1/stores/7/productVariants").with(query: { page: '1', per_page: '100' })
                                                                    .to_return(json_response(data: rows,
                                                                      current_page: 1, last_page: 1, total: rows.size))
  end

  def variant(id, sku: 'FIXTURE', quantity: 4)
    { id: id, sku: sku, barcode: "code-#{id}", full_name: "Fixture #{id}", manage_stock: true,
      store_stock: { quantity: quantity } }
  end

  def json_response(document)
    { status: 200, headers: { 'Content-Type' => 'application/json' }, body: document.to_json }
  end
end
