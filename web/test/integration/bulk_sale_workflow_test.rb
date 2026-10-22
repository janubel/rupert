# frozen_string_literal: true

require 'test_helper'

class BulkSaleWorkflowTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @actor = 'admin@example.com'
    @sale_time = 1.hour.ago.change(usec: 0)
    @product = ShopifyProduct.create!(id: 'gid://shopify/Product/76501', title: 'Bulk workflow product', status: 'ACTIVE')
    @variant = ShopifyVariant.create!(id: 'gid://shopify/ProductVariant/76502', productId: @product.id, sku: 'SHARED-BULK', title: 'Three grams', price: 10)
    @other_variant = ShopifyVariant.create!(id: 'gid://shopify/ProductVariant/76503', productId: @product.id, sku: 'SHARED-BULK', title: 'Different product', price: 20)
    @material = BulkMaterial.create!(name: 'Verified raw herb', unit: 'g')
    @lot = receive('LOT-A', '100')
    @short_lot = receive('LOT-SHORT', '5')
    @recipe = BulkRecipeService.create(source_variant_id: @variant.id, material_id: @material.id,
      grams_per_unit: '3.5', effective_from: @sale_time - 1.day, actor: @actor)
    CanonicalOrderImporter.from_shopify!([source_order])
    @order = Core::Order.find_by!(source_order_id: 'gid://shopify/Order/76504')
    @line = @order.order_lines.first
    post login_path, params: { email: @actor, password: 'password' }
  end

  teardown { Current.reset }

  test 'recipe screens distinguish exact variants with a reused SKU and save a separate immutable version' do
    get new_bulk_recipe_path, params: { q: 'SHARED-BULK' }
    assert_response :success
    assert_select "option[value='#{@variant.id}']", /Three grams/
    assert_select "option[value='#{@other_variant.id}']", /Different product/
    before = @lot.balance_mg
    post bulk_recipes_path, params: { bulk_recipe: { source_variant_id: @other_variant.id, material_id: @material.id,
      grams_per_unit: '7', effective_from: (@sale_time - 1.day).iso8601 } }
    assert_redirected_to bulk_recipes_path
    other_recipe = BulkRecipe.find_by!(source_variant_id: @other_variant.id)
    assert_equal 7000, other_recipe.mg_per_unit
    assert_equal 3500, @recipe.reload.mg_per_unit
    assert_equal before, @lot.reload.balance_mg
    get bulk_recipes_path
    assert_response :success
    assert_includes response.body, @variant.id
    assert_includes response.body, @other_variant.id
  end

  test 'reviewed three units at three point five grams deduct exactly once and preserve the audit' do
    get new_bulk_consumption_path, params: { order_id: @order.id, source_line_id: @line.source_line_id }
    assert_response :success
    assert_includes response.body, 'order creation time'
    assert_select "form[action='#{preview_bulk_consumptions_path}'][data-turbo=false]"
    counts = [BulkMovement.count, BulkConsumption.count]
    token = preview_token
    assert_equal counts, [BulkMovement.count, BulkConsumption.count]
    assert_includes response.body, '10,500 mg'
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select 'meta[name=turbo-cache-control][content=no-cache]'
    assert_select "select[name='bulk_consumption[lot_id]']", count: 0
    payload = { bulk_consumption: { preview_token: token, confirmed: '1' } }
    post bulk_consumptions_path, params: payload
    assert_redirected_to bulk_consumptions_path
    receipt = BulkConsumption.last
    assert_equal 10_500, receipt.consumed_mg
    assert_equal @variant.id, receipt.source_variant_id
    assert_equal 89_500, @lot.reload.balance_mg
    post bulk_consumptions_path, params: payload
    assert_equal receipt.id, BulkConsumption.last.id
    assert_equal 1, BulkConsumption.count
    assert_equal 89_500, @lot.reload.balance_mg
    get bulk_consumptions_path
    assert_response :success
    assert_includes response.body, "Applied receipt ##{receipt.id}"
    assert_includes response.body, 'Recipe v1'
  end

  test 'insufficient lot previews show an exact shortage with no record action' do
    post preview_bulk_consumptions_path, params: preview_payload(lot: @short_lot)
    assert_response :success
    assert_select '[role=alert]', /5,500 mg/
    assert_select "input[value='Save material use']", count: 0
    assert_select "input[name='bulk_consumption[preview_token]']", count: 0
    assert_equal 0, BulkConsumption.count
    assert_equal 5000, @short_lot.reload.balance_mg
  end

  test 'a changed imported quantity invalidates a reviewed deduction' do
    token = preview_token
    CanonicalOrderImporter.from_shopify!([source_order(quantity: 4)])
    assert_no_difference ['BulkConsumption.count', 'BulkMovement.count'] do
      post bulk_consumptions_path, params: { bulk_consumption: { preview_token: token, confirmed: '1' } }
    end
    assert_redirected_to bulk_consumptions_path
    assert_match(/changed after review/, flash[:alert])
    assert_equal 100_000, @lot.reload.balance_mg
  end

  test 'changed source after recorded use flags review without changing the historical receipt or stock' do
    token = preview_token
    post bulk_consumptions_path, params: { bulk_consumption: { preview_token: token, confirmed: '1' } }
    receipt = BulkConsumption.last
    CanonicalOrderImporter.from_shopify!([source_order(quantity: 4)])
    assert_no_difference ['BulkConsumption.count', 'BulkMovement.count'] do
      get bulk_consumptions_path
    end
    assert_response :success
    assert_select '[role=alert]', /Source variant, quantity or order time changed/
    assert_includes response.body, "Applied receipt ##{receipt.id}"
    assert_equal 10_500, receipt.reload.consumed_mg
    assert_equal 89_500, @lot.reload.balance_mg
  end

  test 'confirmation signed scope and expiry protect local deductions' do
    token = preview_token
    [nil, token + 'tampered'].each do |proof|
      assert_no_difference ['BulkConsumption.count', 'BulkMovement.count'] do
        post bulk_consumptions_path, params: { bulk_consumption: { preview_token: proof, confirmed: '1' } }
      end
      assert_match(/Review and confirm/, flash[:alert])
    end
    post bulk_consumptions_path, params: { bulk_consumption: { preview_token: token, confirmed: '0' } }
    assert_match(/Review and confirm/, flash[:alert])
    travel 16.minutes do
      post bulk_consumptions_path, params: { bulk_consumption: { preview_token: token, confirmed: '1' } }
      assert_match(/Review and confirm/, flash[:alert])
    end
    assert_equal 0, BulkConsumption.count
  end

  test 'a different authorized operator cannot reuse another operator review' do
    token = preview_token
    user = User.create!(tenant: @tenant, role: 'inventory_employee', email: 'bulk-operator@example.invalid', password: 'password123')
    delete logout_path
    post login_path, params: { email: user.email, password: 'password123' }
    post bulk_consumptions_path, params: { bulk_consumption: { preview_token: token, confirmed: '1' } }
    assert_match(/Review and confirm/, flash[:alert])
    assert_equal 0, BulkConsumption.count
  end

  test 'another tenant cannot inspect this sale or reuse its signed deduction' do
    token = preview_token
    tenant = Tenant.create!(name: 'Other inventory shop', subdomain: 'other-bulk-shop', status: 'active')
    user = User.create!(tenant: tenant, role: 'admin', email: 'other-bulk-admin@example.invalid', password: 'password123')
    delete logout_path
    post login_path, params: { email: user.email, password: 'password123' }
    get new_bulk_consumption_path, params: { order_id: @order.id, source_line_id: @line.source_line_id }
    assert_response :not_found
    post bulk_consumptions_path, params: { bulk_consumption: { preview_token: token, confirmed: '1' } }
    assert_match(/Review and confirm/, flash[:alert])
    get bulk_consumptions_path
    assert_response :success
    assert_not_includes response.body, @line.source_variant_id
    assert_equal 0, BulkConsumption.unscoped.count
    assert_equal 100_000, BulkLot.unscoped.find(@lot.id).balance_mg
  end

  test 'invalid recipe times remain visible for correction without creating a version' do
    assert_no_difference 'BulkRecipe.count' do
      post bulk_recipes_path, params: { bulk_recipe: { source_variant_id: @other_variant.id,
        material_id: @material.id, grams_per_unit: '7', effective_from: '2026-10-15T10:00:00' } }
    end
    assert_response :unprocessable_entity
    assert_select "input[name='bulk_recipe[effective_from]'][value='2026-10-15T10:00:00']"
    assert_select '[role=alert]', /effective/i
  end

  test 'read permissions allow audit inspection but do not allow recipe or deduction writes' do
    user = User.create!(tenant: @tenant, role: 'reader', email: 'bulk-auditor@example.invalid', password: 'password123')
    delete logout_path
    post login_path, params: { email: user.email, password: 'password123' }
    get bulk_recipes_path
    assert_response :success
    get bulk_consumptions_path
    assert_response :success
    get export_bulk_consumptions_path
    assert_response :success
    get new_bulk_recipe_path
    assert_response :redirect
    post preview_bulk_consumptions_path, params: preview_payload
    assert_response :redirect
    post bulk_consumptions_path, params: { bulk_consumption: { preview_token: 'none', confirmed: '1' } }
    assert_response :redirect
    assert_equal 0, BulkConsumption.count
    user.update_permission_overrides!(['inventory.write'])
    get bulk_consumptions_path
    assert_response :redirect
    post preview_bulk_consumptions_path, params: preview_payload
    assert_response :redirect
  end

  test 'legacy incomplete imports remain visible but cannot be consumed' do
    @order.update!(source_lines_complete: false)
    get bulk_consumptions_path
    assert_response :success
    assert_includes response.body, 'Blocked: source identity'
    post preview_bulk_consumptions_path, params: preview_payload
    assert_response :unprocessable_entity
    assert_select "input[name='bulk_consumption[preview_token]']", count: 0
    assert_equal 0, BulkConsumption.count
  end

  test 'audit CSV is permissioned date-filtered and safe for spreadsheet import' do
    token = preview_token
    post bulk_consumptions_path, params: { bulk_consumption: { preview_token: token, confirmed: '1' } }
    get export_bulk_consumptions_path, params: { from: Date.current.iso8601, to: Date.current.iso8601 }
    assert_response :success
    row = CSV.parse(response.body, headers: true).first
    assert_equal @line.source_line_id, row['source_line_id']
    assert_equal @variant.id, row['source_variant_id']
    assert_equal '10500', row['consumed_mg']
    assert_equal '1', row['recipe_version']
    assert_equal "'=ORDER-CSV", row['order_number']
    assert_equal 'no-store', response.headers['Cache-Control']
    get export_bulk_consumptions_path, params: { from: 3.days.ago.to_date.iso8601, to: 2.days.ago.to_date.iso8601 }
    assert_empty CSV.parse(response.body, headers: true)
  end

  private

  def preview_token
    post preview_bulk_consumptions_path, params: preview_payload
    assert_response :success
    css_select("input[name='bulk_consumption[preview_token]']").first['value']
  end

  def preview_payload(lot: @lot)
    { bulk_consumption: { order_id: @order.id, source_line_id: @line.source_line_id, lot_id: lot.id } }
  end

  def receive(code, grams)
    BulkLedger.receive(material: @material, attributes: { code: code },
      movement_attributes: { quantity: grams, unit: 'g', reference: 'Verified supplier receipt' }, actor: @actor)
  end

  def source_order(quantity: 3)
    { 'id' => 'gid://shopify/Order/76504', 'name' => '=ORDER-CSV', 'createdAt' => @sale_time.iso8601,
      'cancelledAt' => nil, 'displayFinancialStatus' => 'PAID', 'paymentGatewayNames' => ['Card'],
      'currentTotalPriceSet' => { 'shopMoney' => { 'amount' => (quantity * 10).to_s, 'currencyCode' => 'USD' } },
      'lineItems' => { 'pageInfo' => { 'hasNextPage' => false }, 'nodes' => [{
        'id' => 'gid://shopify/LineItem/76505', 'title' => 'Mapped product', 'sku' => @variant.sku,
        'variant' => { 'id' => @variant.id }, 'quantity' => quantity, 'currentQuantity' => quantity,
        'originalUnitPriceSet' => { 'shopMoney' => { 'amount' => '10.00' } },
        'originalTotalSet' => { 'shopMoney' => { 'amount' => (quantity * 10).to_s } }
      }] } }
  end
end
