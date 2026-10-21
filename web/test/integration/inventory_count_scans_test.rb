# frozen_string_literal: true

require 'test_helper'

class InventoryCountScansTest < ActionDispatch::IntegrationTest
  setup do
    ShopifyAPI::Context.setup(
      api_key: 'test-key', api_secret_key: 'test-secret',
      api_version: ShopifyAPI::AdminVersions::SUPPORTED_ADMIN_VERSIONS.first,
      host_name: 'localhost', scope: 'read_products', is_private: false, is_embedded: false
    )
    Shop.create!(shopify_domain: 'm11u0i-sb.myshopify.com', shopify_token: 'test-token')
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    EnvStore.set('SHOPIFY_CLIENT_ID', 'test-client-id')
    EnvStore.set('SHOPIFY_CLIENT_SECRET', 'test-client-secret')
    post login_path, params: { email: 'admin@example.com', password: 'password' }
    @product = ShopifyProduct.create!(id: 'scanner-product', title: 'Scanner Widget')
    @variant = ShopifyVariant.create!(productId: @product.id, title: 'Small', sku: 'SCAN-1', barcode: '0012345000')
    @location = Location.create!(source: 'shopify', externalId: 'scan-main', name: 'Main')
    @level = InventoryLevel.create!(source: 'shopify', locationId: @location.id, shopifyVariantId: @variant.id, quantity: 10)
    @count = InventoryCount.create!(countedAt: Time.current, createdBy: 'admin@example.com')
  end

  teardown do
    Current.tenant = nil
    EnvStore.set('SHOPIFY_CLIENT_ID', nil)
    EnvStore.set('SHOPIFY_CLIENT_SECRET', nil)
  end

  test 'scanner renders set-total default and a unique request token' do
    get scan_inventory_count_path(@count)
    assert_response :success
    assert_select 'h1', 'Scan count'
    assert_select 'input[name=request_token][value]', count: 1
    assert_select 'form[data-busy=false][data-turbo=false]'
    assert_select 'select[name=mode] option:first-child[value=set]'
    assert_select 'p', /Prepared sheets start with system quantities/
  end

  test 'start scan count creates an empty worksheet and opens scanner' do
    get new_inventory_count_path(prepared: 0, start_scanning: 1)
    assert_response :success
    assert_select 'input[name=start_scanning][value="1"]'
    assert_select 'input[type=submit][value="Start scanning"]'
    post inventory_counts_path, params: {
      start_scanning: '1', inventory_count: { countedAt: Time.current.strftime('%Y-%m-%dT%H:%M') },
      items: [{ sku: '', quantity: '' }]
    }
    created = InventoryCount.where.not(id: @count.id).first
    assert_redirected_to scan_inventory_count_path(created)
    assert_empty created.items
  end

  test 'exact stored barcode lookup preserves leading zeroes' do
    get lookup_inventory_count_path(@count), params: { code: '0012345000' }, as: :json
    assert_response :success
    assert_equal 'SCAN-1', response.parsed_body['sku']
    assert_equal @variant.id, response.parsed_body['shopifyVariantId']
    assert_match(/Scanner Widget/, response.parsed_body['title'])
    assert_empty @count.items
  end

  test 'intentional repeated scans accumulate locally and retain actor audit' do
    record_scan(code: '0012345000', quantity: '1')
    assert_response :success
    record_scan(code: 'SCAN-1', quantity: '2')
    assert_response :success
    assert_equal 3, @count.items.find_by!(sku: 'SCAN-1').quantity
    assert_equal 3, response.parsed_body['total_quantity']
    assert_equal 2, @count.scan_receipts.count
    assert_equal ['admin@example.com'], @count.scan_receipts.distinct.pluck(:created_by)
    assert_equal 10, @level.reload.quantity
    refute InventoryMovement.exists?(sku: 'SCAN-1')
  end

  test 'same request replay does not add twice and token cannot change payload' do
    token = SecureRandom.uuid
    record_scan(request_token: token)
    original = response.parsed_body
    record_scan(request_token: token)
    assert_response :success
    assert_equal original, response.parsed_body
    assert_equal 1, @count.items.first.quantity
    assert_equal 1, @count.scan_receipts.count
    record_scan(request_token: token, quantity: '2')
    assert_response :conflict
    assert_equal 1, @count.items.first.quantity
    assert_equal 1, @count.scan_receipts.count
  end

  test 'set total replaces a prepared quantity including zero' do
    @count.items.create!(sku: 'SCAN-1', quantity: 10)
    record_scan(mode: 'set', quantity: '0')
    assert_response :success
    assert_equal 0, @count.items.first.quantity
    assert_equal 10, @level.reload.quantity
  end

  test 'invalid quantities and missing token do not save' do
    %w[wrong -1 1.5 2147483648].each do |quantity|
      record_scan(quantity: quantity)
      assert_response :unprocessable_entity
    end
    record_scan(quantity: '0')
    assert_response :unprocessable_entity
    record_scan(request_token: '')
    assert_response :unprocessable_entity
    assert_empty @count.items
    assert_empty @count.scan_receipts
  end

  test 'unknown code and ambiguous barcode are rejected' do
    record_scan(code: 'UNKNOWN')
    assert_response :not_found
    ShopifyVariant.create!(productId: @product.id, title: 'Large', sku: 'SCAN-2', barcode: @variant.barcode)
    record_scan(code: @variant.barcode)
    assert_response :conflict
    assert_empty @count.items
  end

  test 'duplicate variant SKU and blank-SKU barcode collision are rejected' do
    ShopifyVariant.create!(productId: @product.id, title: 'Duplicate', sku: 'SCAN-1')
    record_scan
    assert_response :conflict
    ShopifyVariant.create!(productId: @product.id, title: 'Missing SKU', sku: '', barcode: 'SQUARE-SKU')
    square_item = SquareItem.create!(id: 'scanner-square-item', name: 'Other item')
    SquareVariation.create!(itemId: square_item.id, name: 'Other variation', sku: 'SQUARE-SKU')
    record_scan(code: 'SQUARE-SKU')
    assert_response :conflict
    assert_empty @count.items
  end

  test 'duplicate worksheet rows must be combined before scanning' do
    2.times { @count.items.create!(sku: 'SCAN-1', quantity: 1) }
    record_scan
    assert_response :conflict
    assert_equal [1, 1], @count.items.pluck(:quantity)
  end

  test 'submitted count is immutable but completed token remains safely replayable' do
    token = SecureRandom.uuid
    record_scan(request_token: token)
    post submit_inventory_count_path(@count)
    assert @count.reload.pending?
    record_scan
    assert_response :conflict
    record_scan(request_token: token)
    assert_response :success
    assert_equal 1, @count.items.first.quantity
    get edit_inventory_count_path(@count)
    assert_redirected_to inventory_count_path(@count)
    patch inventory_count_path(@count), params: {
      inventory_count: { note: 'changed' }, items: [{ sku: 'SCAN-1', quantity: '99' }]
    }
    assert_redirected_to inventory_count_path(@count)
    delete inventory_count_path(@count)
    assert_redirected_to inventory_count_path(@count)
    assert_equal 1, @count.reload.items.first.quantity
    assert_nil @count.note
  end

  test 'foreign tenant count and codes cannot be accessed' do
    other = Tenant.create!(name: 'Other scanner tenant', subdomain: 'other-scanner-tenant')
    foreign_count = InventoryCount.create!(tenant_id: other.id, countedAt: Time.current)
    foreign_product = ShopifyProduct.create!(id: 'private-scanner-product', tenant_id: other.id, title: 'Private')
    ShopifyVariant.create!(tenant_id: other.id, productId: foreign_product.id, title: 'Private', sku: 'PRIVATE', barcode: '999999')
    get scan_inventory_count_path(foreign_count)
    assert_response :not_found
    record_scan(code: '999999')
    assert_response :not_found
    record_scan(code: 'PRIVATE')
    assert_response :not_found
  end

  test 'readers cannot scan and users without inventory read cannot view worksheets' do
    reader = User.create!(email: 'scanner-reader@example.com', password: 'password123', role: 'reader', tenant: @tenant)
    delete logout_path
    post login_path, params: { email: reader.email, password: 'password123' }
    record_scan
    assert_response :forbidden
    reader.update_permission_overrides!(['dashboard.read'])
    get inventory_counts_path
    assert_redirected_to root_path
    get inventory_count_path(@count)
    assert_redirected_to root_path
    assert_empty @count.items
  end

  test 'invalid edit preserves all old rows and accepts prepared indexed params' do
    original = @count.items.create!(sku: 'SCAN-1', quantity: 7)
    patch inventory_count_path(@count), params: {
      inventory_count: { countedAt: '' }, items: [{ sku: 'REPLACEMENT', quantity: '3' }]
    }
    assert_response :unprocessable_entity
    assert_equal [[original.id, 'SCAN-1', 7]], @count.reload.items.pluck(:id, :sku, :quantity)
    patch inventory_count_path(@count), params: {
      inventory_count: { note: 'invalid quantity' }, items: [{ sku: 'SCAN-1', quantity: 'not a number' }]
    }
    assert_response :unprocessable_entity
    assert_equal [[original.id, 'SCAN-1', 7]], @count.reload.items.pluck(:id, :sku, :quantity)
    patch inventory_count_path(@count), params: {
      inventory_count: { note: 'oversized quantity' }, items: [{ sku: 'SCAN-1', quantity: '999999999999999999999999999999999999' }]
    }
    assert_response :unprocessable_entity
    assert_equal [[original.id, 'SCAN-1', 7]], @count.reload.items.pluck(:id, :sku, :quantity)
    post inventory_counts_path, params: {
      inventory_count: { countedAt: Time.current.strftime('%Y-%m-%dT%H:%M') },
      items: { '0' => { sku: 'SCAN-1', quantity: '0' }, '1' => { sku: 'SECOND', quantity: '5' } }
    }
    created = InventoryCount.where.not(id: @count.id).first
    assert_redirected_to inventory_count_path(created)
    assert_equal [['SCAN-1', 0], ['SECOND', 5]], created.items.order(:sku).pluck(:sku, :quantity)
  end

  test 'foreign tenant location cannot be selected on a worksheet' do
    other = Tenant.create!(name: 'Location tenant', subdomain: 'location-tenant')
    foreign_location = Location.create!(tenant_id: other.id, source: 'shopify', externalId: 'private-location', name: 'Private')
    post inventory_counts_path, params: {
      inventory_count: { countedAt: Time.current.strftime('%Y-%m-%dT%H:%M'), locationId: foreign_location.id }
    }
    assert_response :unprocessable_entity
    assert_equal 1, InventoryCount.count
  end

  test 'sqlite busy response permits a safe retry with the same token' do
    database_error = begin
      raise ActiveRecord::StatementInvalid.new('busy'), cause: SQLite3::BusyException.new('database is locked')
    rescue ActiveRecord::StatementInvalid => e
      e
    end
    service = InventoryCountScan.new
    InventoryCountScan.stubs(:new).returns(service)
    service.stubs(:record!).raises(database_error)
    record_scan
    assert_response :service_unavailable
    assert_equal '1', response.headers['Retry-After']
    assert_match(/same scan/, response.parsed_body['error'])
    assert_empty @count.items
  end

  test 'selected Shopify scan binds native identity and snapshot on hand without changing source stock' do
    EnvStore.set('SHOPIFY_SHOP_DOMAIN', 'scan-count.myshopify.com')
    at = Time.current.change(usec: 0)
    @product.update!(status: 'ACTIVE', catalog_present: true, catalog_read_at: at)
    @variant.update!(tracked: true, catalog_present: true, catalog_read_at: at, inventoryItemId: 'scan-native-item')
    @count.update!(locationId: @location.id)
    snapshot = ShopifyStockSnapshot.create!(location: @location, shop_domain: ShopifyClient.shop_domain, captured_at: at,
      records_json: [{ 'id' => @variant.id, 'inventory_item_id' => @variant.inventoryItemId, 'on_hand' => 13, 'available' => 10 }])
    token = SecureRandom.uuid
    record_scan(request_token: token, mode: 'set', quantity: '9')
    assert_response :success
    item = @count.items.first
    assert_equal 13, item.previousQuantity
    assert_equal @variant.id, item.comparison['source_item_id']
    assert_equal 'native_on_hand', item.comparison['quantity_basis']
    assert_equal snapshot.id, item.comparison['stock_snapshot_id']
    original = response.parsed_body
    record_scan(request_token: token, mode: 'set', quantity: '9')
    assert_equal original, response.parsed_body
    assert_equal 1, @count.scan_receipts.count
    assert_equal 10, @level.reload.quantity
    assert_equal 13, snapshot.reload.records.first['on_hand']
    SkuLink.create!(sku: 'SCAN-ALIAS', shopifyVariantId: @variant.id)
    record_scan(code: 'SCAN-ALIAS', mode: 'set', quantity: '2')
    assert_response :success
    alias_item = @count.items.find_by!(sku: 'SCAN-ALIAS')
    assert_nil alias_item.previousQuantity
    assert_nil alias_item.delta
    assert_match(/same platform stock pool/, alias_item.comparison['reason'])
  end

  private

  def record_scan(**overrides)
    post record_scan_inventory_count_path(@count), params: {
      code: 'SCAN-1', quantity: '1', mode: 'increment', request_token: SecureRandom.uuid
    }.merge(overrides), as: :json
  end
end
