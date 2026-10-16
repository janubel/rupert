# frozen_string_literal: true

require 'test_helper'

class ReconciliationLibraryTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @stamp = Time.zone.parse('2026-10-15 12:00')
  end
  teardown { Current.reset }

  def retain(name:, kind: 'invoice', from: '2026-10-01', to: '2026-10-31', metadata: {})
    travel_to(@stamp) do
      ReconciliationEvidence.retain!(bytes: "original #{name}\n", filename: name, source: 'bank', kind: kind, from: from, to: to, metadata: metadata)
    end
  end

  test 'filters intersect document coverage and find case-insensitive filenames and references' do
    invoice = retain(name: 'October_Invoice.txt')
    retain(name: 'September.txt', from: '2026-09-01', to: '2026-09-30')
    retain(name: 'other.txt', kind: 'source_export')
    retain(name: 'OctoberXInvoice.txt', kind: 'source_export')
    statement = retain(name: 'bank-statement.txt', kind: 'bank_statement')
    assert_includes ReconciliationLibrary.new(category: 'source_files').page.map { |entry| entry.record.id }, statement.id
    library = ReconciliationLibrary.new(q: 'INVOICE', category: 'invoices', from: '2026-10-14', to: '2026-10-15')
    assert_equal [invoice.id], library.page.map { |entry| entry.record.id }
    assert_equal 1, library.total
    assert_equal [invoice.id], ReconciliationLibrary.new(q: "##{invoice.id}").page.map { |entry| entry.record.id }
    assert_equal 1, ReconciliationLibrary.new(q: 'October_').total
    assert_equal 0, ReconciliationLibrary.new(q: '%').total
  end

  test 'mixed native and vault pagination is stable for tied timestamps and does not read file blobs' do
    26.times { |n| retain(name: "invoice-#{n}.txt") }
    bytes = "invoice,total\nA,1.00\n"
    native = SwipesimpleExport.create!(merchant_account: 'test', currency: 'USD', source_timezone: 'America/New_York', kind: 'invoices',
      fingerprint: 'native', sha256: Digest::SHA256.hexdigest(bytes), exported_at: @stamp, original_csv: bytes)
    seen = []
    statements = []
    ActiveSupport::Notifications.subscribed(->(_, _, _, _, payload) { statements << payload[:sql] }, 'sql.active_record') do
      first = ReconciliationLibrary.new
      assert_equal 27, first.total
      seen += first.page.map(&:key)
      assert_equal 24, first.page.size
      assert first.next_cursor
      second = ReconciliationLibrary.new(cursor: first.next_cursor, category: 'all')
      seen += second.page.map(&:key)
      assert_equal 3, second.page.size
      assert_nil second.next_cursor
    end
    assert_equal 27, seen.uniq.size
    assert_includes seen, "swipesimple:#{native.id}"
    refute statements.any? { |sql| sql.match?(/SELECT.*(?:content_base64|original_csv)/i) }, 'metadata browsing must not load encrypted file bodies'
  end

  test 'native dates use received export time and invoice category includes invoice exports only' do
    bytes = "id,total\nA,1.00\n"
    %w[invoices transactions].each do |kind|
      SwipesimpleExport.create!(merchant_account: 'test', currency: 'USD', source_timezone: 'America/New_York', kind: kind,
        fingerprint: kind, sha256: Digest::SHA256.hexdigest(bytes), exported_at: @stamp, original_csv: bytes)
    end
    assert_equal 1, ReconciliationLibrary.new(category: 'invoices', source: 'swipesimple').total
    assert_equal 2, ReconciliationLibrary.new(category: 'native_exports', from: '2026-10-15', to: '2026-10-15').total
    assert_equal 0, ReconciliationLibrary.new(category: 'native_exports', from: '2026-10-16').total
    assert_equal 0, ReconciliationLibrary.new(category: 'archives').total
  end

  test 'scope and cursor cannot cross tenants or filters' do
    25.times { |n| retain(name: "private-#{n}.txt") }
    cursor = ReconciliationLibrary.new.next_cursor
    other = Tenant.create!(name: 'Foreign retention', subdomain: 'foreign-retention')
    Current.set(tenant: other) do
      assert_equal 0, ReconciliationLibrary.new.total
      assert_raises(ReconciliationLibrary::Error) { ReconciliationLibrary.new(cursor: cursor) }
    end
    assert_raises(ReconciliationLibrary::Error) { ReconciliationLibrary.new(cursor: cursor, q: 'different') }
    assert_raises(ReconciliationLibrary::Error) { ReconciliationLibrary.new(cursor: 'tampered') }
    assert_raises(ReconciliationLibrary::Error) { ReconciliationLibrary.new(from: '2026-10-20', to: '2026-10-01') }
  end
end
