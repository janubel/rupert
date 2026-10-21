# frozen_string_literal: true

require 'test_helper'

# The QuickBooks importers ship separately (QuickbooksCsv / QuickbooksImport).
# These tests stand in for them to prove the inbox adapter calls the agreed
# interface, stages only, and links to the History page; the real classes are
# exercised by that feature's own tests.
class UploadsQuickbooksAdapterTest < ActiveSupport::TestCase
  include UploadFixtures

  FakeRow = Struct.new(:date, :reason) do
    def rejected? = !reason.nil?
  end
  FakeParsed = Struct.new(:rows, :notes)
  FakeBatch = Struct.new(:id, :row_count, :accepted_count, :duplicate_count, :rejected_count) do
    def to_param = id.to_s
  end

  setup do
    Current.tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    Current.user = @admin
    @calls = []
    calls = @calls
    csv = Class.new do
      define_singleton_method(:parse) do |bytes, kind:|
        calls << [:parse, kind, bytes.bytesize]
        FakeParsed.new([FakeRow.new(Date.new(2026, 10, 1), nil), FakeRow.new(nil, 'bad row')], ['Read the dates as month/day/year.'])
      end
    end
    csv.const_set(:Error, Class.new(ArgumentError))
    stage = Class.new do
      define_singleton_method(:stage!) do |**args|
        calls << [:stage, args[:kind], args[:as_of]]
        Struct.new(:batch, :created).new(FakeBatch.new(7, 2, 1, 0, 1), true)
      end
    end
    stage.const_set(:Error, Class.new(ArgumentError))
    Object.const_set(:QuickbooksCsv, csv)
    Object.const_set(:QuickbooksImport, stage)
  end

  teardown do
    Object.send(:remove_const, :QuickbooksCsv)
    Object.send(:remove_const, :QuickbooksImport)
    Current.reset
  end

  def intake(content, name) = Uploads::Intake.call(StringIO.new(content), filename: name, origin: 'web', actor: @admin).upload

  test 'with the importer installed a chart of accounts is recognized and routed to staging only' do
    upload = intake(QB_COA_CSV, 'coa.csv')
    assert_equal 'recognized', upload.status
    assert_equal 'quickbooks', upload.importer_key
    assert_equal 'quickbooks:chart_of_accounts', upload.detected_type

    assert_no_difference -> { Finance::Account.count } do
      Uploads::Workflow.dry_run!(upload, actor: @admin)
    end
    assert_equal [:parse, 'chart_of_accounts', QB_COA_CSV.bytesize], @calls.last
    assert_equal 2, upload.reload.summary.dig('dry_run', 'counts', 'Rows read')
    assert_equal 1, upload.summary.dig('dry_run', 'counts', 'Rows that cannot be read')

    Uploads::Workflow.import!(upload, actor: @admin)
    assert_equal [:stage, 'chart_of_accounts', nil], @calls.last
    assert_equal 'imported', upload.reload.status
    assert_match(/Staged for review/, upload.summary.dig('import', 'headline'))
  end

  test 'a trial balance needs its as-of date, suggested from the report title' do
    upload = intake(QB_TRIAL_CSV, 'tb.csv')
    assert_equal 'quickbooks:trial_balance', upload.detected_type
    assert_equal '2026-10-31', upload.params['as_of']
    upload.update!(params_json: {}.to_json)
    Uploads::Workflow.dry_run!(upload, actor: @admin)
    assert_match(/as of/, upload.reload.reason)
    upload.update!(params_json: { 'as_of' => '2026-10-31' }.to_json)
    Uploads::Workflow.dry_run!(upload, actor: @admin)
    assert upload.reload.dry_run_current?
    Uploads::Workflow.import!(upload, actor: @admin)
    assert_equal [:stage, 'trial_balance', '2026-10-31'], @calls.last
  end

  test 'its own parse errors become a plain reason and leave the file waiting' do
    QuickbooksCsv.define_singleton_method(:parse) { |_bytes, kind:| raise QuickbooksCsv::Error, "This #{kind} layout cannot be posted safely." }
    upload = intake(QB_JOURNAL_CSV, 'journal.csv')
    Uploads::Workflow.dry_run!(upload, actor: @admin)
    upload.reload
    assert_equal 'needs_review', upload.status
    assert_match(/cannot be posted safely/, upload.reason)
  end
end
