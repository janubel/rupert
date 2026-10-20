# frozen_string_literal: true

require 'test_helper'

class SalesTaxReportTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  def order(day, source: 'shopify', gross: 1100, tax: 100)
    record = Core::Order.new(source: source, source_order_id: SecureRandom.uuid, occurred_at: Time.zone.parse("#{day} 12:00"), gross_cents: gross, tax_cents: tax, currency: 'USD')
    record.aasm.current_state = :paid
    record.save!
  end

  test 'sums tax per source over a custom date range and keeps sources apart' do
    order('2026-10-08')
    order('2026-10-14', gross: 2200, tax: 200)
    order('2026-10-15')
    order('2026-10-10', source: 'square', gross: 550, tax: 50)
    lines = SalesTaxReport.new(from: Date.new(2026, 10, 8), to: Date.new(2026, 10, 14)).lines
    shopify = lines.find { |line| line.source == 'Shopify' }
    square = lines.find { |line| line.source == 'Square' }
    assert_equal [2, 300, 3000], [shopify.orders, shopify.tax_collected, shopify.sales_before_tax]
    assert_equal 50, square.tax_collected
    assert_nil shopify.tax_refunded
  end

  test 'rejects a backwards or oversized range' do
    assert_raises(SalesTaxReport::Error) { SalesTaxReport.new(from: Date.new(2026, 10, 9), to: Date.new(2026, 10, 8)) }
    assert_raises(SalesTaxReport::Error) { SalesTaxReport.new(from: Date.new(2024, 1, 1), to: Date.new(2026, 1, 1)) }
  end

  test 'csv marks unknown amounts unavailable' do
    order('2026-10-08')
    csv = SalesTaxReport.new(from: Date.new(2026, 10, 8), to: Date.new(2026, 10, 8)).csv
    assert_includes csv, 'Unavailable'
    assert_includes csv, 'Shopify'
  end
end
