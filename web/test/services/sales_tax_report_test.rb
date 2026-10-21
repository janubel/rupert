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

  test 'includes Rupert POS orders and names stores by their source location ID' do
    Location.create!(source: 'square', externalId: 'sq-main', name: 'Main Street', tenant_id: Current.tenant.id)
    record = Core::Order.new(source: 'square', source_order_id: SecureRandom.uuid, occurred_at: Time.zone.parse('2026-10-08 12:00'),
      gross_cents: 1100, tax_cents: 100, currency: 'USD', location_id: 'sq-main')
    record.aasm.current_state = :paid
    record.save!
    order('2026-10-08', source: 'rupert_pos', gross: 2140, tax: 140)
    lines = SalesTaxReport.new(from: Date.new(2026, 10, 8), to: Date.new(2026, 10, 8)).lines
    assert_equal 'Main Street', lines.find { |line| line.source == 'Square' }.store
    assert_equal 140, lines.find { |line| line.source == 'Rupert POS' }.tax_collected
  end

  test 'filters to the chosen sources and ignores unknown ones' do
    order('2026-10-08')
    order('2026-10-08', source: 'square', gross: 550, tax: 50)
    report = SalesTaxReport.new(from: Date.new(2026, 10, 8), to: Date.new(2026, 10, 8), sources: %w[square bogus])
    assert_equal ['square'], report.sources
    assert_equal ['Square'], report.lines.map(&:source)
    assert_equal SalesTaxReport::SOURCES.keys, SalesTaxReport.new(from: Date.new(2026, 10, 8), to: Date.new(2026, 10, 8), sources: ['bogus']).sources
  end

  test 'estimates tax only where the source reports none, never replacing reported tax' do
    order('2026-10-08')
    bytes = "Transaction #,Date,Type,Amount,Result,Method\n"
    export = SwipesimpleExport.create!(merchant_account: 'Card shop', currency: 'USD', source_timezone: 'America/New_York', kind: 'transactions',
      fingerprint: 'tax-estimate', sha256: Digest::SHA256.hexdigest(bytes), exported_at: Time.zone.parse('2026-10-09 09:00'), original_csv: bytes)
    [['Sale', 10_600, 1], ['Sale', 5_300, 2], ['Refund', 5_300, 3]].each do |type, cents, row|
      SwipesimpleReportRow.create!(swipesimple_export: export, identity: "tx-#{row}", source_number: "T#{row}", transaction_type: type,
        status: 'Approved', amount_cents: cents, tip_cents: 0, occurred_at: Time.zone.parse('2026-10-08 15:00'), source_row: row)
    end
    report = SalesTaxReport.new(from: Date.new(2026, 10, 8), to: Date.new(2026, 10, 8), rate: '6')
    swipe = report.lines.find { |line| line.source == 'SwipeSimple' }
    shopify = report.lines.find { |line| line.source == 'Shopify' }
    assert_nil swipe.tax_collected
    assert_equal 15_900, swipe.gross_sales
    assert_equal 600, swipe.estimated_tax, '10,600 net of the refund is 10,000 before 6% tax'
    assert_equal 100, shopify.tax_collected
    assert_nil shopify.estimated_tax
    assert_includes report.csv, 'Estimated tax cents'
    assert_nil SalesTaxReport.new(from: Date.new(2026, 10, 8), to: Date.new(2026, 10, 8)).lines.find { |line| line.source == 'SwipeSimple' }.estimated_tax
  end

  test 'rejects an impossible tax rate' do
    %w[0 -1 31 abc].each do |rate|
      assert_raises(SalesTaxReport::Error, rate) { SalesTaxReport.new(from: Date.new(2026, 10, 8), to: Date.new(2026, 10, 8), rate: rate) }
    end
  end
end
