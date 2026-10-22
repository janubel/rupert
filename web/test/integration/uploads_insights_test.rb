# frozen_string_literal: true

require 'test_helper'

class UploadsInsightsPageTest < ActionDispatch::IntegrationTest
  include UploadFixtures

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    @reader = User.create!(tenant: @tenant, email: 'reader-insights@example.com', role: 'reader', password: 'password', name: 'Reader')
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end

  teardown { Current.reset }

  test 'an empty workspace gets a plain explanation, not empty charts' do
    get insights_uploads_path
    assert_response :success
    assert_select '[role=status]', text: /nothing to chart yet/
    assert_select 'svg.upload-chart', count: 0
  end

  test 'the page draws the volume chart with a legend, a table and one description per column' do
    Current.user = @admin
    [[BANK_CSV, 'a.csv'], [UNKNOWN_CSV, 'b.csv'], ['MZ', 'c.exe']].each do |content, name|
      Uploads::Intake.call(StringIO.new(content), filename: name, origin: 'web', actor: @admin)
    end
    get insights_uploads_path
    assert_response :success
    assert_select 'svg.upload-chart g.upload-col', 30
    assert_select 'svg.upload-chart g.upload-col[aria-label*="3 uploads"]'
    assert_select 'ul.upload-legend li', 5
    assert_select 'details table caption', text: /Uploads by outcome per day/
    assert_select '#funnel-title'
    assert_select '#reasons-title'
    assert_match(/Not recognized/, response.body)
    assert_select 'a[href=?]', insights_uploads_path(days: 90)
    page_text = css_select('#main').text
    assert_no_match(/a\.csv|b\.csv|c\.exe|UPS STORE/, page_text)
  end

  test 'a long range groups by week and a bad range falls back to thirty days' do
    Uploads::Intake.call(StringIO.new(BANK_CSV), filename: 'a.csv', origin: 'web', actor: @admin)
    get insights_uploads_path(days: 365)
    assert_select 'svg.upload-chart g.upload-col', 53
    assert_select 'caption', text: /per week/
    get insights_uploads_path(days: 'abc')
    assert_select 'svg.upload-chart g.upload-col', 30
  end

  test 'it needs uploads.read, and the Uploads list links to it' do
    get uploads_path
    assert_select 'a[href=?]', insights_uploads_path, text: 'Insights'
    delete logout_path
    post login_path, params: { email: 'reader-insights@example.com', password: 'password' }
    get insights_uploads_path
    assert_redirected_to root_path
  end
end
