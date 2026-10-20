# frozen_string_literal: true

require 'test_helper'

class DailyCloseSummaryTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  test 'store rows give gross after discounts before tax, net, tax, tips, cash and credit' do
    order = Core::Order.new(source: 'shopify', source_order_id: SecureRandom.uuid, occurred_at: Time.zone.parse('2026-10-14 12:00'),
      gross_cents: 1100, tax_cents: 100, tip_cents: 150, currency: 'USD')
    order.aasm.current_state = :paid
    order.save!
    order.payments.create!(method: 'cash', amount_cents: 400, status: 'completed', paid_at: order.occurred_at)
    order.payments.create!(method: 'card', amount_cents: 700, status: 'completed', paid_at: order.occurred_at)
    row = DailyCloseSummary.new(day: '2026-10-14').store_rows.first
    assert_equal [1000, 0, 1000, 100, 150, 400, 700], [row.gross, row.refunds, row.net, row.tax, row.tips, row.cash, row.credit]
  end

  test 'no data gives an empty summary rather than zeros' do
    assert_predicate DailyCloseSummary.new(day: '2026-10-14'), :empty?
  end
end
