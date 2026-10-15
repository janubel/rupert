# frozen_string_literal: true

require 'test_helper'

class BulkLedgerTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @material = BulkMaterial.create!(name: 'Dried herb', unit: 'g')
    @actor = 'inventory@example.com'
  end

  teardown { Current.reset }

  test 'mass conversion uses decimal factors and rounds once to integer milligrams' do
    assert_equal 1000, BulkMass.convert('1', 'g').first
    assert_equal 100, BulkMass.convert('0.1', 'g').first
    assert_equal 1_234_567, BulkMass.convert('1.234567', 'kg').first
    assert_equal 28_350, BulkMass.convert('1', 'oz').first
    assert_equal 453_592, BulkMass.convert('1', 'lb').first
    assert_equal 1, BulkMass.convert('0.0005', 'g').first
    assert_equal(-1500, BulkMass.convert('-1.5', 'g', signed: true).first)
    ['0', '-1', 'NaN', '1e3', '0.0001', '99999999999999999999999'].each do |input|
      assert_raises(ArgumentError) { BulkMass.convert(input, 'g') }
    end
    assert_raises(ArgumentError) { BulkMass.convert('1', 'liters') }
  end

  test 'receipt consumption and signed correction retain an exact append-only ledger' do
    lot = receive('2', unit: 'kg')
    assert lot.persisted?, lot.errors.full_messages.to_sentence
    assert_equal 2_000_000, lot.balance_mg
    receipt = lot.bulk_movements.first
    assert_equal 'receipt', receipt.kind
    assert_equal @actor, receipt.created_by
    assert receipt.created_at

    use = record(lot, '250.125', unit: 'g')
    assert use.persisted?, use.errors.full_messages.to_sentence
    assert_equal(-250_125, use.delta_mg)
    correction = record(lot, '-1.125', unit: 'g', kind: 'adjustment', reference: 'Scale correction')
    assert correction.persisted?
    assert_equal 1_748_750, lot.reload.balance_mg
    assert_equal lot.balance_mg, lot.bulk_movements.sum(:delta_mg)
    assert_equal 3, lot.bulk_movements.count
    assert_raises(ActiveRecord::ReadOnlyRecord) { use.update!(reference: 'rewrite') }
    assert_raises(ActiveRecord::ReadOnlyRecord) { use.destroy! }
    assert_equal 'Use order 42', use.reload.reference
    assert_equal 0, InventoryMovement.count
  end

  test 'consumption and corrections cannot make a lot negative and cannot consume another lot' do
    lot = receive('5')
    other_lot = receive('100', code: 'OTHER')
    refused = record(lot, '5.001')
    refute refused.persisted?
    assert_match(/negative/, refused.errors.full_messages.to_sentence)
    assert_equal 5000, lot.reload.balance_mg
    assert_equal 100_000, other_lot.reload.balance_mg
    refused = record(lot, '-5.001', kind: 'adjustment')
    refute refused.persisted?
    assert record(lot, '5').persisted?
    assert_equal 0, lot.reload.balance_mg
    refute record(lot, '0.001').persisted?
  end

  test 'invalid units quantities kinds and missing references do not create stock' do
    lot = receive('bad')
    refute lot.persisted?
    assert_match(/decimal weight/, lot.errors.full_messages.to_sentence)
    assert_equal 0, BulkLot.count
    lot = receive('1', reference: '')
    refute lot.persisted?
    assert_equal 0, BulkMovement.count
    lot = receive('1')
    [['-1', 'g', 'consume'], ['1', 'liters', 'receipt'], ['1', 'g', 'invented'], ['0', 'g', 'adjustment']].each do |quantity, unit, kind|
      movement = record(lot, quantity, unit: unit, kind: kind)
      refute movement.persisted?
      assert movement.errors.any?
    end
    assert_equal 1000, lot.reload.balance_mg
    assert_equal 1, BulkMovement.count
  end

  test 'receipt and movement request replays cannot add or consume stock twice' do
    token = SecureRandom.uuid
    lot = receive('10', receipt_token: token)
    assert_equal lot.id, receive('10', receipt_token: token).id
    changed = receive('11', receipt_token: token)
    refute changed.persisted?
    assert_match(/already used/, changed.errors.full_messages.to_sentence)
    assert_equal 1, BulkLot.count
    assert_equal 1, BulkMovement.count
    movement_token = SecureRandom.uuid
    use = record(lot, '2', request_token: movement_token)
    assert_equal use.id, record(lot, '2.0', request_token: movement_token).id
    changed = record(lot, '3', request_token: movement_token)
    refute changed.persisted?
    assert_match(/already used/, changed.errors.full_messages.to_sentence)
    assert_equal 8000, lot.reload.balance_mg
    assert_equal 2, BulkMovement.count
  end

  test 'a reused movement token cannot create a new receipt or orphan lot' do
    lot = receive('5')
    token = SecureRandom.uuid
    assert record(lot, '1', request_token: token).persisted?
    duplicate = receive('2', code: 'SECOND', receipt_token: token)
    refute duplicate.persisted?
    assert_match(/already used/, duplicate.errors.full_messages.to_sentence)
    assert_equal 1, BulkLot.count
    assert_equal 2, BulkMovement.count
    assert_equal 4000, lot.reload.balance_mg
  end

  test 'duplicate lot codes require an explicit receipt on the existing lot' do
    lot = receive('1')
    duplicate = receive('5')
    refute duplicate.persisted?
    assert_match(/already exists/, duplicate.errors[:code].join)
    assert_equal 1000, lot.reload.balance_mg
    assert record(lot, '2', kind: 'receipt', reference: 'Second delivery').persisted?
    assert_equal 3000, lot.reload.balance_mg
  end

  test 'tenant associations and service calls cannot cross stores' do
    lot = receive('10')
    other = Tenant.create!(name: 'Other bulk store', subdomain: 'other-bulk-store')
    foreign = BulkMaterial.create!(name: 'Foreign herb', unit: 'g', tenant_id: other.id)
    invalid = BulkLot.new(bulk_material: foreign, code: 'FOREIGN', receipt_checked: true)
    refute invalid.valid?
    assert invalid.errors[:bulk_material].any?
    assert_raises(ActiveRecord::RecordNotFound) { receive('1', material: foreign) }
    Current.tenant = other
    assert_raises(ActiveRecord::RecordNotFound) { record(lot, '1') }
    assert_equal 0, BulkLot.count
    Current.tenant = tenants(:default_tenant)
    assert_equal 10_000, lot.reload.balance_mg
  end

  test 'direct creation cannot bypass initial receipt and balance checks' do
    lot = BulkLot.new(bulk_material: @material, code: 'BYPASS', balance_mg: 1000)
    refute lot.save
    assert_match(/ledger service/, lot.errors.full_messages.to_sentence)
    lot = receive('1')
    movement = lot.bulk_movements.new(kind: 'consume', delta_mg: -5000, input_quantity: '5', input_unit: 'g',
      reference: 'bypass', created_by: @actor)
    refute movement.save
    assert_equal 1000, lot.reload.balance_mg
    assert_raises(ActiveRecord::ReadonlyAttributeError) { lot.update!(balance_mg: 0) }
  end

  private

  def receive(quantity, unit: 'g', code: 'LOT-1', material: @material, reference: 'Supplier receipt 1', **attributes)
    BulkLedger.receive(material: material, attributes: { code: code }.merge(attributes),
      movement_attributes: { quantity: quantity, unit: unit, reference: reference }, actor: @actor)
  end

  def record(lot, quantity, unit: 'g', kind: 'consume', reference: 'Use order 42', **attributes)
    BulkLedger.record(lot: lot, attributes: { quantity: quantity, unit: unit, kind: kind, reference: reference }.merge(attributes), actor: @actor)
  end
end
