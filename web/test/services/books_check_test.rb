# frozen_string_literal: true

require 'test_helper'

class BooksCheckTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
  end

  teardown { Current.tenant = nil }

  def order!(source: 'square', number: 'o1', gross: 1000, tax: 80, status: :paid, location: 'loc1', at: 1.hour.ago)
    order = Core::Order.new(source: source, source_order_id: "#{source}-#{number}", order_number: number, channel: 'pos',
      gross_cents: gross, tax_cents: tax, occurred_at: at, tenant_id: @tenant.id, location_id: location)
    order.mark_paid! if %i[paid refunded].include?(status)
    order.refund! if status == :refunded
    order.save!
    order
  end

  def pay!(order, cents)
    order.payments.create!(tenant_id: @tenant.id, method: 'card', amount_cents: cents, status: 'completed', paid_at: order.occurred_at)
  end

  def result(key)
    BooksCheck.new.checks.find { |c| c.key == key }
  end

  test 'paid order without payment is flagged with its amount' do
    order!(number: 'nopay', gross: 2500)
    check = result('paid_without_payment')
    assert_equal :fix, check.status
    assert_equal 1, check.count
    assert_equal 2500, check.cents
  end

  test 'paid order with matching payment passes both payment checks' do
    pay!(order!, 1000)
    assert result('paid_without_payment').ok?
    assert result('payment_mismatch').ok?
  end

  test 'payment that differs from the order total is a mismatch' do
    pay!(order!(gross: 1000), 1200)
    check = result('payment_mismatch')
    assert_equal 1, check.count
    assert_equal 200, check.cents
  end

  test 'refunded order without a refund record is flagged until one is recorded' do
    refunded = order!(number: 'ref', gross: 6360, status: :refunded)
    assert_equal 1, result('refund_records').count
    refunded.refunds.create!(tenant_id: @tenant.id, amount_cents: 6360, method: 'card', refunded_at: Time.current)
    assert result('refund_records').ok?
  end

  test 'orders without a location are a watch item' do
    order!(location: nil)
    check = result('orders_without_location')
    assert_equal :watch, check.status
    assert_equal 1, check.count
  end

  test 'stale source is a watch item' do
    order!(source: 'shopify', number: 'old', at: 10.days.ago)
    check = result('source_freshness')
    assert_equal :watch, check.status
    assert_includes check.detail, 'shopify'
  end

  test 'tax above order total is impossible' do
    order!(gross: 100, tax: 500)
    assert_equal 1, result('impossible_amounts').count
  end

  test 'csv neutralises formula cells and lists every check' do
    order!(number: '=1+1', gross: 500)
    csv = BooksCheck.new.csv
    assert_includes csv, "'=1+1"
    BooksCheck.new.checks.each { |c| assert_includes csv, c.title }
  end

  test 'verdict is fix when any check needs fixing' do
    order!(number: 'nopay')
    assert_equal :fix, BooksCheck.new.verdict
  end
end
