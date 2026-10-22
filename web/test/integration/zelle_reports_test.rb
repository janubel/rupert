# frozen_string_literal: true

require 'test_helper'

class ZelleReportsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    post login_path, params: { email: @admin.email, password: 'password' }
    @context = { account_label: 'Business checking 1234', currency: 'USD', exported_at: '2026-10-15T22:00:00-04:00' }
    travel_to Time.iso8601('2026-10-16T03:00:00Z')
  end

  teardown do
    travel_back
    Current.reset
  end

  test 'reviewed upload stores private evidence and reports unverified Zelle totals' do
    assert_no_difference ['ZelleExport.unscoped.count', 'Core::Order.unscoped.count', 'SwipesimpleExport.unscoped.count'] do
      post preview_zelle_reports_path, params: upload
    end
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal 'nosniff', response.headers['X-Content-Type-Options']
    refute_includes response.body, 'Fictional Customer'
    refute_includes response.body, 'ZTEST'
    assert_includes response.body, 'Validated 4 rows'
    token = Nokogiri::HTML(response.body).at_css('input[name=preview_token]')['value']
    assert_difference 'ZelleExport.unscoped.count', 1 do
      post zelle_reports_path, params: upload.merge(preview_token: token)
    end
    assert_redirected_to zelle_reports_path
    Current.tenant = @tenant
    receipt = ZelleExport.last
    assert_equal 4, receipt.entries.count
    assert_equal @admin.id, receipt.imported_by_id

    get zelle_reports_path(day: '2026-10-14')
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_includes response.body, 'Daily Zelle totals (unverified)'
    assert_includes response.body, 'Zelle · unverified'
    assert_includes response.body, '1,200.50'
    assert_includes response.body, 'Fictional Customer A'

    get document_zelle_report_path(receipt)
    assert_response :success
    assert_equal File.read(csv_path), response.body
    assert_equal 'no-store', response.headers['Cache-Control']

    post zelle_reports_path, params: upload.merge(preview_token: token)
    assert_equal 1, ZelleExport.count, 'replaying the same reviewed file adds nothing'
  end

  test 'Zelle stays out of SwipeSimple reports' do
    Current.tenant = @tenant
    csv = File.read(csv_path)
    prepared = ZelleReportImporter.preview(csv, @context)
    ZelleReportImporter.import!(csv, @context, expected_fingerprint: prepared.fingerprint)
    get swipesimple_reports_path(day: '2026-10-14')
    assert_response :success
    refute_includes response.body, 'Fictional Customer A'
    assert_includes response.body, 'No imported transaction evidence for this day'
  end

  test 'both report pages share a payment sources tab strip with the current page marked' do
    get zelle_reports_path
    assert_response :success
    nav = Nokogiri::HTML(response.body).at_css('nav[aria-label="Payment sources"]')
    assert_equal %w[SwipeSimple Zelle], nav.css('a').map { |link| link.text.strip }
    assert_equal ['Zelle'], nav.css('a[aria-current=page]').map { |link| link.text.strip }
    assert_equal swipesimple_reports_path, nav.at_css('a')['href']
    get swipesimple_reports_path
    nav = Nokogiri::HTML(response.body).at_css('nav[aria-label="Payment sources"]')
    assert_equal ['SwipeSimple'], nav.css('a[aria-current=page]').map { |link| link.text.strip }
    assert_equal zelle_reports_path, nav.css('a').last['href']
  end

  test 'missing expired changed and foreign-user previews cannot authorize imports' do
    post zelle_reports_path, params: upload
    assert_redirected_to zelle_reports_path
    post preview_zelle_reports_path, params: upload
    token = Nokogiri::HTML(response.body).at_css('input[name=preview_token]')['value']
    assert_no_difference 'ZelleExport.unscoped.count' do
      post zelle_reports_path, params: upload.merge(preview_token: token, zelle_export: @context.merge(account_label: 'Other'))
      travel 16.minutes do
        post zelle_reports_path, params: upload.merge(preview_token: token)
      end
      other = User.create!(email: 'other-zelle@example.invalid', password: 'password123', role: 'admin', tenant: @tenant)
      delete logout_path
      post login_path, params: { email: other.email, password: 'password123' }
      post zelle_reports_path, params: upload.merge(preview_token: token)
      # a token signed for another feature's purpose is not accepted either
      forged = Rails.application.message_verifier('swipesimple-native-preview').generate(
        { 'tenant_id' => @tenant.id, 'user_id' => other.id, 'fingerprint' => 'x' }, purpose: 'zelle-bank-csv-v1')
      post zelle_reports_path, params: upload.merge(preview_token: forged)
    end
  end

  test 'invalid files are rejected whole with a fixed message and nothing saved' do
    bad = Rack::Test::UploadedFile.new(StringIO.new("Date,Amount\n2026-10-14,5.00\n"), 'text/csv', original_filename: 'bad.csv')
    assert_no_difference 'ZelleExport.unscoped.count' do
      post preview_zelle_reports_path, params: { file: bad, zelle_export: @context }
    end
    assert_redirected_to zelle_reports_path
    follow_redirect!
    assert_includes response.body, 'Unsupported CSV headers'
    post preview_zelle_reports_path, params: { zelle_export: @context }
    assert_redirected_to zelle_reports_path
  end

  test 'readers can view but not import or download and other tenants cannot read documents' do
    Current.tenant = @tenant
    csv = File.read(csv_path)
    prepared = ZelleReportImporter.preview(csv, @context)
    receipt = ZelleReportImporter.import!(csv, @context, expected_fingerprint: prepared.fingerprint)
    reader = User.create!(email: 'reader-zelle@example.invalid', password: 'password123', role: 'reader', tenant: @tenant)
    delete logout_path
    post login_path, params: { email: reader.email, password: 'password123' }
    get zelle_reports_path
    assert_response :success
    assert_select 'input[type=file]', count: 0
    assert_select 'a', text: 'Download original CSV', count: 0
    get document_zelle_report_path(receipt)
    assert_response :redirect
    assert_no_difference 'ZelleExport.unscoped.count' do
      post preview_zelle_reports_path, params: upload
      assert_response :redirect
      post zelle_reports_path, params: upload.merge(preview_token: 'x')
      assert_response :redirect
    end
    other = Tenant.create!(name: 'Foreign zelle', subdomain: 'foreign-zelle-ui')
    foreign = User.create!(email: 'foreign-zelle@example.invalid', password: 'password123', role: 'admin', tenant: other)
    delete logout_path
    post login_path, params: { email: foreign.email, password: 'password123' }
    get document_zelle_report_path(receipt)
    assert_response :not_found
    get zelle_reports_path(day: '2026-10-14')
    refute_includes response.body, 'Fictional Customer A'
  end

  test 'users without reports access are turned away and logged out visitors must sign in' do
    delete logout_path
    get zelle_reports_path
    assert_response :redirect
    refute_equal zelle_reports_path, URI(response.location).path
  end

  test 'invalid day redirects with guidance' do
    get zelle_reports_path(day: 'bogus')
    assert_redirected_to zelle_reports_path
  end

  test 'sync page links to the Zelle import for sync writers' do
    get syncs_path
    assert_response :success
    assert_select "a[href='#{zelle_reports_path(anchor: 'import')}']"
  end

  test 'source documents context and sensitive row fields are filtered from request parameters' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter('file' => 'private.csv', 'zelle_export' => @context, 'original_csv' => 'PRIVATE',
      'counterparty' => 'PRIVATE', 'memo' => 'PRIVATE', 'bank_reference' => 'PRIVATE')
    assert filtered.values.all? { |value| value == '[FILTERED]' }
  end

  private

  def csv_path
    Rails.root.join('test/fixtures/files/zelle_bank.csv')
  end

  def upload
    { file: Rack::Test::UploadedFile.new(csv_path, 'text/csv'), zelle_export: @context }
  end
end
