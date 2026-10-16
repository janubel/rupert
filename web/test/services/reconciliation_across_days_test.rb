# frozen_string_literal: true

require 'test_helper'

class ReconciliationAcrossDaysTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  test 'seven date view distinguishes missing controls from requests and reuses exact scope requests' do
    day = Date.new(2026, 10, 14)
    order = Core::Order.create!(source: 'square', source_order_id: 'across-days-order', currency: 'USD',
      occurred_at: Time.zone.parse('2026-10-14 12:00'), gross_cents: 1000, tax_cents: 0)
    order.mark_paid!
    monthly = request(source: 'bank', kind: 'bank_statement', from: day.beginning_of_month, to: day.end_of_month)
    control = request(source: 'square', kind: 'register_control', from: day, to: day, currency: 'USD')
    foreign = Tenant.create!(name: 'Hidden across days', subdomain: 'hidden-across-days')
    Current.set(tenant: foreign) { request(source: 'square', kind: 'register_control', from: day, to: day, currency: 'EUR') }
    before = [Core::Order.count, ReconciliationDocument.count, ReconciliationFollowUpEvent.count]
    overview = ReconciliationAcrossDays.new(ending_on: '2026-10-15')
    assert_equal 7, overview.days.size
    assert_equal Date.new(2026, 10, 9), overview.starting_on
    row = overview.days.find { |entry| entry[:day] == day }
    assert_equal 1, row[:counts][:missing_controls]
    assert_equal 0, row[:untracked]
    assert_equal control.id, row[:missing].first[:request_id]
    assert_empty overview.untracked_reports
    assert_equal 2, row[:follow_ups]
    assert_equal 7, overview.days_needing_attention
    assert_equal before, [Core::Order.count, ReconciliationDocument.count, ReconciliationFollowUpEvent.count]
    control.update!(status: 'closed', notes: 'Closed request does not provide a control.')
    row = ReconciliationAcrossDays.new(ending_on: '2026-10-15').days.find { |entry| entry[:day] == day }
    assert_equal 1, row[:untracked]
    assert_equal [day], ReconciliationAcrossDays.new(ending_on: '2026-10-15').untracked_reports.map { |gap| gap[:day] }
    assert_nil row[:missing].first[:request_id]
    assert_equal 1, row[:follow_ups]
    assert monthly.persisted?
  end

  test 'requests outside the selected dates are excluded and invalid dates fail clearly' do
    request(source: 'bank', kind: 'bank_statement', from: Date.new(2026, 9, 1), to: Date.new(2026, 9, 30))
    overview = ReconciliationAcrossDays.new(ending_on: '2026-10-15')
    assert_equal 0, overview.days.sum { |row| row[:follow_ups] }
    assert_raises(ReconciliationEvidence::Error) { ReconciliationAcrossDays.new(ending_on: '2026-13-40') }
  end

  test 'close dates distinguish review freshness package freshness and overdue covered work without writes' do
    travel_to Time.zone.parse('2026-10-16 12:00') do
      day = Date.new(2026, 10, 14)
      actor = users(:regular_user)
      item = request(source: 'bank', kind: 'bank_statement', from: day.beginning_of_month, to: day.end_of_month)
      item.update!(due_on: day, notes: 'Original still needed.')
      workflow = FinancialCloseWorkflow.new(day: day.iso8601)
      DailyReconciliationReview.create!(day: day, report_digest: workflow.report.digest, status: 'needs_attention', notes: 'Exception recorded.', reviewed_by: actor)
      workflow = FinancialCloseWorkflow.new(day: day.iso8601)
      package = workflow.retain!({ 'workflow_digest' => workflow.digest, 'disposition' => 'with_exceptions', 'notes' => 'Statement outstanding.' }.merge(FinancialCloseWorkflow::CHECKS.keys.to_h { |key| [key, '1'] }), actor: actor)
      row = ReconciliationAcrossDays.new(ending_on: day.iso8601).days.first
      assert_equal 1, row[:overdue]
      assert_equal 'Needs attention', row[:close][:review]
      assert_equal package.id, row[:close][:package_id]
      assert row[:close][:package_current]
      overview = ReconciliationAcrossDays.new(ending_on: day.iso8601)
      assert_equal 7, overview.focused_days('overdue').size
      assert_empty overview.focused_days('changed')
      refute_includes overview.focused_days('review').map { |entry| entry[:day] }, day
      assert_equal item.id, row[:close][:next_overdue].id
      item.update!(notes: 'New next step recorded.')
      assert_no_enqueued_jobs do
        assert_no_difference ['ReconciliationDocument.count', 'ReconciliationFollowUpEvent.count', 'ActionMailer::Base.deliveries.size'] do
          row = ReconciliationAcrossDays.new(ending_on: day.iso8601).days.first
          refute row[:close][:package_current]
          assert_equal 'Needs attention', row[:close][:review]
          assert_equal [day], ReconciliationAcrossDays.new(ending_on: day.iso8601).focused_days('changed').map { |entry| entry[:day] }
        end
      end
      ReconciliationEvidence.retain!(bytes: 'New evidence', filename: 'new-statement.txt', source: 'bank', kind: 'bank_statement', from: day.iso8601, to: day.iso8601)
      assert_equal 'Changed since review', ReconciliationAcrossDays.new(ending_on: day.iso8601).days.first[:close][:review]
      foreign = Tenant.create!(name: 'Other close dates', subdomain: 'other-close-dates')
      Current.set(tenant: foreign) do
        row = ReconciliationAcrossDays.new(ending_on: day.iso8601).days.first
        assert_nil row[:close][:package_id]
        assert_equal 'Review not recorded', row[:close][:review]
        assert_equal 0, row[:overdue]
        assert_empty ReconciliationAcrossDays.new(ending_on: day.iso8601).focused_days('overdue')
      end
    end
  end

  private

  def request(source:, kind:, from:, to:, currency: nil)
    ReconciliationFollowUp.create!(category: 'missing_report', source: source, document_kind: kind, period_from: from, period_to: to,
      currency: currency, due_on: Date.new(2026, 10, 16), title: 'Synthetic expected report', notes: 'Request the original.', submission_key: SecureRandom.uuid)
  end
end
