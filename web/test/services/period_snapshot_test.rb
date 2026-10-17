# frozen_string_literal: true

require 'test_helper'

class PeriodSnapshotTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  test 'payment and refund snapshots keep sources and currencies separate' do
    day = Date.current - 50
    at = Time.zone.local(day.year, day.month, day.day, 12)
    %w[USD CAD].each do |currency|
      order = Core::Order.create!(source: 'square', source_order_id: SecureRandom.uuid,
        occurred_at: at, gross_cents: 1000, tax_cents: 0, currency: currency)
      Core::Payment.create!(order: order, method: 'cash', amount_cents: 1000, paid_at: at, status: 'completed')
      Core::Refund.create!(order: order, method: 'cash', amount_cents: 100, refunded_at: at)
    end
    totals = PeriodSnapshot.new(from: day, to: day).totals
    assert_equal [%w[square CAD completed 1 1000], %w[square USD completed 1 1000]], totals['payments']
    assert_equal [%w[square CAD cash 1 100], %w[square USD cash 1 100]], totals['refunds']
  end
end
