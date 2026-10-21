# frozen_string_literal: true

require 'test_helper'

class UploadsRecognizerTest < ActiveSupport::TestCase
  include UploadFixtures

  setup do
    Current.tenant = tenants(:default_tenant)
    Current.user = users(:regular_user)
  end

  teardown do
    Uploads::Registry.reset_extra!
    Current.reset
  end

  def intake(content, name)
    Uploads::Intake.call(StringIO.new(content), filename: name, origin: 'web', actor: Current.user).upload
  end

  test 'each supported export is recognized by its own signature' do
    {
      [BANK_CSV, 'oct.csv'] => ['bank_statement', 'recognized'],
      [SWIPE_SALES_CSV, 'sales.csv'] => ['swipesimple_sales', 'recognized'],
      [IRIS_CSV, 'dd.csv'] => ['iris_daily_deposits', 'recognized'],
      [authnet_csv, 'auth.csv'] => ['authorize_net_portal', 'recognized']
    }.each do |(content, name), (importer, status)|
      upload = intake(content, name)
      assert_equal importer, upload.importer_key, name
      assert_equal status, upload.status, name
      assert_operator upload.confidence, :>=, 75, name
      assert upload.detected_reason.present?, name
    end
  end

  test 'a SwipeSimple web report is recognized from its native columns' do
    csv = "Transaction #,Date,Type,Amount,Result,Method\n1,2026-10-14 10:00,Sale,10.00,Approved,Visa\n"
    upload = intake(csv, 'swipe-transactions.csv')
    assert_equal 'swipesimple_report', upload.importer_key
    assert_equal 'recognized', upload.status
  end

  test 'a generic item list is a shape match, not a signature' do
    upload = intake(ITEMS_CSV, 'list.csv')
    assert_equal 'swipesimple_items', upload.detected_type
    assert_operator upload.confidence, :<, 100
    assert_match(/shape match/, upload.detected_reason)
  end

  test 'QuickBooks exports are named by kind, and wait as needs review while the importer is not installed' do
    {
      [QB_COA_CSV, 'coa.csv'] => 'quickbooks:chart_of_accounts', [QB_JOURNAL_CSV, 'journal.csv'] => 'quickbooks:journal',
      [QB_TRIAL_CSV, 'tb.csv'] => 'quickbooks:trial_balance', [QB_VENDORS_CSV, 'vendors.csv'] => 'quickbooks:vendors'
    }.each do |(content, name), type|
      upload = intake(content, name)
      assert_equal type, upload.detected_type, name
      assert_operator upload.confidence, :>=, 75, name
      next if Uploads::Importers::Quickbooks.available?

      assert_equal 'needs_review', upload.status, name
      assert_match(/not installed yet/, upload.reason, name)
      assert_nil upload.importer_key
    end
  end

  test 'a bare vendor-shaped file with no QuickBooks title is only a weak guess' do
    upload = intake("Vendor,Company,Phone,Email,Balance\nAcme,Acme Co,555-0100,ap@example.test,0.00\n", 'v.csv')
    assert_equal 'needs_review', upload.status
    assert_operator upload.confidence, :<, 75
  end

  test 'known but unimportable files stay as needs review with the reason' do
    square = intake(SQUARE_CSV, 'items.csv')
    assert_equal 'needs_review', square.status
    assert_equal 'square:sales', square.detected_type
    assert_match(/no importer for it yet/, square.reason)
    timesheets = intake(TIMESHEET_CSV, 'ts.csv')
    assert_equal 'rupert:timesheets', timesheets.detected_type
    assert_equal 'needs_review', timesheets.status
  end

  test 'unrecognized files are never guessed' do
    csv = intake(UNKNOWN_CSV, 'mystery.csv')
    assert_equal 'needs_review', csv.status
    assert_nil csv.importer_key
    assert_nil csv.detected_type
    assert_match(/could not tell/, csv.reason)
    pdf = intake("%PDF-1.4\n%fake body", 'invoice.pdf')
    assert_equal 'needs_review', pdf.status
    assert_match(/PDF/, pdf.reason)
    json = intake('[{"a":1},{"a":2}]', 'data.json')
    assert_match(/2 items/, json.reason)
  end

  test 'an Excel copy of a QuickBooks report is named but not routed' do
    xlsx = build_xlsx([['Account', 'Type', 'Detail Type', 'Description', 'Balance'], ['Checking', 'Bank', 'Checking', '', 1000]])
    upload = intake(xlsx, 'coa.xlsx')
    assert_equal 'quickbooks:chart_of_accounts', upload.detected_type
    assert_equal 'needs_review', upload.status
    assert_match(/Save As CSV/, upload.detected_reason)
  end

  test 'two close candidates are held for a person instead of picking one' do
    both = Class.new(Uploads::Importers::Base) do
      importer 'rival', label: 'Rival bank importer', source: 'Bank', permission: 'finance.write'
      def detect(_doc) = Uploads::Detection.new(type: 'rival', label: 'Rival bank', confidence: 0.75, reason: 'test', importer: 'rival', source: 'Bank')
    end
    Uploads::Registry.register(both)
    upload = intake(BANK_CSV, 'oct.csv')
    assert_equal 'needs_review', upload.status
    assert_match(/Could be/, upload.reason)
  end

  test 'a new importer picks up old needs-review files when recognition is re-run' do
    upload = intake(UNKNOWN_CSV, 'mystery.csv')
    assert_equal 'needs_review', upload.status
    before = upload.recognizer_version
    fresh = Class.new(Uploads::Importers::Base) do
      importer 'greek', label: 'Greek letters', source: 'Test', permission: 'uploads.write', formats: %w[csv]
      def detect(doc) = doc.header_keys == %w[alpha beta gamma] ? detection('greek', 'Greek letters', 0.95, 'alpha beta gamma header') : nil
    end
    Uploads::Registry.register(fresh)
    assert_equal 1, Uploads::Workflow.recognize_all!(actor: Current.user)
    upload.reload
    assert_equal 'recognized', upload.status
    assert_equal 'greek', upload.importer_key
    assert_not_equal before, upload.recognizer_version
  end

  test 'a broken sniffer never blocks an upload' do
    broken = Class.new(Uploads::Importers::Base) do
      importer 'broken', label: 'Broken', source: 'Test', permission: 'uploads.write'
      def detect(_doc) = raise('boom')
    end
    Uploads::Registry.register(broken)
    assert_equal 'recognized', intake(BANK_CSV, 'oct.csv').status
  end

  test 'titles above the headings and tab or semicolon separators are handled' do
    titled = "My Bank\nAccount ending in ####\n\nDate;Description;Amount;Balance\n2026-10-14;UPS;-42,10;900\n2026-10-15;ACME;-1;899\n"
    assert_equal 'bank_statement', intake(titled, 'semi.csv').importer_key
    tabbed = "Date\tDescription\tAmount\n2026-10-14\tUPS\t-42.10\n2026-10-15\tACME\t-1.00\n"
    assert_equal 'bank_statement', intake(tabbed, 'tab.csv').importer_key
  end
end
