# frozen_string_literal: true

require 'test_helper'

class BooksPeriodTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @day = Date.current - 3
  end

  teardown { Current.reset }

  def sale(gross: 1000, at: nil)
    order = Core::Order.create!(source: 'square', source_order_id: SecureRandom.uuid, occurred_at: at || Time.zone.parse("#{@day} 12:00"),
      gross_cents: gross, tax_cents: 0, currency: 'USD')
    order.mark_paid!
    order
  end

  def period(kind = 'daily') = BooksPeriod.new(kind: kind, date: @day)

  test 'weeks run Monday to Sunday and only finished periods are complete' do
    week = BooksPeriod.new(kind: 'weekly', date: Date.new(2026, 10, 14))
    assert_equal [Date.new(2026, 10, 12), Date.new(2026, 10, 18)], [week.from, week.to]
    assert period.complete?
    assert_not BooksPeriod.new(kind: 'daily', date: Date.current).complete?
    assert_raises(BooksPeriod::Error) { BooksPeriod.new(kind: 'monthly', date: Date.current) }
    assert_raises(BooksPeriod::Error) { BooksPeriod.new(kind: 'daily', date: 'nope') }
  end

  test 'fingerprint ignores source import timestamps' do
    sale
    before = period.digest
    SyncRun.create!(source: 'all', mode: 'scheduled', status: 'success', startedAt: Time.current, finishedAt: Time.current + 5.seconds)
    assert_equal before, period.digest
  end

  test 'fingerprint changes when sales or money out change' do
    before = period.digest
    sale
    after_sale = period.digest
    assert_not_equal before, after_sale
    Finance::Expense.create!(category: 'supplies', amount: '12.50', incurred_on: @day, method: 'card')
    assert_not_equal after_sale, period.digest
  end

  test 'state moves from pending to approved to changed' do
    sale
    assert_equal :pending, period.state
    BookApproval.record!(period: period, status: 'approved', notes: nil, user: users(:regular_user))
    assert_equal :approved, period.state
    sale(gross: 500)
    assert_equal :changed, period.state
  end

  test 'sales pools stay separate by source and are never added across sources' do
    sale
    order = Core::Order.create!(source: 'shopify', source_order_id: SecureRandom.uuid, occurred_at: Time.zone.parse("#{@day} 13:00"),
      gross_cents: 700, tax_cents: 0, currency: 'USD')
    order.mark_paid!
    assert_equal %w[shopify square], period.pools.map { |p| p[:source] }
  end
end
