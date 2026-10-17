# frozen_string_literal: true

require 'test_helper'

class AuthorizeNetPortalObservationTest < ActiveSupport::TestCase
  # The whole-history scan these observations replace, kept verbatim as the
  # reference for byte-identical day payloads and period rows.
  def legacy_latest
    observations = {}
    AuthorizeNetPortalExport.select(:id, :gateway_id, :records_json, :exported_at).find_each do |receipt|
      receipt.records.each do |row|
        key = [receipt.gateway_id, row.fetch('transaction_id')]
        previous = observations[key]
        next if previous && previous.fetch('exported_at') > receipt.exported_at.iso8601(6)

        observations[key] = row.merge('gateway_id' => receipt.gateway_id,
          'export_id' => receipt.id, 'exported_at' => receipt.exported_at.iso8601(6))
      end
    end
    observations.values
  end

  def legacy_portal(day)
    legacy_latest.select do |row|
      %w[submitted_at settled_at].any? { |key| row[key].present? && Time.iso8601(row[key]).in_time_zone.to_date == day }
    end.sort_by { |row| [row['gateway_id'], row['transaction_id']] }
  end

  class LegacyReport < MoneyReconciliationReport
    attr_accessor :legacy_rows

    def authorize_net
      observations = legacy_rows.to_h { |r| [[r['gateway_id'], r['transaction_id']], r] }
      AuthorizeNetTransaction.where(environment: 'production').find_each do |r|
        previous = observations[[r.gateway_id, r.source_transaction_id]]
        next if previous && Time.iso8601(previous.fetch('exported_at')) > r.observed_at

        observations[[r.gateway_id, r.source_transaction_id]] = {
          'gateway_id' => r.gateway_id, 'status' => r.payment_status, 'transaction_type' => r.transaction_type,
          'settled_at' => r.settled_at&.iso8601, 'submitted_at' => r.submitted_at.iso8601,
          'currency' => r.currency, 'settlement_amount' => r.settled_amount.to_s('F')
        }
      end
      selected = observations.values.select { |r| r['settled_at'].present? && @range.cover?(Time.iso8601(r['settled_at'])) }
      selected.group_by { |r| [r['gateway_id'], r['currency']] }.each do |(account, currency), group|
        sales = group.select { |r| ['Settled Successfully', 'settledSuccessfully'].include?(r['status']) && !r['transaction_type'].to_s.downcase.include?('refund') }
        refunds = group.select { |r| ['Refund Settled Successfully', 'Refund', 'refundSettledSuccessfully'].include?(r['status']) || (['Settled Successfully', 'settledSuccessfully'].include?(r['status']) && r['transaction_type'].to_s.downcase.include?('refund')) }
        [['Settled sales', sales], ['Settled refunds', refunds]].each do |metric, values|
          next if values.empty?

          add('Authorize.net', account, currency, metric, values.sum(BigDecimal('0')) { |r| r['settlement_amount'] ? BigDecimal(r['settlement_amount']) : BigDecimal(r.fetch('settlement_cents').to_s) / 100 }, values.size, 'Settlement date; newest API/portal observation per transaction')
        end
      end
      @warnings << 'Authorize.net portal snapshots may cover only a selected range; missing rows do not prove zero settlements.'
    end
  end

  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  def export(gateway, exported_at, rows)
    AuthorizeNetPortalExport.create!(gateway_id: gateway, kind: 'settled', fingerprint: SecureRandom.hex, sha256: 'synthetic',
      exported_at: Time.iso8601(exported_at), original_csv: 'synthetic', records_json: rows.to_json)
  end

  def row(id, submitted, settled, status: 'Settled Successfully', cents: 1000)
    { 'transaction_id' => id, 'status' => status, 'transaction_type' => 'Authorization w/ Auto Capture', 'currency' => 'USD',
      'settlement_cents' => cents, 'authorization_cents' => cents, 'submitted_at' => submitted, 'settled_at' => settled,
      'reference_transaction_id' => nil, 'source_row' => 2 }
  end

  def history
    export('111', '2026-10-15T22:00:00Z', [row('1', '2026-10-14T15:00:00Z', '2026-10-15T02:00:00Z'),
      row('2', '2026-10-14T03:30:00Z', nil), row('3', '2026-10-14T16:00:00Z', '2026-10-15T15:00:00Z'),
      row('4', '2026-10-14T17:00:00Z', nil), row('5', '2026-10-13T12:00:00Z', '2026-10-13T20:00:00Z')])
    export('111', '2026-10-16T09:00:00.123456Z', [row('3', '2026-10-14T16:00:00Z', '2026-10-15T15:00:00Z', status: 'Updated', cents: 1100),
      row('4', '2026-10-12T17:00:00Z', nil)])
    # Same instant: the later export keeps the observation, as before.
    export('111', '2026-10-16T09:00:00.123456Z', [row('3', '2026-10-14T16:00:00Z', '2026-10-16T15:00:00Z', status: 'Tie later', cents: 1200)])
    export('222', '2026-10-15T23:00:00Z', [row('1', '2026-10-14T18:00:00Z', '2026-10-15T01:00:00Z', cents: 777)])
    # Imported later but exported earlier: the older observation loses.
    export('111', '2026-10-15T21:00:00Z', [row('5', '2026-10-14T12:00:00Z', '2026-10-14T20:00:00Z', status: 'Stale')])
    # Eastern fall-back hour: the original string comparison keeps 01:30 EDT over 01:10 EST.
    export('111', '2026-11-01T05:30:00Z', [row('9', '2026-10-14T19:00:00Z', '2026-11-01T04:00:00Z', status: 'EDT')])
    export('111', '2026-11-01T06:10:00Z', [row('9', '2026-10-14T19:00:00Z', '2026-11-01T04:00:00Z', status: 'EST')])
    # Legacy row shape and a repeated ID within one export.
    export('333', '2026-10-15T20:00:00Z', [{ 'settled_at' => '2026-10-14T21:00:00Z', 'transaction_id' => '10', 'note' => 'first', 'settlement_cents' => 5 },
      { 'settled_at' => '2026-10-14T21:00:00Z', 'transaction_id' => '10', 'note' => 'second', 'settlement_cents' => 6 }])
    other = Tenant.create!(name: 'Other portal', subdomain: 'portal-obs-other', status: 'active')
    Current.set(tenant: other) { export('111', '2026-10-20T00:00:00Z', [row('1', '2026-10-14T15:00:00Z', nil, status: 'Other tenant')]) }
  end

  test 'day payloads stay byte-identical to the whole-history scan' do
    history
    %w[2026-10-12 2026-10-13 2026-10-14 2026-10-15 2026-10-16 2026-11-01 2026-11-02].each do |day|
      current = DailyMoneyReconciliation.new(day: day)
      legacy = DailyMoneyReconciliation.new(day: day)
      expected = legacy_portal(current.day)
      legacy.define_singleton_method(:portal) { expected }
      assert_equal legacy.payload.to_json, current.payload.to_json, day
      assert_equal legacy.digest, current.digest, day
    end
    assert_equal legacy_latest.to_json, AuthorizeNetPortalExport.latest_records.to_json
    assert_equal %w[1 3 9 1 10], DailyMoneyReconciliation.new(day: '2026-10-14').portal.pluck('transaction_id')
  end

  test 'pinned portal rows keep their shape and order' do
    history
    first = AuthorizeNetPortalExport.order(:id).first
    tie = AuthorizeNetPortalExport.order(:id).third
    portal = DailyMoneyReconciliation.new(day: '2026-10-16').portal
    assert_equal [{ 'transaction_id' => '3', 'status' => 'Tie later', 'transaction_type' => 'Authorization w/ Auto Capture', 'currency' => 'USD',
      'settlement_cents' => 1200, 'authorization_cents' => 1200, 'submitted_at' => '2026-10-14T16:00:00Z', 'settled_at' => '2026-10-16T15:00:00Z',
      'reference_transaction_id' => nil, 'source_row' => 2, 'gateway_id' => '111', 'export_id' => tie.id,
      'exported_at' => '2026-10-16T05:00:00.123456-04:00' }].to_json, portal.to_json
    edt = DailyMoneyReconciliation.new(day: '2026-11-01').portal.find { |r| r['transaction_id'] == '9' }
    assert_equal 'EDT', edt['status']
    assert_equal first.id, DailyMoneyReconciliation.new(day: '2026-10-13').portal.find { |r| r['transaction_id'] == '5' }['export_id']
  end

  test 'period rows match the whole-history report' do
    history
    AuthorizeNetTransaction.create!(environment: 'production', gateway_id: '111', source_transaction_id: '1', transaction_type: 'authCaptureTransaction',
      payment_status: 'settledSuccessfully', submitted_at: Time.iso8601('2026-10-14T15:00:00Z'), settled_at: Time.iso8601('2026-10-15T02:00:00Z'),
      currency: 'USD', authorized_amount: '10.01', settled_amount: '10.01', observed_at: Time.iso8601('2026-10-17T00:00:00Z'))
    AuthorizeNetTransaction.create!(environment: 'production', gateway_id: '111', source_transaction_id: '3', transaction_type: 'authCaptureTransaction',
      payment_status: 'settledSuccessfully', submitted_at: Time.iso8601('2026-10-14T16:00:00Z'), settled_at: Time.iso8601('2026-10-15T15:00:00Z'),
      currency: 'USD', authorized_amount: '9.99', settled_amount: '9.99', observed_at: Time.iso8601('2026-10-01T00:00:00Z'))
    AuthorizeNetTransaction.create!(environment: 'production', gateway_id: '111', source_transaction_id: '5', transaction_type: 'authCaptureTransaction',
      payment_status: 'settledSuccessfully', submitted_at: Time.iso8601('2026-10-13T12:00:00Z'), settled_at: Time.iso8601('2026-09-30T12:00:00Z'),
      currency: 'USD', authorized_amount: '1.00', settled_amount: '1.00', observed_at: Time.iso8601('2026-10-18T00:00:00Z'))
    AuthorizeNetTransaction.create!(environment: 'production', gateway_id: '444', source_transaction_id: '44', transaction_type: 'refundTransaction',
      payment_status: 'refundSettledSuccessfully', submitted_at: Time.iso8601('2026-10-14T16:00:00Z'), settled_at: Time.iso8601('2026-10-14T18:00:00Z'),
      currency: 'USD', authorized_amount: '2.50', settled_amount: '2.50', observed_at: Time.iso8601('2026-10-15T00:00:00Z'))
    [%w[daily 2026-10-14], %w[weekly 2026-10-14], %w[monthly 2026-10-14], %w[monthly 2026-11-01], %w[daily 2026-09-30]].each do |kind, date|
      legacy = LegacyReport.new(kind: kind, date: date)
      legacy.legacy_rows = legacy_latest
      current = MoneyReconciliationReport.new(kind: kind, date: date)
      assert_equal legacy.payload.except('generated_at').to_json, current.payload.except('generated_at').to_json, "#{kind} #{date}"
    end
  end

  test 'counts totals and the index window use the newest observation per transaction' do
    history
    latest = legacy_latest
    assert_equal latest.size, AuthorizeNetPortalObservation.transaction_count
    expected = latest.select { |r| r['status'] == 'Settled Successfully' && r['transaction_type'] == 'Authorization w/ Auto Capture' }
      .group_by { |r| r.fetch('currency') }.transform_values { |rows| rows.sum { |r| r.fetch('settlement_cents') } }
    assert_equal expected, AuthorizeNetPortalObservation.latest_totals(status: 'Settled Successfully', transaction_type: 'Authorization w/ Auto Capture')
    recent = AuthorizeNetPortalObservation.recent(3)
    assert_equal latest.select { |r| r['submitted_at'] }.sort_by { |r| r['submitted_at'] }.reverse.first(3).to_json, recent.to_json
    assert_equal latest.size, SourceSyncStatus.all.find { |s| s[:key] == 'authorize_net' }[:detail].to_i
  end

  test 'rows are encrypted tenant scoped and recording is idempotent' do
    history
    receipt = AuthorizeNetPortalExport.order(:id).first
    raw = AuthorizeNetPortalObservation.connection.select_values("SELECT record_json FROM authorize_net_portal_observations WHERE authorize_net_portal_export_id = #{receipt.id}")
    assert_equal 5, raw.size
    raw.each { |value| refute_includes value, 'Settled Successfully' }
    before = AuthorizeNetPortalExport.latest_records.to_json
    count = AuthorizeNetPortalObservation.count
    AuthorizeNetPortalExport.find_each { |item| AuthorizeNetPortalObservation.record!(item) }
    assert_equal count, AuthorizeNetPortalObservation.count
    assert_equal before, AuthorizeNetPortalExport.latest_records.to_json
    refute_includes AuthorizeNetPortalExport.latest_records.pluck('status'), 'Other tenant'
    assert_equal 1, AuthorizeNetPortalObservation.unscoped.where(status: 'Other tenant').count
    Current.tenant = nil
    assert_equal 0, AuthorizeNetPortalObservation.transaction_count
    assert_empty AuthorizeNetPortalObservation.latest_between(Time.zone.parse('2026-10-14')...Time.zone.parse('2026-10-15'))
  end
end
