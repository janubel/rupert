# frozen_string_literal: true

require 'test_helper'
require 'csv'
require 'stringio'

class SwipesimpleImporterTest < ActiveSupport::TestCase
  BASE_ROW = {
    'Order' => 'transaction-1', 'Date' => '2026-07-01T14:30:00-04:00', 'Item' => 'Tea', 'SKU' => 'TEA',
    'Qty' => '2', 'Unit Price' => '12.35', 'Total' => '24.70', 'Payment' => 'Card',
    'Status' => 'Completed', 'Currency' => 'USD', 'Customer' => 'Private Buyer'
  }.freeze

  setup do
    @tenant = Tenant.create!(name: 'CSV Import Workspace', subdomain: 'csv-import-workspace')
    Current.tenant = @tenant
  end

  teardown do
    Current.reset
  end

  test 'preview validates canonical order lines and returns safe aggregates without writing records' do
    source = csv_for([{}, { 'Order' => 'transaction-2', 'Item' => 'Oil', 'SKU' => 'OIL', 'Qty' => '1',
                           'Unit Price' => '9.99', 'Total' => '9.99', 'Payment' => 'Cash' }])
    before = record_counts
    preview = SwipesimpleImporter.preview(source)

    assert_equal before, record_counts
    assert_equal 2, preview.summary[:orders]
    assert_equal 2, preview.summary[:lines]
    assert_equal 2, preview.summary[:payments]
    assert_equal 3469, preview.summary[:gross_cents]
    assert_equal 'USD', preview.summary[:currency]
    assert_equal Digest::SHA256.hexdigest(source.b), preview.fingerprint
    assert_includes preview.summary[:warnings].join(' '), 'Customer identities are not imported'
    refute_includes preview.to_h.to_json, 'Private Buyer'
    refute_includes preview.to_h.to_json, 'transaction-1'
    assert_equal Time.utc(2026, 7, 1, 18, 30), preview.records.first[:occurred_at]
    assert_raises(FrozenError) { preview.records.first[:gross_cents] = 1 }
  end

  test 'imports all validated rows atomically into tenant-scoped orders payments and ledger without creating customers' do
    source = csv_for([{}, { 'Item' => 'Oil', 'SKU' => 'OIL', 'Qty' => '1', 'Unit Price' => '$9.99', 'Total' => '$9.99' }])
    preview = SwipesimpleImporter.preview(source)
    result = SwipesimpleImporter.import!(source, expected_fingerprint: preview.fingerprint)

    assert_equal({ orders: 1, lines: 2, payments: 1, skipped_rows: 0, unchanged_orders: 0 }, result.to_h)
    order = Core::Order.find_by!(source: 'swipesimple', source_order_id: 'transaction-1')
    assert_equal 'paid', order.status
    assert_equal 3469, order.gross_cents
    assert_nil order.tax_cents
    assert_nil order.customer_id
    assert_equal 0, Core::Customer.where(source: 'swipesimple').count
    assert_equal 2, order.order_lines.count
    assert_equal 1, order.payments.count
    assert_equal 3469, order.payments.first.amount_cents
    assert_equal 'card', order.payments.first.method
    assert_equal Time.utc(2026, 7, 1, 18, 30), order.payments.first.paid_at
    ledger = LedgerEntry.find_by!(source: 'swipesimple', sourceOrderId: 'transaction-1')
    assert_equal @tenant.id, ledger.tenant_id
    assert_match(/\Aswipesimple:[0-9a-f]{64}\z/, ledger.id)
    refute_equal 'swipesimple:transaction-1', ledger.id
    assert_equal 3, ledger.lineItems
  end

  test 'identical replay is a no-op including child IDs timestamps and ledger sync time' do
    source = csv_for
    SwipesimpleImporter.import!(source)
    before = snapshots
    travel 1.hour do
      result = SwipesimpleImporter.import!(source)
      assert_equal 1, result.unchanged_orders
      assert_equal 0, result.orders
      assert_equal 0, result.lines
      assert_equal 0, result.payments
    end
    assert_equal before, snapshots
  end

  test 'changed replay rejects the entire file and preserves existing rows and unrelated new orders' do
    SwipesimpleImporter.import!(csv_for)
    before = snapshots
    changed = csv_for([{ 'Order' => 'new-transaction' }, { 'Qty' => '3', 'Total' => '37.05' }])

    error = assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.import!(changed) }
    assert_includes error.message, 'existing transaction differs'
    refute_includes error.message, 'transaction-1'
    assert_equal before, snapshots
    refute Core::Order.exists?(source: 'swipesimple', source_order_id: 'new-transaction')
  end

  test 'refund history prevents even an otherwise matching replay from changing the order' do
    source = csv_for
    SwipesimpleImporter.import!(source)
    order = Core::Order.find_by!(source: 'swipesimple')
    order.record_refund!(amount_cents: 100, reference: 'refund-1')
    before = snapshots

    assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.import!(source) }
    assert_equal before, snapshots
    assert_equal 100, order.refunds.sum(:amount_cents)
  end

  test 'missing or altered payment and ledger records cause conflicts instead of being silently repaired' do
    source = csv_for
    SwipesimpleImporter.import!(source)
    payment = Core::Payment.find_by!(reference: 'transaction-1')
    payment.update!(amount_cents: 50)
    assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.import!(source) }
    assert_equal 50, payment.reload.amount_cents
    payment.update!(amount_cents: 2470)
    ledger = LedgerEntry.find_by!(source: 'swipesimple')
    ledger.update!(grossCents: 50)
    assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.import!(source) }
    assert_equal 50, ledger.reload.grossCents
    ledger.destroy!
    assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.import!(source) }
    assert_equal 0, LedgerEntry.where(source: 'swipesimple').count
  end

  test 'same external IDs in different tenants never collide or overwrite ledger entries' do
    source = csv_for
    SwipesimpleImporter.import!(source)
    first_ledger = LedgerEntry.find_by!(source: 'swipesimple').attributes
    other = Tenant.create!(name: 'Other CSV Workspace', subdomain: 'other-csv-workspace')
    Current.tenant = other
    SwipesimpleImporter.import!(csv_for([{ 'Unit Price' => '5.00', 'Total' => '10.00' }]))

    assert_equal 2, Core::Order.unscoped.where(source: 'swipesimple', source_order_id: 'transaction-1').count
    ledgers = LedgerEntry.unscoped.where(source: 'swipesimple', sourceOrderId: 'transaction-1')
    assert_equal 2, ledgers.count
    assert_equal 2, ledgers.pluck(:id).uniq.length
    assert_equal first_ledger, LedgerEntry.unscoped.find(first_ledger['id']).attributes
    assert_equal 1000, LedgerEntry.find_by!(source: 'swipesimple').grossCents
  end

  test 'same-tenant legacy global ledger identities are preserved and require review' do
    ledger = LedgerEntry.create!(id: 'swipesimple:transaction-1', source: 'swipesimple', sourceOrderId: 'transaction-1',
      orderName: 'Legacy', occurredAt: Time.current, syncedAt: Time.current, grossCents: 50, currency: 'USD',
      status: 'COMPLETED', lineItems: 1)
    before = ledger.attributes

    assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.import!(csv_for) }
    assert_equal before, ledger.reload.attributes
    assert_equal 0, Core::Order.where(source: 'swipesimple').count
  end

  test 'a different tenant legacy global ledger identity is never touched' do
    other = Tenant.create!(name: 'Legacy CSV Workspace', subdomain: 'legacy-csv-workspace')
    ledger = LedgerEntry.create!(tenant_id: other.id, id: 'swipesimple:transaction-1', source: 'swipesimple',
      sourceOrderId: 'transaction-1', orderName: 'Legacy', occurredAt: Time.current, syncedAt: Time.current,
      grossCents: 50, currency: 'USD', status: 'COMPLETED', lineItems: 1)
    before = ledger.attributes

    SwipesimpleImporter.import!(csv_for)
    assert_equal before, LedgerEntry.unscoped.find(ledger.id).attributes
    assert_equal 1, LedgerEntry.where(source: 'swipesimple').count
  end

  test 'invalid rows anywhere prevent all business writes' do
    before = record_counts
    source = csv_for([{}, { 'Order' => 'bad-order', 'Date' => 'private bad date' }])
    error = assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.import!(source) }

    assert_equal before, record_counts
    assert_includes error.message, 'Row 3'
    refute_includes error.message, 'private bad date'
  end

  test 'requires stable identities explicit statuses currencies and supported headers' do
    ['Order', 'Status', 'Currency', 'Date', 'Item', 'Qty', 'Unit Price', 'Payment'].each do |missing|
      source = csv_for(headers: BASE_ROW.keys - [missing])
      assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview(source) }
    end
    assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview(csv_for([{ 'Order' => '' }])) }
    ['Name', 'Tax', 'Tip', 'Fee', 'Unknown Private Header'].each do |extra|
      error = assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview(csv_for(headers: BASE_ROW.keys + [extra])) }
      refute_includes error.message, extra
    end
    assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview(csv_for(headers: BASE_ROW.keys + ['Price'])) }
    assert_equal 0, Core::Order.where(source: 'swipesimple').count
  end

  test 'accepts unambiguous aliases and optional order totals without changing line prices' do
    source = CSV.generate do |csv|
      csv << ['Transaction ID', 'Paid At', 'Product Name', 'Item SKU', 'Units', 'Price', 'Line Total',
              'Tender Type', 'Result', 'Currency Code', 'Order Number', 'Order Total', 'Type']
      csv << ['alias-1', '2026-07-01T18:30:00Z', 'Tea', 'TEA', 2, '12.35', '24.70', 'Credit Card', 'Approved', 'USD', 'SALE-1', '34.69', 'Sale']
      csv << ['alias-1', '2026-07-01T18:30:00Z', 'Oil', 'OIL', 1, '9.99', '9.99', 'Visa', 'Approved', 'USD', '', '', 'Sale']
    end
    result = SwipesimpleImporter.import!(source)
    assert_equal 1, result.orders
    assert_equal 'SALE-1', Core::Order.find_by!(source_order_id: 'alias-1').order_number
    assert_equal 3469, Core::Payment.find_by!(reference: 'alias-1').amount_cents
  end

  test 'unsupported status types unknown tenders split tenders and locations fail closed' do
    %w[Declined Pending Voided Refunded Failed Authorized unknown].each do |status|
      assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview(csv_for([{ 'Status' => status }])) }
    end
    %w[Refund Void Authorization Credit].each do |type|
      source = csv_for([{ 'Type' => type }], headers: BASE_ROW.keys + ['Type'])
      assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview(source) }
    end
    ['ACH', '', 'private tender', 'Cash+Card'].each do |payment|
      assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview(csv_for([{ 'Payment' => payment }])) }
    end
    mixed = csv_for([{}, { 'Item' => 'Oil', 'SKU' => 'OIL', 'Payment' => 'Cash' }])
    assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview(mixed) }
    location = csv_for([{ 'Location' => 'private location' }], headers: BASE_ROW.keys + ['Location'])
    error = assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview(location) }
    refute_includes error.message, 'private location'
  end

  test 'rejects duplicate ambiguous rows and conflicting order details totals and currencies' do
    assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview(csv_for([{}, {}])) }
    assert_raises(SwipesimpleImporter::Error) do
      SwipesimpleImporter.preview(csv_for([{}, { 'Item' => 'Oil', 'Date' => '2026-07-02T18:30:00Z' }]))
    end
    assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview(csv_for([{ 'Total' => '1.00' }])) }
    bad_total = csv_for([{ 'Order Total' => '100.00' }], headers: BASE_ROW.keys + ['Order Total'])
    assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview(bad_total) }
    assert_raises(SwipesimpleImporter::Error) do
      SwipesimpleImporter.preview(csv_for([{}, { 'Order' => 'transaction-2', 'Currency' => 'CAD' }]))
    end
  end

  test 'money quantities and timestamps reject coercion missing values overflows and invalid dates' do
    ['NaN', 'Infinity', '1.001', '-1', '12garbage', '', '1,23.45', '21474836.48'].each do |money|
      error = assert_raises(SwipesimpleImporter::Error) do
        SwipesimpleImporter.preview(csv_for([{ 'Unit Price' => money, 'Total' => money }]))
      end
      refute_includes error.message, money unless money.empty?
    end
    ['0', '-1', '1.5', '1x', '', '1000001'].each do |quantity|
      assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview(csv_for([{ 'Qty' => quantity }])) }
    end
    ['2026-07-01', '07/01/2026', 'today', '2026-02-30T12:00:00Z', '2026-07-01T12:00:00',
     '2026-07-01T24:00:00Z', '2026-07-01T12:00:00-00:00', '2026-07-01T12:00:00+15:00'].each do |date|
      assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview(csv_for([{ 'Date' => date }])) }
    end
  end

  test 'aggregate order quantities respect the integer limit on both database adapters' do
    rows = Array.new(2148) do |i|
      { 'Item' => "Free item #{i}", 'SKU' => "FREE-#{i}", 'Qty' => '1000000', 'Unit Price' => '0', 'Total' => '0' }
    end
    rows << { 'Item' => 'Paid item', 'SKU' => 'PAID', 'Qty' => '1', 'Unit Price' => '1.00', 'Total' => '1.00' }
    error = assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview(csv_for(rows)) }
    assert_includes error.message, 'aggregate order quantity'
    assert_equal 0, Core::Order.where(source: 'swipesimple').count
  end

  test 'requires supported two-decimal currencies without currency scale guessing' do
    %w[JPY KWD ABC usd].each do |currency|
      assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview(csv_for([{ 'Currency' => currency }])) }
    end
    SwipesimpleImporter::SUPPORTED_CURRENCIES.each do |currency|
      assert_equal currency, SwipesimpleImporter.preview(csv_for([{ 'Currency' => currency }])).summary[:currency]
    end
  end

  test 'bounded IO UTF8 BOM blank rows and file row limits are enforced before import' do
    source = csv_for
    io = mock('bounded csv io')
    io.expects(:read).with(SwipesimpleImporter::MAX_BYTES + 1).returns("\uFEFF#{source}")
    assert_equal 1, SwipesimpleImporter.preview(io).summary[:orders]
    assert_equal 1, SwipesimpleImporter.preview(source + ",,,,,,,,,,,\n").summary[:skipped_rows]
    assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview('x' * (SwipesimpleImporter::MAX_BYTES + 1)) }
    assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview("\xFF".b + source.b) }
    assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview(source + "\x00") }
    assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview((['Column'] * 33).join(',') + "\n") }
    oversized = csv_for(Array.new(SwipesimpleImporter::MAX_ROWS + 1) { |i| { 'Order' => "order-#{i}" } })
    assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview(oversized) }
    assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.preview("Order,Date\n\"bad private quote") }
  end

  test 'preview fingerprint mismatch does not write business data' do
    before = record_counts
    assert_raises(SwipesimpleImporter::Error) do
      SwipesimpleImporter.import!(csv_for, expected_fingerprint: Digest::SHA256.hexdigest('different source'))
    end
    assert_equal before, record_counts
  end

  test 'transaction block runs before commit and failure rolls back all business rows' do
    before = record_counts
    observed = nil
    assert_raises(SwipesimpleImporter::Error) do
      SwipesimpleImporter.import!(csv_for) do |summary|
        observed = summary
        assert_equal 1, Core::Order.where(source: 'swipesimple').count
        raise ActiveRecord::Rollback
      end
    end
    assert_equal 1, observed.orders
    assert_equal before, record_counts
  end

  test 'database failure while creating ledger rolls back order lines and payments with a fixed error' do
    LedgerEntry.expects(:create!).raises(ActiveRecord::RecordInvalid.new(LedgerEntry.new))
    before = record_counts
    error = assert_raises(SwipesimpleImporter::Error) { SwipesimpleImporter.import!(csv_for) }
    assert_includes error.message, 'Nothing was imported'
    assert_nil error.cause
    assert_equal before, record_counts
  end

  private

  def csv_for(rows = [{}], headers: BASE_ROW.keys)
    CSV.generate do |csv|
      csv << headers
      rows.each do |overrides|
        values = BASE_ROW.merge(overrides)
        csv << headers.map { |header| values[header] }
      end
    end
  end

  def record_counts
    [Core::Order.count, Core::OrderLine.count, Core::Payment.count, Core::Customer.count, LedgerEntry.count]
  end

  def snapshots
    {
      orders: Core::Order.order(:id).map(&:attributes), lines: Core::OrderLine.order(:id).map(&:attributes),
      payments: Core::Payment.order(:id).map(&:attributes), ledgers: LedgerEntry.order(:id).map(&:attributes)
    }
  end
