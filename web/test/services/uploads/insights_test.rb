# frozen_string_literal: true

require 'test_helper'

class UploadsInsightsTest < ActiveSupport::TestCase
  include UploadFixtures

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    Current.user = @admin
  end

  teardown { Current.reset }

  def intake(content, name) = Uploads::Intake.call(StringIO.new(content), filename: name, origin: 'web', actor: @admin).upload

  def run_bank(upload, label = 'Operating')
    upload.update!(params_json: { 'account_label' => label }.to_json)
    Uploads::Workflow.dry_run!(upload, actor: @admin)
    Uploads::Workflow.import!(upload, actor: @admin) if upload.reload.dry_run_current?
  end

  test 'every way a file can wait or be refused carries a reason code' do
    intake(UNKNOWN_CSV, 'a.csv')
    intake(SQUARE_CSV, 'b.csv')
    intake('MZ', 'c.exe')
    intake('', 'd.csv')
    intake('{"a":', 'e.json')
    intake("MZ\x90\x00\x03".b, 'f.csv')
    intake(BANK_CSV, 'g.csv')
    intake(BANK_CSV, 'h.csv')
    codes = Upload.order(:id).pluck(:reason_code)
    assert_equal ['unrecognized', 'no_importer', 'unsupported_type', 'empty', 'bad_json', 'not_text', nil, 'duplicate'], codes
  end

  test 'a failed dry run, a discard and a successful import update the code' do
    bad = intake("Date,Description,Amount\nnot-a-date,X,1\n2026-10-15,Y,2\n", 'bad.csv')
    run_bank(bad)
    assert_equal 'dry_run_failed', bad.reload.reason_code
    ok = intake(BANK_CSV, 'ok.csv')
    run_bank(ok)
    assert_equal 'imported', ok.reload.status
    assert_nil ok.reason_code
    other = intake(UNKNOWN_CSV, 'x.csv')
    Uploads::Workflow.discard!(other, actor: @admin)
    assert_equal 'discarded', other.reload.reason_code
  end

  test 'insights count outcomes per day, the funnel, reasons, types and importer health' do
    ok = intake(BANK_CSV, 'ok.csv')
    run_bank(ok)
    bad = intake("Date,Description,Amount\nnope,X,1\n2026-10-15,Y,2\n", 'bad.csv')
    run_bank(bad)
    intake(UNKNOWN_CSV, 'u.csv')
    intake(SQUARE_CSV, 's.csv')
    intake('MZ', 'virus.exe')
    intake(BANK_CSV, 'again.csv')

    insights = Uploads::Insights.new(days: 30)
    assert_equal 6, insights.total
    today = insights.daily.last
    assert_equal Time.zone.today, today[:date]
    assert_equal 6, today[:total]
    assert_equal 1, today[:counts]['imported']
    assert_equal 1, today[:counts]['rejected']
    assert_equal 1, today[:counts]['duplicate']
    assert_equal 30, insights.daily.size

    funnel = insights.funnel.to_h { |step| [step[:key], step[:count]] }
    assert_equal 4, funnel['kept']
    assert_equal 1, funnel['imported']
    assert_equal 1, funnel['dry_run']

    reasons = insights.reasons.to_h { |reason| [reason[:code], reason[:count]] }
    assert_equal 1, reasons['unrecognized']
    assert_equal 1, reasons['no_importer']
    assert_equal 1, reasons['unsupported_type']
    assert_equal 1, reasons['duplicate']
    assert_equal 1, reasons['dry_run_failed']
    assert_equal reasons.values.max, insights.reasons.first[:count]

    bank = insights.types.find { |type| type[:label] == 'Bank statement' }
    assert_equal 2, bank[:count]
    assert_equal 1, bank[:imported]
    importer = insights.importers.find { |entry| entry[:key] == 'bank_statement' }
    assert_equal({ passed: 1, failed: 1, imported: 1, import_failed: 0 }, importer.slice(:passed, :failed, :imported, :import_failed))
    assert_equal 'Bank statement CSV', importer[:label]
    assert_equal 3, insights.waiting_count
    assert_equal 0, insights.oldest_waiting_days
    assert_operator insights.time_to_import_hours, :<, 0.1
  end

  test 'old uploads fall outside the range and another workspace is never counted' do
    old = intake(BANK_CSV, 'old.csv')
    old.update_columns(created_at: 40.days.ago)
    intake(UNKNOWN_CSV, 'new.csv')
    other = Tenant.create!(name: 'Insights other', subdomain: 'insights-other')
    Current.tenant = other
    Upload.create!(tenant_id: other.id, filename: 'private.csv', file_format: 'csv', byte_size: 1, status: 'rejected', reason_code: 'empty', retained: false)
    Current.tenant = @tenant
    assert_equal 1, Uploads::Insights.new(days: 30).total
    assert_equal 2, Uploads::Insights.new(days: 90).total
    assert_equal 30, Uploads::Insights.new(days: 7).days, 'an unknown range falls back to 30 days'
    assert_empty Uploads::Insights.new(days: 30).reasons.select { |reason| reason[:code] == 'empty' }
  end

  test 'insights never contain file contents or names' do
    intake("Date,Description,Amount\n2026-10-14,SECRETPAYEE,-1.00\n", 'secret-name.csv')
    insights = Uploads::Insights.new(days: 30)
    dump = [insights.daily, insights.funnel, insights.reasons, insights.types, insights.importers, insights.origins].to_json
    assert_no_match(/SECRETPAYEE|secret-name/, dump)
  end
end
