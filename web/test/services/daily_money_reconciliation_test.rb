# frozen_string_literal: true

require 'test_helper'

class DailyMoneyReconciliationTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @day = '2026-10-14'
  end
  teardown { Current.reset }

  def evidence(**options)
    ReconciliationEvidence.retain!(**{ bytes: "total,10.00\r\n", filename: 'register.csv', source: 'square', kind: 'register_control',
      from: @day, to: @day, metadata: { 'currency' => 'USD', 'order_total' => 1000, 'card' => 1000 } }.merge(options))
  end

  def sale(source: 'square', currency: 'USD', location: nil)
    order = Core::Order.create!(source: source, source_order_id: SecureRandom.uuid, occurred_at: Time.zone.parse("#{@day} 12:00"),
      gross_cents: 1000, tax_cents: 0, currency: currency, location_id: location)
    order.mark_paid!
    order
  end

  test 'original bytes and metadata are encrypted and exact replays do not duplicate' do
    doc = evidence
    assert_equal "total,10.00\r\n", doc.reload.original_bytes
    assert_equal doc.id, evidence.id
    connection = ActiveRecord::Base.connection
    raw = connection.select_one("SELECT content_base64, metadata_json FROM reconciliation_documents WHERE id = #{doc.id}")
    refute_includes raw.fetch('content_base64'), Base64.strict_encode64(doc.original_bytes)
    refute_includes raw.fetch('metadata_json'), 'order_total'
    refute doc.update(filename: 'changed.csv')
    assert_raises(ActiveRecord::RecordNotDestroyed) { doc.destroy! }
  end

  test 'comparison preserves source currency location and shows variances and unavailable metrics' do
    order = sale
    order.payments.create!(method: 'card', amount_cents: 900, paid_at: order.occurred_at)
    sale(currency: 'EUR')
    sale(location: 'other-register')
    doc = evidence(metadata: { 'currency' => 'USD', 'order_total' => 1000, 'card' => 1000, 'tips' => 50 })
    rows = DailyMoneyReconciliation.new(day: @day).comparisons
    assert_equal [doc.id], rows.first[:document_ids]
    assert_equal 'Matched recorded total', rows.find { |row| row[:metric] == 'order_total' }[:status]
    card = rows.find { |row| row[:metric] == 'card' }
    assert_equal(-100, card[:delta_cents])
    assert_equal 'Variance', card[:status]
    assert_nil rows.find { |row| row[:metric] == 'tips' }[:actual_cents]
  end

  test 'missing source data is unavailable rather than zero or a match' do
    evidence(source: 'ctrax', metadata: { 'currency' => 'USD', 'cash' => 0 })
    row = DailyMoneyReconciliation.new(day: @day).comparisons.first
    assert_nil row[:actual_cents]
    assert_equal 'Unavailable in canonical records', row[:status]
  end

  test 'ambiguous controls need explicit corrections with both originals retained' do
    old = evidence
    evidence(bytes: "corrected total\n")
    assert_equal 'Conflicting controls', DailyMoneyReconciliation.new(day: @day).comparisons.first[:status]
    corrected = evidence(bytes: "new version\n", supersedes_id: old.id)
    assert_equal old.id, corrected.supersedes_id
    assert_equal 3, ReconciliationDocument.count
    assert_equal old.original_bytes, old.reload.original_bytes
    assert_raises(ReconciliationEvidence::Error) { evidence(bytes: "another\n", supersedes_id: old.id) }
  end

  test 'a single correction replaces only its control comparison and preserves history' do
    old = evidence
    corrected = evidence(bytes: "corrected\n", supersedes_id: old.id, metadata: { 'currency' => 'USD', 'order_total' => 900 })
    report = DailyMoneyReconciliation.new(day: @day)
    assert_equal [corrected.id], report.controls.map(&:id)
    assert_equal [old.id, corrected.id], report.documents.map(&:id)
  end

  test 'withdrawing an accidental duplicate resolves the conflict while preserving both files' do
    original = evidence
    duplicate = evidence(bytes: 'duplicate report')
    withdrawal = evidence(bytes: duplicate.original_bytes, metadata: duplicate.metadata.merge('withdrawn' => true, 'note' => 'Duplicate control'), supersedes_id: duplicate.id)
    report = DailyMoneyReconciliation.new(day: @day)
    assert_equal [original.id], report.controls.map(&:id)
    assert_equal 3, report.documents.size
    assert_equal duplicate.original_bytes, withdrawal.original_bytes
    refute report.comparisons.any? { |row| row[:status] == 'Conflicting controls' }
  end

  test 'tenant isolation covers document reads replays and correction targets' do
    own = evidence
    Current.tenant = Tenant.create!(name: 'Evidence foreign', subdomain: 'evidence-foreign')
    assert_nil ReconciliationDocument.find_by(id: own.id)
    assert_empty DailyMoneyReconciliation.new(day: @day).documents
    foreign = evidence
    refute_equal own.id, foreign.id
    assert_raises(ReconciliationEvidence::Error) { evidence(bytes: 'cross-tenant', supersedes_id: own.id) }
  end

  test 'archives replay unchanged data and keep versions for late arriving evidence' do
    sale
    first = DailyMoneyReconciliation.new(day: @day).archive!
    assert_equal first.id, DailyMoneyReconciliation.new(day: @day).archive!.id
    evidence
    second = DailyMoneyReconciliation.new(day: @day).archive!
    refute_equal first.id, second.id
    refute_equal first.metadata['report_digest'], second.metadata['report_digest']
    assert_includes first.original_bytes, 'Amounts in integer cents'
  end

  test 'CSV formula fields are neutralized and currencies are not combined' do
    sale(source: '=1+1', currency: 'EUR', location: '@formula')
    csv = DailyMoneyReconciliation.new(day: @day).csv
    assert_includes csv, "'=1+1"
    assert_includes csv, "'@formula"
    assert_includes csv, 'EUR'
  end

  test 'gateway and portal evidence retain date status and identity without adding sales' do
    canonical = sale
    settled = Time.zone.parse("#{@day} 16:00")
    AuthorizeNetTransaction.create!(environment: 'production', gateway_id: '12345', source_transaction_id: '67890',
      transaction_type: 'authCaptureTransaction', payment_status: 'settledSuccessfully', submitted_at: settled - 1.hour,
      settled_at: settled, authorized_amount: '10.00', settled_amount: '10.00', currency: 'USD', observed_at: settled)
    row = { 'transaction_id' => '67890', 'status' => 'Settled Successfully', 'transaction_type' => 'Authorization w/ Auto Capture',
      'currency' => 'USD', 'submitted_at' => (settled - 1.hour).iso8601, 'settled_at' => settled.iso8601, 'settlement_cents' => 1000 }
    export = AuthorizeNetPortalExport.create!(gateway_id: '12345', kind: 'settled', fingerprint: SecureRandom.hex, sha256: 'synthetic',
      exported_at: settled, original_csv: 'synthetic', records_json: [row].to_json)
    report = DailyMoneyReconciliation.new(day: @day)
    assert_equal 1000, report.register.rows.find { |r| r[:source] == canonical.source }[:order_total_cents]
    assert_equal 1, report.gateway.size
    assert_equal BigDecimal('10'), report.gateway.first.last
    assert_equal export.id, report.portal.first['export_id']
    first_digest = report.digest
    AuthorizeNetPortalExport.create!(gateway_id: '12345', kind: 'settled', fingerprint: SecureRandom.hex, sha256: 'new-synthetic',
      exported_at: settled + 1.minute, original_csv: 'new synthetic', records_json: [row.merge('status' => 'Updated observation')].to_json)
    refute_equal first_digest, DailyMoneyReconciliation.new(day: @day).digest
    assert_equal 1, DailyMoneyReconciliation.new(day: @day).portal.size
    assert_equal 1, Core::Order.count
  end

  test 'dates unsupported formats missing totals and invalid amounts fail before writes' do
    assert_raises(ReconciliationEvidence::Error) { evidence(from: 'bad') }
    assert_raises(ReconciliationEvidence::Error) { evidence(filename: 'bad.html') }
    assert_raises(ReconciliationEvidence::Error) { evidence(filename: 'bad.pdf', bytes: 'not pdf') }
    assert_raises(ReconciliationEvidence::Error) { evidence(bytes: '') }
    assert_raises(ReconciliationEvidence::Error) { evidence(metadata: { 'currency' => 'USD' }) }
    assert_raises(ReconciliationEvidence::Error) { ReconciliationEvidence.cents('1.001') }
    assert_raises(ReconciliationEvidence::Error) { ReconciliationEvidence.cents('NaN') }
    assert_equal(-123, ReconciliationEvidence.cents('-1.23'))
    assert_nil ReconciliationEvidence.cents('')
    assert_empty ReconciliationDocument.all
  end

  test 'retention pruning does not remove old evidence archives or review notes' do
    doc = evidence(from: '2020-01-01', to: '2020-01-01')
    review = DailyReconciliationReview.create!(day: '2020-01-01', report_digest: 'old', status: 'reviewed', notes: 'Original review')
    DataRetention.prune_all!
    assert ReconciliationDocument.exists?(doc.id)
    assert DailyReconciliationReview.exists?(review.id)
  end

  test 'archive scheduler revisits seven days and never changes canonical sales' do
    sale
    assert_no_difference ['Core::Order.count', 'Core::Payment.count', 'LedgerEntry.count'] do
      travel_to Time.zone.parse('2026-10-15 08:00') do
        DailyReconciliationArchiveJob.perform_now
        own = ReconciliationDocument.where(kind: 'daily_archive').count
        assert_equal 7, own
        DailyReconciliationArchiveJob.perform_now
        assert_equal own, ReconciliationDocument.where(kind: 'daily_archive').count
      end
    end
  end
end
