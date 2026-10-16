# frozen_string_literal: true

require 'test_helper'

class SwipesimpleReportsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    post login_path, params: { email: @admin.email, password: 'password' }
    @context = { kind: 'transactions', merchant_account: 'Example Wholesale', currency: 'USD',
      source_timezone: 'America/New_York', exported_at: '2026-10-15T22:00:00-04:00' }
    travel_to Time.iso8601('2026-10-16T03:00:00Z')
  end

  teardown do
    travel_back
    Current.reset
  end

  test 'reviewed native upload stores private evidence and reports source totals' do
    assert_no_difference ['SwipesimpleExport.unscoped.count', 'Core::Order.unscoped.count'] do
      post preview_swipesimple_reports_path, params: upload
    end
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    refute_includes response.body, 'Fictional Customer'
    token = Nokogiri::HTML(response.body).at_css('input[name=preview_token]')['value']
    post swipesimple_reports_path, params: upload.merge(preview_token: token)
    assert_redirected_to swipesimple_reports_path
    Current.tenant = @tenant
    receipt = SwipesimpleExport.last
    assert_equal 13, receipt.report_rows.count
    get swipesimple_reports_path(day: '2026-10-14')
    assert_response :success
    assert_includes response.body, 'Daily cash / card / tip totals'
    get document_swipesimple_report_path(receipt)
    assert_response :success
    assert_equal File.read(csv_path), response.body
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  test 'missing expired changed and foreign-user previews cannot authorize imports' do
    post swipesimple_reports_path, params: upload
    assert_redirected_to swipesimple_reports_path
    post preview_swipesimple_reports_path, params: upload
    token = Nokogiri::HTML(response.body).at_css('input[name=preview_token]')['value']
    assert_no_difference 'SwipesimpleExport.unscoped.count' do
      post swipesimple_reports_path, params: upload.merge(preview_token: token, swipesimple_export: @context.merge(currency: 'CAD'))
      travel 16.minutes do
        post swipesimple_reports_path, params: upload.merge(preview_token: token)
      end
      other = User.create!(email: 'other-native@example.invalid', password: 'password123', role: 'admin', tenant: @tenant)
      delete logout_path
      post login_path, params: { email: other.email, password: 'password123' }
      post swipesimple_reports_path, params: upload.merge(preview_token: token)
    end
  end

  test 'raw documents are tenant-scoped and readers cannot import or download them' do
    Current.tenant = @tenant
    prepared = SwipesimpleReportImporter.preview(File.read(csv_path), @context)
    receipt = SwipesimpleReportImporter.import!(File.read(csv_path), @context, expected_fingerprint: prepared.fingerprint)
    reader = User.create!(email: 'reader-native@example.invalid', password: 'password123', role: 'reader', tenant: @tenant)
    delete logout_path
    post login_path, params: { email: reader.email, password: 'password123' }
    get swipesimple_reports_path
    assert_response :success
    assert_select 'input[type=file]', count: 0
    get document_swipesimple_report_path(receipt)
    assert_response :redirect
    post preview_swipesimple_reports_path, params: upload
    assert_response :redirect
    other = Tenant.create!(name: 'Foreign source', subdomain: 'foreign-source')
    foreign = User.create!(email: 'foreign-native@example.invalid', password: 'password123', role: 'admin', tenant: other)
    delete logout_path
    post login_path, params: { email: foreign.email, password: 'password123' }
    get document_swipesimple_report_path(receipt)
    assert_response :not_found
  end

  test 'source documents context and sensitive row fields are filtered from request parameters' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter('file' => 'private.csv', 'swipesimple_export' => @context, 'original_csv' => 'PRIVATE', 'source_number' => 'PRIVATE')
    assert filtered.values.all? { |value| value == '[FILTERED]' }
  end

  private

  def csv_path
    Rails.root.join('test/fixtures/files/swipesimple_transactions.csv')
  end

  def upload
    { file: Rack::Test::UploadedFile.new(csv_path, 'text/csv'), swipesimple_export: @context }
  end
end