end

class SwipesimpleImporterConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test 'simultaneous identical imports create one order and preserve one unchanged replay' do
    tenant = Tenant.create!(name: 'CSV import race', subdomain: "csv-import-race-#{SecureRandom.hex(4)}")
    source = CSV.generate do |csv|
      csv << SwipesimpleImporterTest::BASE_ROW.keys
      csv << SwipesimpleImporterTest::BASE_ROW.values
    end
    ready = Queue.new
    start = Queue.new
    outcomes = Queue.new
    threads = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Current.tenant = tenant
          ready << true
          start.pop
          outcomes << SwipesimpleImporter.import!(source)
        ensure
          Current.reset
        end
      rescue StandardError => error
        outcomes << error
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each { |thread| assert thread.join(15), 'concurrent CSV import timed out' }
    results = Array.new(2) { outcomes.pop }
    results.each { |result| refute_kind_of Exception, result, result.inspect }
    assert_equal [0, 1], results.map(&:orders).sort
    assert_equal [0, 1], results.map(&:unchanged_orders).sort
    Current.tenant = tenant
    assert_equal 1, Core::Order.where(source: 'swipesimple').count
    assert_equal 1, Core::Payment.count
    assert_equal 1, Core::OrderLine.count
    assert_equal 1, LedgerEntry.where(source: 'swipesimple').count
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    if tenant
      Core::Payment.unscoped.where(tenant_id: tenant.id).delete_all
      Core::OrderLine.unscoped.where(tenant_id: tenant.id).delete_all
      Core::Order.unscoped.where(tenant_id: tenant.id).delete_all
      LedgerEntry.unscoped.where(tenant_id: tenant.id).delete_all
      tenant.destroy!
    end
    Current.reset
  end
end
