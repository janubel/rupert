# frozen_string_literal: true

require 'test_helper'

class InventoryExceptionsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @at = Time.current.change(usec: 0)
    @product = ShopifyProduct.create!(id: 'exception-product', title: 'Exception test product', status: 'ACTIVE')
    @variant = variant('EXCEPTION-ONE')
    @shopify = location('shopify', 'Shopify exception warehouse')
    @square = location('square', 'Square exception register')
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  test 'healthy independent platform pools are never cross-channel drift' do
    shopify_level = level(@shopify, @variant, quantity: 20, available: 15)
    square = square_variation('EXCEPTION-ONE')
    level(@square, square, quantity: 2, available: 1)
    SkuLink.create!(sku: @variant.sku, shopifyVariantId: @variant.id, squareVariationId: square.id)
    queue = InventoryExceptions.new(at: @at)
    assert_empty queue.rows
    assert_equal 0, queue.summary[:shown]
    refute queue.summary[:limited]
    assert_equal 1, queue.total_pages
    get inventory_exceptions_path
    assert_response :success
    assert_select 'h1', 'Stock review'
    assert_includes response.body, 'different quantities between channels are normal'
    assert_includes response.body, 'does not confirm physical stock'
    assert_equal 20, shopify_level.reload.quantity
  end

  test 'native stock exceptions include Square-only negative unknown malformed and stale pools' do
    square = square_variation('SQUARE-ONLY')
    negative = level(@square, square, quantity: -3, available: nil)
    stale = level(@shopify, @variant, quantity: 5, available: 5, updatedAt: @at - 2.hours)
    wrong_source = level(@square, variant('WRONG-LOCATION'), quantity: 1, available: 1, source: 'shopify')
    missing = InventoryLevel.create!(source: 'square', locationId: @square.id, quantity: 4, available: 4, updatedAt: @at)
    rows = InventoryExceptions.new(at: @at, stale_hours: 1).sections.find { |group| group[:key] == :stock }[:rows]
    assert rows.any? { |row| row[:kind] == 'Negative mirrored stock' && row[:item_id] == square.id }
    unknown = rows.find { |row| row[:kind] == 'Unknown mirrored stock' }
    assert_nil unknown[:available]
    assert_equal(-3, unknown[:quantity])
    assert rows.any? { |row| row[:kind] == 'Stale stock snapshot' && row[:item_id] == stale.shopifyVariantId }
    assert rows.any? { |row| row[:kind] == 'Invalid pool identity' && row[:item_id] == wrong_source.shopifyVariantId }
    assert rows.any? { |row| row[:kind] == 'Invalid pool identity' && row[:item_id].nil? && row[:location_id] == missing.locationId }
    get inventory_exceptions_path, params: { source: 'square', location_id: @square.id, section: 'stock' }
    assert_response :success
    assert_includes response.body, 'SQUARE-ONLY'
    assert_includes response.body, 'Unknown'
    refute_includes response.body, 'WRONG-LOCATION'
    assert_nil negative.reload.available
  end

  test 'active holds exceeding min available and on hand keep exact source and location isolation' do
    stock = level(@shopify, @variant, quantity: 12, available: 8)
    active = reserve(stock, 5, 'Active pickup')
    expired = reserve(stock, 2, 'Expired pickup', expires_at: @at + 1.hour)
    released = reserve(stock, 1, 'Released pickup')
    StockReservation.where(id: expired.id).update_all(expires_at: @at - 1.second)
    StockReservationService.release(released, actor: 'operator@example.com')
    other_location = location('shopify', 'Other healthy warehouse')
    level(other_location, @variant, quantity: 100, available: 100)
    square = square_variation(@variant.sku)
    level(@square, square, quantity: 100, available: 100)
    stock.update!(quantity: 4, available: 3)
    queue = InventoryExceptions.new(at: @at)
    rows = queue.sections.find { |group| group[:key] == :holds }[:rows]
    assert_equal 1, rows.length
    assert_equal @shopify.id, rows.first[:location_id]
    assert_equal 'shopify', rows.first[:source]
    assert_equal @variant.id, rows.first[:item_id]
    assert_equal 5, rows.first[:held]
    assert_equal 2, rows.first[:shortage]
    assert_equal 'Local holds exceed capacity', rows.first[:kind]
    assert_equal 'active', active.reload.status
    assert_empty InventoryExceptions.new(at: @at, source: 'square').sections.find { |group| group[:key] == :holds }[:rows]
    assert_empty InventoryExceptions.new(at: @at, location_id: other_location.id).sections.find { |group| group[:key] == :holds }[:rows]
  end

  test 'missing and unknown held mirrors never invent a shortage quantity' do
    stock = level(@shopify, @variant, quantity: 10, available: 8)
    reserve(stock, 4, 'Verify this pickup')
    stock.update!(available: nil)
    held = InventoryExceptions.new(at: @at).sections.find { |group| group[:key] == :holds }[:rows].first
    assert_equal 'Held stock cannot be verified', held[:kind]
    assert_nil held[:shortage]
    assert_nil held[:available]
    stock.destroy!
    held = InventoryExceptions.new(at: @at).sections.find { |group| group[:key] == :holds }[:rows].first
    assert_nil held[:quantity]
    assert_nil held[:available]
    assert_equal 4, held[:held]
    assert_nil held[:shortage]
    get inventory_exceptions_path, params: { section: 'holds' }
    assert_response :success
    assert_includes response.body, 'Shortage:'
    assert_includes response.body, 'Unknown'
  end

  test 'positive mirrored capacity cannot verify holds when parent source identity changes' do
    stock = level(@shopify, @variant, quantity: 10, available: 10)
    reserve(stock, 2, 'Previously valid pickup')
    @shopify.update!(source: 'square')
    row = InventoryExceptions.new(at: @at, section: 'holds').rows.first
    assert_equal 'Held stock cannot be verified', row[:kind]
    assert_equal 2, row[:held]
    assert_nil row[:shortage]
    assert_equal 10, row[:available]
    assert_includes row[:detail], 'source/location identity'
  end

  test 'incomplete source orders are bounded blocked-data diagnostics with exact location mapping' do
    incomplete = Core::Order.create!(source: 'shopify', source_order_id: 'source-order-incomplete',
      order_number: 'Incomplete source order', occurred_at: @at, gross_cents: 1000, source_lines_complete: false,
      location_id: @shopify.externalId)
    incomplete.mark_paid!
    complete = Core::Order.create!(source: 'shopify', source_order_id: 'source-order-complete',
      occurred_at: @at, gross_cents: 1000, source_lines_complete: true)
    complete.mark_paid!
    unpaid = Core::Order.create!(source: 'shopify', source_order_id: 'source-order-unpaid',
      occurred_at: @at, gross_cents: 1000, source_lines_complete: false)
    queue = InventoryExceptions.new(at: @at, section: 'orders', source: 'shopify', location_id: @shopify.id)
    assert_equal 1, queue.rows.length
    assert_equal incomplete.source_order_id, queue.rows.first[:item_id]
    assert_equal incomplete.id, queue.rows.first[:review_id]
    assert_includes queue.rows.first[:detail], 'must not drive gram consumption'
    refute queue.rows.any? { |row| row[:review_id] == complete.id || row[:review_id] == unpaid.id }
    assert_empty InventoryExceptions.new(at: @at, section: 'orders', source: 'square').rows
    get inventory_exceptions_path, params: { section: 'orders', source: 'shopify', location_id: @shopify.id }
    assert_response :success
    assert_select "a[href='#{order_path(incomplete)}']", 'Review source order'
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  test 'catalog conflicts include same-product normalized SKU duplicates barcodes shared and inconsistent links' do
    first = variant('DUPLICATE', barcode: '012345')
    second = variant(' duplicate ', barcode: '012345')
    square_first = square_variation('Regular')
    square_variation(' regular ')
    SkuLink.create!(sku: first.sku, shopifyVariantId: first.id, squareVariationId: square_first.id)
    SkuLink.create!(sku: second.sku, shopifyVariantId: second.id, squareVariationId: square_first.id)
    changed = variant('NEW-SKU')
    old_square = square_variation('OLD-SKU')
    SkuLink.create!(sku: 'OLD-SKU', shopifyVariantId: changed.id, squareVariationId: old_square.id)
    SkuLink.create!(sku: 'HALF-LINK', shopifyVariantId: nil, squareVariationId: nil)
    rows = InventoryExceptions.new(at: @at, section: 'identity').rows
    duplicate = rows.find { |row| row[:kind] == 'Duplicate Shopify SKU' }
    assert_equal 'duplicate', duplicate[:label]
    assert_includes duplicate[:detail], '2 catalog records'
    assert_includes duplicate[:detail], first.id
    assert rows.any? { |row| row[:kind] == 'Duplicate Square SKU' && row[:label] == 'regular' }
    assert rows.any? { |row| row[:kind] == 'Duplicate Shopify barcode' && row[:label] == '012345' }
    assert rows.any? { |row| row[:kind] == 'Shared Square identity' && row[:item_id] == square_first.id }
    assert rows.any? { |row| row[:kind] == 'Unresolved catalog link' && row[:label] == 'OLD-SKU' }
    assert rows.any? { |row| row[:kind] == 'Unresolved catalog link' && row[:label] == 'HALF-LINK' }
    square_rows = InventoryExceptions.new(at: @at, source: 'square', section: 'identity').rows
    refute square_rows.any? { |row| row[:kind].start_with?('Duplicate Shopify') }
  end

  test 'intentional manual unlink is healthy while absent or foreign source parents remain unresolved' do
    SkuLink.create!(shopifyVariantId: @variant.id, squareVariationId: nil, sku: @variant.sku,
      auto: false, matchSource: 'manual-unlink')
    SkuLink.create!(shopifyVariantId: nil, squareVariationId: nil, sku: 'MISSING-UNLINK-PARENT',
      auto: false, matchSource: 'manual-unlink')
    other = Tenant.create!(name: 'Foreign unlink store', subdomain: 'foreign-unlink-store')
    Current.tenant = other
    product = ShopifyProduct.create!(id: 'foreign-unlink-product', title: 'Private foreign product')
    foreign_variant = ShopifyVariant.create!(productId: product.id, sku: 'FOREIGN-UNLINK', title: 'Private foreign variant')
    Current.tenant = @tenant
    SkuLink.create!(shopifyVariantId: foreign_variant.id, squareVariationId: nil, sku: 'FOREIGN-UNLINK-PARENT',
      auto: false, matchSource: 'manual-unlink')
    rows = InventoryExceptions.new(at: @at, section: 'identity').rows
    refute rows.any? { |row| row[:kind] == 'Unresolved catalog link' && row[:item_id] == @variant.id }
    assert rows.any? { |row| row[:kind] == 'Unresolved catalog link' && row[:label] == 'MISSING-UNLINK-PARENT' }
    assert rows.any? { |row| row[:kind] == 'Unresolved catalog link' && row[:label] == 'FOREIGN-UNLINK-PARENT' }
    assert_equal 2, rows.length
  end

  test 'pending counts and depleted lots have review links and explicit separate coverage' do
    count = InventoryCount.create!(locationId: @square.id, countedAt: @at - 1.day, note: 'Counter worksheet')
    count.items.create!(sku: 'COUNT-ONE', quantity: 3)
    count.submit!
    material = BulkMaterial.create!(name: 'Bulk test herb', unit: 'g')
    lot = BulkLedger.receive(material: material, attributes: { code: 'EXHAUSTED' },
      movement_attributes: { quantity: '1', unit: 'g', reference: 'Initial receipt' }, actor: 'operator@example.com')
    BulkLedger.record(lot: lot, attributes: { kind: 'consume', quantity: '1', unit: 'g', reference: 'Use remaining lot' }, actor: 'operator@example.com')
    queue = InventoryExceptions.new(at: @at, source: 'square', location_id: @square.id)
    count_row = queue.rows.find { |row| row[:kind] == 'Count awaits review' }
    assert_equal count.id, count_row[:review_id]
    assert_includes count_row[:detail], '1 worksheet rows'
    assert_includes count_row[:detail], 'across locations'
    assert queue.rows.any? { |row| row[:kind] == 'Bulk lot depleted' && row[:review_id] == lot.id }
    get inventory_exceptions_path, params: { source: 'square', location_id: @square.id }
    assert_response :success
    assert_select "a[href='#{inventory_count_path(count)}']", 'Review count'
    assert_select "a[href='#{bulk_material_bulk_lot_path(material, lot)}']", 'Review lot'
    assert_includes response.body, 'Platform and location filters do not apply'
    assert_equal 'pending', count.reload.status
    assert_equal 0, lot.reload.balance_mg
  end

  test 'tenant scoping includes association bounds and never renders foreign record labels' do
    foreign = Tenant.create!(name: 'Secret store', subdomain: 'exception-foreign')
    Current.tenant = foreign
    foreign_product = ShopifyProduct.create!(id: 'secret-product', title: 'Private product')
    foreign_variant = ShopifyVariant.create!(productId: foreign_product.id, title: 'PRIVATE ITEM LABEL', sku: 'SECRET-SKU')
    foreign_location = location('shopify', 'PRIVATE LOCATION LABEL')
    foreign_stock = level(foreign_location, foreign_variant, quantity: 10, available: 10)
    reserve(foreign_stock, 3, 'PRIVATE HOLD LABEL')
    foreign_stock.update!(quantity: -2, available: -2)
    foreign_count = InventoryCount.create!(locationId: foreign_location.id, countedAt: @at, note: 'PRIVATE COUNT LABEL')
    foreign_count.submit!
    Current.tenant = @tenant
    InventoryLevel.create!(source: 'shopify', locationId: foreign_location.id, shopifyVariantId: foreign_variant.id,
      quantity: 2, available: 2, updatedAt: @at)
    queue = InventoryExceptions.new(at: @at)
    assert_equal 1, queue.rows.length
    assert_equal 'Invalid pool identity', queue.rows.first[:kind]
    assert_equal 'Unresolved source item', queue.rows.first[:label]
    get inventory_exceptions_path
    assert_response :success
    %w[PRIVATE SECRET-SKU].each { |text| refute_includes response.body, text }
    assert_select "option[value='#{foreign_location.id}']", count: 0
    cached = InventoryExceptions.new(at: @at)
    cached.rows
    Current.tenant = foreign
    assert_raises(ActiveRecord::RecordNotFound) { cached.rows }
  end

  test 'matching SQL results member samples and pagination remain explicitly bounded' do
    3.times { |index| level(@shopify, variant("BOUNDED-#{index}"), quantity: -1, available: 1) }
    queue = InventoryExceptions.new(at: @at, limit: 2, per_page: 1, section: 'stock')
    assert_equal 2, queue.rows.length
    assert queue.summary[:limited]
    assert_equal 2, queue.total_pages
    assert_equal 1, queue.page_rows.length
    second = InventoryExceptions.new(at: @at, limit: 2, per_page: 1, section: 'stock', page: 2)
    refute_equal queue.page_rows.first[:item_id], second.page_rows.first[:item_id]
    7.times { variant('ONE-HUGE-GROUP') }
    identity = InventoryExceptions.new(at: @at, limit: 1, section: 'identity')
    duplicate = identity.rows.find { |row| row[:kind] == 'Duplicate Shopify SKU' }
    assert_includes duplicate[:detail], '7 catalog records'
    assert_includes duplicate[:detail], 'member sample only'
    assert identity.summary[:limited]
  end

  test 'queue has bounded query count and performs no writes while rendering' do
    12.times { |index| level(@shopify, variant("QUERY-#{index}"), quantity: -1, available: 1) }
    queries = []
    collector = lambda do |*args|
      payload = args.last
      queries << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:cached]
    end
    InventoryWriter.expects(:physical_count!).never
    NegativeInventory.expects(:fix!).never
    NegativeInventory.expects(:fix_all!).never
    ActiveSupport::Notifications.subscribed(collector, 'sql.active_record') do
      InventoryExceptions.new(at: @at).rows
    end
    selects = queries.count { |sql| sql.match?(/\ASELECT/i) }
    assert_operator selects, :<=, 25, queries.join("\n")
    refute queries.any? { |sql| sql.match?(/\A(?:INSERT|UPDATE|DELETE)/i) }, queries.join("\n")
    assert_no_difference ['InventoryMovement.count', 'BulkMovement.count', 'StockReservation.count'] do
      get inventory_exceptions_path
      assert_response :success
    end
    assert_select "form[action='#{inventory_exceptions_path}'][method='get']"
    assert_select "form[action*='fix']", count: 0
  end

  test 'read access is required and invalid filters redirect safely' do
    writer = User.create!(email: 'exception-write-only@example.com', password: 'password123', role: 'manager', tenant: @tenant)
    writer.update_permission_overrides!(['inventory.write'])
    delete logout_path
    post login_path, params: { email: writer.email, password: 'password123' }
    get inventory_exceptions_path
    assert_redirected_to root_path
    delete logout_path
    post login_path, params: { email: 'admin@example.com', password: 'password' }
    [{ source: 'other' }, { stale_hours: '0' }, { stale_hours: '1.5' }, { stale_hours: '169' }, { section: 'execute' }, { page: '-1' }].each do |filters|
      get inventory_exceptions_path, params: filters
      assert_redirected_to inventory_exceptions_path
    end
  end

  private

  def variant(sku, **attributes)
    ShopifyVariant.create!({ productId: @product.id, sku: sku, title: "Item #{sku}", tracked: true }.merge(attributes))
  end

  def square_variation(sku)
    item = SquareItem.create!(id: SecureRandom.uuid, name: "Square product #{sku}")
    SquareVariation.create!(id: SecureRandom.uuid, itemId: item.id, sku: sku, name: "Square item #{sku}")
  end

  def location(source, name)
    Location.create!(source: source, externalId: SecureRandom.uuid, name: name, active: true)
  end

  def level(location, item, **attributes)
    source = attributes.delete(:source) || location.source
    item_key = item.is_a?(ShopifyVariant) ? :shopifyVariantId : :squareVariationId
    InventoryLevel.create!({ source: source, locationId: location.id, item_key => item.id,
      quantity: 5, available: 5, updatedAt: @at }.merge(attributes))
  end

  def reserve(stock, quantity, reference, **attributes)
    StockReservationService.reserve(inventory_level_id: stock.id,
      attributes: { quantity: quantity, reference: reference }.merge(attributes), actor: 'operator@example.com')
  end
end
