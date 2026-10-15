# frozen_string_literal: true

require 'test_helper'

class BulkSaleConsumptionTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: 'Reviewed materials', subdomain: "reviewed-materials-#{SecureRandom.hex(4)}")
    Current.tenant = @tenant
    @actor = 'inventory@example.invalid'
    @product = ShopifyProduct.create!(id: 'gid://shopify/Product/9001', title: 'Herbal tea')
    @variant = ShopifyVariant.create!(id: 'gid://shopify/ProductVariant/9002', productId: @product.id, sku: 'TEA', title: 'Small', inventoryQuantity: 99)
    @material = BulkMaterial.create!(name: 'Loose herb', unit: 'g')
    @lot = BulkLedger.receive(material: @material, attributes: { code: 'LOT-1' },
      movement_attributes: { quantity: '10', unit: 'g', reference: 'Supplier receipt' }, actor: @actor)
    @recipe = create_recipe
    @order, @line = create_sale
  end

  teardown { Current.reset }

  test 'recipes are exact immutable versions with explicit effective dates and integer milligram precision' do
    assert @recipe.persisted?, @recipe.errors.full_messages.to_sentence
    assert_equal 1250, @recipe.mg_per_unit
    assert_equal BigDecimal('1.25'), @recipe.grams
    assert_equal 1, @recipe.version
    assert_equal 'Herbal tea — Small', @recipe.catalog_title
    assert_equal 'TEA', @recipe.catalog_sku
    later = create_recipe(grams: '2.5', effective: '2026-01-03T00:00:00Z')
    assert later.persisted?, later.errors.full_messages.to_sentence
    assert_equal 2, later.version
    assert_equal 1250, @recipe.reload.mg_per_unit
    assert_raises(ActiveRecord::ReadOnlyRecord) { @recipe.update!(mg_per_unit: 1) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { @recipe.destroy! }
    early = create_recipe(effective: '2026-01-02T00:00:00Z')
    refute early.persisted?
    assert early.errors[:effective_from].any?
  end

  test 'invalid weights times and direct recipe creation cannot bypass exact catalog review' do
    %w[0 -1 0.0005 1.2345 NaN 1e3 999999999999999999999].each do |grams|
      recipe = create_recipe(grams: grams, effective: '2026-01-03T00:00:00Z')
      refute recipe.persisted?
      assert recipe.errors[:grams_per_unit].any?
    end
    ['2026-01-01', '2026-02-30T12:00:00Z', '2026-01-01T24:00:00Z', '2026-01-01T12:00:00-00:00',
     '2026-01-01T12:00:00+15:00', '2026-01-01T12:00:00+14:30', 'private bad time', nil].each do |time|
      recipe = create_recipe(effective: time)
      refute recipe.persisted?
      assert recipe.errors[:effective_from].any?
    end
    unknown = BulkRecipeService.create(source_variant_id: 'TEA', material_id: @material.id,
      grams_per_unit: '1', effective_from: Time.utc(2026, 1, 3), actor: @actor)
    refute unknown.persisted?
    direct = BulkRecipe.new(source: 'shopify', source_variant_id: @variant.id, bulk_material: @material,
      mg_per_unit: 1, version: 2, effective_from: Time.utc(2026, 1, 3), catalog_title: 'Bypass', created_by: @actor)
    refute direct.save
    assert_match(/recipe service/, direct.errors.full_messages.to_sentence)
    assert_equal 1, BulkRecipe.count
  end

  test 'preview is read only and consumption atomically records one immutable linked movement' do
    counts = [BulkMovement.count, BulkConsumption.count]
    plan = preview
    assert_equal counts, [BulkMovement.count, BulkConsumption.count]
    assert_equal 2, plan.quantity
    assert_equal 2500, plan.required_mg
    assert_equal 10_000, plan.available_mg
    assert_equal @recipe.id, plan.recipe.id
    assert_match(/\A[0-9a-f]{64}\z/, plan.fingerprint)
    before_inventory = @variant.inventoryQuantity
    receipt = apply(expected_fingerprint: plan.fingerprint)

    assert receipt.persisted?
    assert_equal 2500, receipt.consumed_mg
    assert_equal @actor, receipt.created_by
    assert_equal @line.source_line_id, receipt.source_line_id
    assert_equal @variant.id, receipt.source_variant_id
    assert_equal(-2500, receipt.bulk_movement.delta_mg)
    assert_equal receipt.bulk_movement_id, receipt.bulk_movement.id
    assert_equal 'consume', receipt.bulk_movement.kind
    assert_equal 7500, @lot.reload.balance_mg
    assert_equal @lot.balance_mg, @lot.bulk_movements.sum(:delta_mg)
    assert_equal before_inventory, @variant.reload.inventoryQuantity
    assert_equal 0, InventoryMovement.count
    assert_raises(ActiveRecord::ReadOnlyRecord) { receipt.update!(created_by: 'rewrite@example.invalid') }
    assert_raises(ActiveRecord::ReadOnlyRecord) { receipt.destroy! }
    assert_not_requested(:any, /./)
  end

  test 'exact same request or a fresh request for the same source line cannot consume twice' do
    token = SecureRandom.uuid
    first = apply(request_token: token)
    assert_equal first.id, apply(request_token: token).id
    assert_equal first.id, apply.id
    assert_equal 1, BulkConsumption.count
    assert_equal 2, BulkMovement.count
    assert_equal 7500, @lot.reload.balance_mg
  end

  test 'source identity replay survives canonical local line recreation' do
    first = apply
    attrs = @line.attributes.except('id', 'created_at', 'updated_at')
    @line.destroy!
    recreated = Core::OrderLine.create!(attrs)
    refute_equal @line.id, recreated.id
    assert_equal first.id, apply.id
    assert_equal 7500, @lot.reload.balance_mg
    assert_equal 1, BulkConsumption.count
  end

  test 'source edits lot changes and recipe changes invalidate reviewed plans and never rewrite prior consumption' do
    plan = preview
    @line.update!(quantity: 3)
    assert_raises(BulkSaleConsumption::Error) { apply(expected_fingerprint: plan.fingerprint) }
    assert_equal 10_000, @lot.reload.balance_mg
    @line.update!(quantity: 2)
    receipt = apply
    @line.update!(quantity: 3)
    assert_raises(BulkSaleConsumption::Error) { apply }
    assert_equal 2500, receipt.reload.consumed_mg
    assert_equal 7500, @lot.reload.balance_mg
    @line.update!(quantity: 2)
    other_lot = BulkLedger.receive(material: @material, attributes: { code: 'LOT-2' },
      movement_attributes: { quantity: '10', unit: 'g', reference: 'Second receipt' }, actor: @actor)
    assert_raises(BulkSaleConsumption::Error) { apply(lot_id: other_lot.id) }
    assert_equal 10_000, other_lot.reload.balance_mg
    create_recipe(grams: '2', effective: '2026-01-01T12:00:00Z')
    assert_raises(BulkSaleConsumption::Error) { apply(recipe_id: nil) }
    assert_equal 2500, receipt.reload.consumed_mg
  end

  test 'shortages and audit persistence failures roll back every material movement' do
    @line.update!(quantity: 9)
    assert_equal 1250, preview.shortage_mg
    assert_raises(BulkSaleConsumption::Error) { apply }
    assert_equal 10_000, @lot.reload.balance_mg
    assert_equal 1, BulkMovement.count
    assert_equal 0, BulkConsumption.count
    @line.update!(quantity: 2)
    BulkConsumption.expects(:create!).raises(ActiveRecord::RecordInvalid.new(BulkConsumption.new))
    error = assert_raises(BulkSaleConsumption::Error) { apply }
    assert_nil error.cause
    assert_equal 10_000, @lot.reload.balance_mg
    assert_equal 1, BulkMovement.count
  end

  test 'database contention and failed statements expose no SQL or source data and preserve stock' do
    BulkLedger.expects(:record).raises(ActiveRecord::StatementInvalid.new('Private SQL source and actor details'))
    error = assert_raises(BulkSaleConsumption::Error) { apply }
    refute_includes error.message, 'Private SQL'
    assert_nil error.cause
    assert_equal 10_000, @lot.reload.balance_mg
    assert_equal 0, BulkConsumption.count
    assert_equal 1, BulkMovement.count
  end

  test 'current lot availability is rechecked under lock without invalidating an unchanged sale recipe' do
    plan = preview
    movement = BulkLedger.record(lot: @lot, attributes: { kind: 'consume', quantity: '1', unit: 'g',
      reference: 'Manual use' }, actor: @actor)
    assert movement.persisted?
    receipt = apply(expected_fingerprint: plan.fingerprint)
    assert receipt.persisted?
    assert_equal 6500, @lot.reload.balance_mg
  end

  test 'future recipes cannot consume earlier sales and each sale uses its effective version' do
    newer = create_recipe(grams: '2.5', effective: '2026-01-03T00:00:00Z')
    assert_equal @recipe.id, preview.recipe.id
    assert_raises(BulkSaleConsumption::Error) { preview(recipe_id: newer.id) }
    @order.update!(occurred_at: Time.utc(2025, 12, 31))
    assert_raises(BulkSaleConsumption::Error) { preview }
    @order.update!(occurred_at: Time.utc(2026, 1, 4))
    assert_equal newer.id, preview(recipe_id: nil).recipe.id
    assert_equal 5000, preview(recipe_id: nil).required_mg
  end

  test 'recipes never infer identity from duplicate SKU or consume the wrong material' do
    other = ShopifyVariant.create!(id: 'gid://shopify/ProductVariant/9010', productId: @product.id, sku: @variant.sku, title: 'Another variant')
    @line.update!(source_variant_id: other.id)
    assert_raises(BulkSaleConsumption::Error) { preview }
    @line.update!(source_variant_id: @variant.id)
    other_material = BulkMaterial.create!(name: 'Different ingredient', unit: 'g')
    lot = BulkLedger.receive(material: other_material, attributes: { code: 'WRONG' },
      movement_attributes: { quantity: '10', unit: 'g', reference: 'Other ingredient' }, actor: @actor)
    assert_raises(BulkSaleConsumption::Error) { preview(lot_id: lot.id) }
    assert_equal 10_000, lot.reload.balance_mg
  end

  test 'incomplete unpaid cancelled source and refund histories cannot consume or restock materials' do
    [
      { source_lines_complete: false }, { source_financial_status: 'PENDING' },
      { source_financial_status: 'REFUNDED' }, { source: 'square' }, { status: 'cancelled' },
      { source_order_id: 'unknown-order' }
    ].each do |attributes|
      original = @order.attributes.slice(*attributes.keys.map(&:to_s))
      @order.update_columns(attributes)
      assert_raises(BulkSaleConsumption::Error) { apply }
      @order.update_columns(original)
    end
    receipt = apply
    Core::Refund.create!(order: @order, amount_cents: 100, method: 'card', refunded_at: Time.current, reference: 'REFUND-1')
    assert_raises(BulkSaleConsumption::Error) { apply }
    assert_equal 7500, @lot.reload.balance_mg
    assert_equal 2500, receipt.reload.consumed_mg
    assert_equal 2, BulkMovement.count
  end

  test 'unknown source line variant or zero quantity cannot be consumed' do
    assert_raises(BulkSaleConsumption::Error) { preview(source_line_id: 'TEA') }
    assert_raises(BulkSaleConsumption::Error) { preview(source_line_id: 'gid://shopify/LineItem/99999') }
    @line.update!(quantity: 0)
    assert_raises(BulkSaleConsumption::Error) { preview }
    @line.update!(quantity: 2, source_variant_id: 'TEA')
    assert_raises(BulkSaleConsumption::Error) { preview }
    assert_equal 10_000, @lot.reload.balance_mg
  end

  test 'tenant boundaries reject foreign orders materials and lots' do
    other = Tenant.create!(name: 'Foreign materials', subdomain: 'foreign-materials')
    foreign = BulkMaterial.create!(tenant_id: other.id, name: 'Foreign herb', unit: 'g')
    assert_raises(ActiveRecord::RecordNotFound) do
      BulkRecipeService.create(source_variant_id: @variant.id, material_id: foreign.id, grams_per_unit: '1',
        effective_from: Time.utc(2026, 1, 3), actor: @actor)
    end
    Current.tenant = other
    assert_raises(ActiveRecord::RecordNotFound) { preview }
    assert_raises(ActiveRecord::RecordNotFound) { apply }
    assert_equal 0, BulkConsumption.count
    Current.tenant = @tenant
    assert_equal 10_000, @lot.reload.balance_mg
  end

  test 'request token conflicts with other sale lines or manual movements cannot consume material' do
    token = SecureRandom.uuid
    first = apply(request_token: token)
    other_order, other_line = create_sale(order_number: 9050, line_number: 9051)
    assert_raises(BulkSaleConsumption::Error) do
      apply(order_id: other_order.id, source_line_id: other_line.source_line_id, request_token: token)
    end
    assert_equal first.id, BulkConsumption.first.id
    assert_equal 7500, @lot.reload.balance_mg
    manual_token = SecureRandom.uuid
    BulkLedger.record(lot: @lot, attributes: { kind: 'consume', quantity: '1', unit: 'g', reference: 'Manual use',
      request_token: manual_token }, actor: @actor)
    assert_raises(BulkSaleConsumption::Error) do
      apply(order_id: other_order.id, source_line_id: other_line.source_line_id, request_token: manual_token)
    end
    assert_equal 6500, @lot.reload.balance_mg
    assert_equal 1, BulkConsumption.count
  end

  test 'receipt audit batch is read only and re-created local rows still match exact source identity' do
    receipt = apply
    attrs = @line.attributes.except('id', 'created_at', 'updated_at')
    @line.destroy!
    @line = Core::OrderLine.create!(attrs)
    before = [@lot.reload.attributes, receipt.attributes, BulkMovement.order(:id).map(&:attributes)]
    states = BulkSaleConsumption.audit_states([receipt])
    assert_equal 'matches', states.fetch(receipt.id)[:status]
    assert_equal before, [@lot.reload.attributes, receipt.reload.attributes, BulkMovement.order(:id).map(&:attributes)]
  end

  test 'receipt audit flags changed quantity variant source time payment and completeness without stock writes' do
    receipt = apply
    [{ quantity: 3 }, { source_variant_id: 'gid://shopify/ProductVariant/999' }].each do |change|
      original = @line.attributes.slice(*change.keys.map(&:to_s))
      @line.update_columns(change)
      assert_equal 'review', BulkSaleConsumption.audit_states([receipt]).fetch(receipt.id)[:status]
      @line.update_columns(original)
    end
    [{ occurred_at: Time.utc(2026, 1, 3) }, { source_financial_status: 'REFUNDED' },
     { source_lines_complete: false }, { status: 'cancelled' }].each do |change|
      original = @order.attributes.slice(*change.keys.map(&:to_s))
      @order.update_columns(change)
      assert_equal 'review', BulkSaleConsumption.audit_states([receipt]).fetch(receipt.id)[:status]
      @order.update_columns(original)
    end
    assert_equal 7500, @lot.reload.balance_mg
    assert_equal 2500, receipt.reload.consumed_mg
    assert_equal 2, BulkMovement.count
  end

  test 'receipt audit flags missing local source lines and discarded refund history without restocking' do
    receipt = apply
    original = @line.attributes.except('id', 'created_at', 'updated_at')
    @line.destroy!
    missing = BulkSaleConsumption.audit_states([receipt]).fetch(receipt.id)
    assert_equal 'review', missing[:status]
    assert_includes missing[:message], 'missing or ambiguous'
    @line = Core::OrderLine.create!(original)
    refund = Core::Refund.create!(order: @order, amount_cents: 100, method: 'card', refunded_at: Time.current)
    refund.discard!
    assert_equal 0, @order.refunds.count
    state = BulkSaleConsumption.audit_states([receipt]).fetch(receipt.id)
    assert_equal 'review', state[:status]
    assert_includes state[:message], 'Refund history'
    assert_equal 7500, @lot.reload.balance_mg
    assert_equal 2500, receipt.reload.consumed_mg
  end

  test 'receipt audit batch has bounded queries and enforces tenant and receipt limits' do
    first = apply
    order, line = create_sale(order_number: 9080, line_number: 9081)
    second = apply(order_id: order.id, source_line_id: line.source_line_id)
    selects = []
    listener = ->(_name, _started, _finished, _id, payload) do
      selects << payload[:sql] if payload[:sql].match?(/\ASELECT/i) && !payload[:cached] && payload[:name] != 'SCHEMA'
    end
    states = nil
    ActiveSupport::Notifications.subscribed(listener, 'sql.active_record') do
      states = BulkSaleConsumption.audit_states([first, second])
    end
    assert_equal ['matches'], states.values.pluck(:status).uniq
    assert_operator selects.length, :<=, 3
    assert_equal({}, BulkSaleConsumption.audit_states([]))
    assert_raises(BulkSaleConsumption::Error) { BulkSaleConsumption.audit_states(Array.new(101, first)) }
    other = Tenant.create!(name: 'Other audit store', subdomain: 'other-audit-store')
    Current.tenant = other
    assert_raises(ActiveRecord::RecordNotFound) { BulkSaleConsumption.audit_states([first]) }
  end

  test 'multiplication cannot exceed the canonical integer milligram range' do
    huge = create_recipe(grams: '9223372036854775.807', effective: '2026-01-01T12:00:00Z')
    assert huge.persisted?, huge.errors.full_messages.to_sentence
    assert_raises(BulkSaleConsumption::Error) { preview(recipe_id: huge.id) }
    assert_equal 10_000, @lot.reload.balance_mg
  end

  private

  def create_recipe(grams: '1.25', effective: '2026-01-01T00:00:00Z')
    BulkRecipeService.create(source_variant_id: @variant.id, material_id: @material.id,
      grams_per_unit: grams, effective_from: effective, actor: @actor)
  end

  def create_sale(order_number: 9003, line_number: 9004)
    order = Core::Order.create!(source: 'shopify', source_order_id: "gid://shopify/Order/#{order_number}",
      order_number: "SALE-#{order_number}", occurred_at: Time.utc(2026, 1, 2, 12), gross_cents: 1000,
      source_lines_complete: true, source_financial_status: 'PAID', currency: 'USD')
    order.mark_paid!
    line = order.order_lines.create!(name: 'Tea', sku: @variant.sku, quantity: 2, unit_cents: 500, line_cents: 1000,
      source_line_id: "gid://shopify/LineItem/#{line_number}", source_variant_id: @variant.id)
    [order, line]
  end

  def preview(**options)
    BulkSaleConsumption.preview(**{ order_id: @order.id, source_line_id: @line.source_line_id, lot_id: @lot.id }.merge(options))
  end

  def apply(**options)
    BulkSaleConsumption.apply!(**{ order_id: @order.id, source_line_id: @line.source_line_id, lot_id: @lot.id,
      actor: @actor, request_token: SecureRandom.uuid }.merge(options))
  end
end

class BulkSaleConsumptionConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @tenant = Tenant.create!(name: 'Sale material race', subdomain: "sale-material-race-#{SecureRandom.hex(4)}")
    Current.tenant = @tenant
    @product = ShopifyProduct.create!(id: "gid://shopify/Product/#{SecureRandom.random_number(1_000_000) + 1}", title: 'Concurrent product')
    @variant = ShopifyVariant.create!(id: "gid://shopify/ProductVariant/#{SecureRandom.random_number(1_000_000) + 1}", productId: @product.id, title: 'Concurrent variant')
    @material = BulkMaterial.create!(name: 'Concurrent ingredient', unit: 'g')
    @lot = BulkLedger.receive(material: @material, attributes: { code: 'CONCURRENT' },
      movement_attributes: { quantity: '5', unit: 'g', reference: 'Receipt' }, actor: 'counter@example.invalid')
    @recipe = BulkRecipeService.create(source_variant_id: @variant.id, material_id: @material.id,
      grams_per_unit: '1', effective_from: '2026-01-01T00:00:00Z', actor: 'counter@example.invalid')
    @sales = 2.times.map do |number|
      order = Core::Order.create!(source: 'shopify', source_order_id: "gid://shopify/Order/#{50_001 + number}",
        order_number: "CONCURRENT-#{number}", occurred_at: Time.utc(2026, 1, 2), gross_cents: 1000,
        source_lines_complete: true, source_financial_status: 'PAID')
      order.mark_paid!
      line = order.order_lines.create!(name: 'Concurrent product', quantity: 4, unit_cents: 250, line_cents: 1000,
        source_line_id: "gid://shopify/LineItem/#{60_001 + number}", source_variant_id: @variant.id)
      [order, line]
    end
  end

  teardown do
    Current.tenant = @tenant
    BulkConsumption.delete_all
    BulkMovement.delete_all
    BulkLot.delete_all
    BulkRecipe.delete_all
    BulkMaterial.delete_all
    Core::OrderLine.delete_all
    Core::Order.delete_all
    @variant&.destroy!
    @product&.destroy!
    @tenant&.destroy!
    Current.reset
  end

  test 'two source lines cannot consume the same remaining material twice' do
    outcomes = race { |number| @sales[number] }
    assert_equal 1, outcomes.count { |outcome| outcome.is_a?(BulkConsumption) }
    failure = outcomes.find { |outcome| outcome.is_a?(BulkSaleConsumption::Error) }
    assert failure
    assert_match(/insufficient material/, failure.message)
    assert_equal 1000, @lot.reload.balance_mg
    assert_equal 1, BulkConsumption.count
    assert_equal 2, BulkMovement.count
    assert_equal @lot.balance_mg, @lot.bulk_movements.sum(:delta_mg)
  end

  test 'simultaneous retries of a source line create one immutable receipt and movement' do
    outcomes = race { @sales.first }
    assert outcomes.all? { |outcome| outcome.is_a?(BulkConsumption) }
    assert_equal 1, outcomes.map(&:id).uniq.length
    assert_equal 1000, @lot.reload.balance_mg
    assert_equal 1, BulkConsumption.count
    assert_equal 2, BulkMovement.count
  end

  private

  def race
    ready = Queue.new
    start = Queue.new
    outcomes = Queue.new
    threads = Array.new(2) do |number|
      selected = yield(number)
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Current.tenant = @tenant
          ready << true
          start.pop
          order, line = selected
          outcomes << BulkSaleConsumption.apply!(order_id: order.id, source_line_id: line.source_line_id,
            lot_id: @lot.id, actor: 'counter@example.invalid', request_token: SecureRandom.uuid)
        ensure
          Current.reset
        end
      rescue StandardError => error
        outcomes << error
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each { |thread| assert thread.join(15), 'concurrent sale consumption timed out' }
    Array.new(2) { outcomes.pop }.tap do |results|
      results.each do |result|
        assert result.is_a?(BulkConsumption) || result.is_a?(BulkSaleConsumption::Error), result.inspect
      end
    end
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end
end
