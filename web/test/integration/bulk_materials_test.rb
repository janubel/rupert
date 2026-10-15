# frozen_string_literal: true

require 'test_helper'

class BulkMaterialsTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @material = BulkMaterial.create!(name: 'Bulk peppermint', unit: 'g')
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  test 'operator creates material receives a lot uses stock and records correction' do
    get new_bulk_material_path
    assert_response :success
    post bulk_materials_path, params: { bulk_material: { name: 'Chamomile', unit: 'kg' } }
    material = BulkMaterial.find_by!(name: 'Chamomile')
    assert_redirected_to bulk_material_path(material)
    get new_bulk_material_bulk_lot_path(material)
    assert_response :success
    token = css_select("input[name='bulk_lot[receipt_token]']").first['value']
    payload = { bulk_lot: { code: 'BATCH-42', quantity: '1', unit: 'kg', reference: 'Supplier delivery 42', receipt_token: token } }
    post bulk_material_bulk_lots_path(material), params: payload
    lot = BulkLot.last
    assert_redirected_to bulk_material_bulk_lot_path(material, lot)
    assert_equal 1_000_000, lot.balance_mg
    post bulk_material_bulk_lots_path(material), params: payload
    assert_equal 1, BulkLot.count
    assert_equal 1, BulkMovement.count

    get bulk_material_bulk_lot_path(material, lot)
    assert_response :success
    assert_select 'h1', 'Lot BATCH-42'
    assert_select 'td', 'Supplier delivery 42'
    movement_token = css_select("input[name='bulk_movement[request_token]']").first['value']
    use = { bulk_movement: { kind: 'consume', quantity: '250', unit: 'g', reference: 'Packaging run 42', request_token: movement_token } }
    post bulk_material_bulk_lot_bulk_movements_path(material, lot), params: use
    assert_redirected_to bulk_material_bulk_lot_path(material, lot)
    assert_equal 750_000, lot.reload.balance_mg
    post bulk_material_bulk_lot_bulk_movements_path(material, lot), params: use
    assert_equal 750_000, lot.reload.balance_mg
    assert_equal 2, BulkMovement.count

    post bulk_material_bulk_lot_bulk_movements_path(material, lot), params: { bulk_movement: {
      kind: 'adjustment', quantity: '-0.5', unit: 'g', reference: 'Spillage correction', request_token: SecureRandom.uuid
    } }
    assert_equal 749_500, lot.reload.balance_mg
    get bulk_materials_path
    assert_response :success
    assert_select 'td', 'Chamomile'
    assert_select 'td', /749,500 mg/
    get bulk_material_path(material)
    assert_response :success
    assert_select 'td', 'BATCH-42'
  end

  test 'invalid receipt and overconsumption render errors and keep replay tokens' do
    token = SecureRandom.uuid
    post bulk_material_bulk_lots_path(@material), params: { bulk_lot: { code: 'ERROR', quantity: '1', unit: 'liters', reference: 'Invoice', receipt_token: token } }
    assert_response :unprocessable_entity
    assert_select '[role=alert]', /supported mass unit/
    assert_select "input[name='bulk_lot[receipt_token]'][value='#{token}']"
    assert_equal 0, BulkLot.count

    lot = receive
    movement_token = SecureRandom.uuid
    post bulk_material_bulk_lot_bulk_movements_path(@material, lot), params: { bulk_movement: {
      kind: 'consume', quantity: '2', unit: 'kg', reference: 'Too much', request_token: movement_token
    } }
    assert_response :unprocessable_entity
    assert_select '[role=alert]', /negative/
    assert_select "input[name='bulk_movement[request_token]'][value='#{movement_token}']"
    assert_equal 1000, lot.reload.balance_mg
    assert_equal 1, BulkMovement.count
  end

  test 'readers can inspect ledger but write-only overrides cannot expose stock' do
    lot = receive
    employee = User.create!(email: 'bulk-reader@example.com', password: 'password123', role: 'reader', tenant: tenants(:default_tenant))
    delete logout_path
    post login_path, params: { email: employee.email, password: 'password123' }
    get bulk_material_bulk_lot_path(@material, lot)
    assert_response :success
    assert_select "input[name='bulk_movement[quantity]']", count: 0
    get export_bulk_materials_path
    assert_response :success
    get new_bulk_material_path
    assert_response :redirect
    post bulk_material_bulk_lot_bulk_movements_path(@material, lot), params: { bulk_movement: { kind: 'consume', quantity: '1', unit: 'g', reference: 'Denied', request_token: SecureRandom.uuid } }
    assert_response :redirect
    Current.tenant = tenants(:default_tenant)
    assert_equal 1000, lot.reload.balance_mg

    employee.update_permission_overrides!(['inventory.write'])
    get bulk_material_bulk_lot_path(@material, lot)
    assert_response :redirect
    get new_bulk_material_bulk_lot_path(@material)
    assert_response :redirect
    get bulk_materials_path
    assert_response :redirect
    get export_bulk_materials_path
    assert_response :redirect
  end

  test 'CSV exports only this store ledger and keeps spreadsheet text inert' do
    lot = receive
    BulkLedger.record(lot: lot, attributes: { kind: 'consume', quantity: '0.1', unit: 'g',
      reference: '=HYPERLINK("https://example.com")' }, actor: 'admin@example.com')
    other = Tenant.create!(name: 'Export other', subdomain: 'bulk-export-other')
    Current.tenant = other
    material = BulkMaterial.create!(name: 'Secret export material', unit: 'g')
    BulkLedger.receive(material: material, attributes: { code: 'SECRET' },
      movement_attributes: { quantity: '1', unit: 'g', reference: 'Secret reference' }, actor: 'other@example.com')
    get export_bulk_materials_path
    assert_response :success
    assert_equal 'text/csv', response.media_type
    rows = CSV.parse(response.body, headers: true)
    assert_equal 2, rows.size
    assert_equal 2, rows.map { |row| row['movement_id'] }.uniq.size
    assert_match(/\.\d{6}Z\z/, rows[0]['recorded_at_utc'])
    assert_equal %w[1000 -100], rows.map { |row| row['change_mg'] }
    assert_equal ['900'], rows.map { |row| row['current_lot_balance_mg'] }.uniq
    assert_equal "'=HYPERLINK(\"https://example.com\")", rows[-1]['reference']
    refute_includes response.body, 'Secret export material'
    refute_includes response.body, 'Secret reference'
  end

  test 'foreign and mismatched material lot paths are inaccessible' do
    lot = receive
    other_material = BulkMaterial.create!(name: 'Another material', unit: 'g')
    get bulk_material_bulk_lot_path(other_material, lot)
    assert_response :not_found
    other = Tenant.create!(name: 'Other bulk tenant', subdomain: 'other-bulk-tenant')
    Current.tenant = other
    foreign_material = BulkMaterial.create!(name: 'Secret bulk', unit: 'g')
    foreign_lot = BulkLedger.receive(material: foreign_material, attributes: { code: 'SECRET' },
      movement_attributes: { quantity: '10', unit: 'g', reference: 'Secret supplier' }, actor: 'other@example.com')
    get bulk_materials_path
    assert_response :success
    assert_select 'td', text: 'Secret bulk', count: 0
    get bulk_material_path(foreign_material)
    assert_response :not_found
    post bulk_material_bulk_lot_bulk_movements_path(foreign_material, foreign_lot), params: { bulk_movement: {
      kind: 'consume', quantity: '1', unit: 'g', reference: 'Denied', request_token: SecureRandom.uuid
    } }
    assert_response :not_found
  end

  private

  def receive
    Current.tenant = tenants(:default_tenant)
    BulkLedger.receive(material: @material, attributes: { code: 'LOT-UI' },
      movement_attributes: { quantity: '1', unit: 'g', reference: 'Invoice UI' }, actor: 'admin@example.com')
  end
end
