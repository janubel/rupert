# frozen_string_literal: true

require 'test_helper'

class ReconciliationAttentionTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  test 'missing controls are exact source currency location pools and exclude corrected or withdrawn controls' do
    rows = [{ source: 'square', currency: 'USD', location_id: nil }, { source: 'square', currency: 'EUR', location_id: nil }, { source: 'square', currency: 'USD', location_id: 'store-b' }]
    report = stub(register: stub(rows: rows), comparisons: [], controls: [])
    assert_equal 3, ReconciliationAttention.new(report).missing_controls.size
    control = ReconciliationEvidence.retain!(bytes: 'test', filename: 'report.txt', source: 'square', kind: 'register_control',
      from: '2026-10-14', to: '2026-10-14', metadata: { 'currency' => 'USD', 'cash' => 0 })
    report.stubs(:controls).returns([control])
    assert_equal rows.last(2), ReconciliationAttention.new(report).missing_controls
  end

  test 'attention groups currencies without summing and ranks known differences within each currency' do
    values = [['EUR', 5], ['EUR', nil], ['USD', -10], ['USD', 500], ['USD', nil]].map do |currency, delta|
      { currency: currency, source: 'square', metric: 'card', delta_cents: delta, status: delta ? 'Variance' : 'Unavailable in canonical records' }
    end
    report = stub(comparisons: values + [{ status: 'Matched recorded total' }], register: stub(rows: []))
    attention = ReconciliationAttention.new(report)
    assert_equal [5, 500, -10, nil, nil], attention.differences.map { |row| row[:delta_cents] }
    assert_equal({ variances: 3, unavailable: 2, conflicts: 0, missing_controls: 0 }, attention.counts)
  end
end
