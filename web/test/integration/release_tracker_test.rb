# frozen_string_literal: true

require 'test_helper'

class ReleaseTrackerTest < ActionDispatch::IntegrationTest
  API = 'https://api.github.com/repos/techmore/rupert'

  setup do
    Current.tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    stub_request(:get, %r{#{API}/milestones}).to_return(status: 200, headers: { 'Content-Type' => 'application/json' }, body: [
      { title: 'Rupert deployment ready', number: 1, open_issues: 5, closed_issues: 2, html_url: 'https://github.com/x/1' },
      { title: 'v0.2.1', number: 2, open_issues: 3, closed_issues: 1, html_url: 'https://github.com/x/2' }
    ].to_json)
    @issues = stub_request(:get, %r{#{API}/issues\?.*milestone=2}).to_return(status: 200, body: [
      { number: 423, title: 'Payroll: define owner-approved pay rules', html_url: 'https://github.com/x/423', labels: [{ name: 'area:payroll' }, { name: 'v0.2.1-gate' }] },
      { number: 426, title: 'UI: apply shared navigation', html_url: 'https://github.com/x/426', labels: [{ name: 'area:ui-finance' }, { name: 'bug' }] },
      { number: 999, title: 'A pull request', html_url: 'https://github.com/x/999', labels: [], pull_request: {} },
      { number: 470, title: 'Something without an area', html_url: 'https://github.com/x/470', labels: [] }
    ].to_json)
  end

  teardown do
    EnvStore.platform_set('GITHUB_ISSUES_MILESTONE', nil)
    Rails.cache = @previous_cache
    Current.reset
  end

  test 'reads the newest v milestone without a token, grouped by area, pull requests left out' do
    tracker = GithubIssues.release_tracker
    assert_equal 'v0.2.1', tracker.title
    assert_equal [3, 1, 25], [tracker.open_count, tracker.closed_count, tracker.percent_done]
    assert_equal [['Payroll', [423]], ['UI / Finance', [426]], ['Other', [470]]], tracker.by_area.map { |area, rows| [area, rows.pluck(:number)] }
    assert_equal ['bug'], tracker.issues.find { |issue| issue[:number] == 426 }[:labels]
    assert_not_requested :get, %r{#{API}/issues\?.*milestone=1}
    GithubIssues.release_tracker
    assert_requested @issues, times: 1
  end

  test 'a named milestone setting wins, and an unreadable GitHub gives nil' do
    EnvStore.platform_set('GITHUB_ISSUES_MILESTONE', 'Rupert deployment ready')
    stub_request(:get, %r{#{API}/issues\?.*milestone=1}).to_return(status: 200, body: '[]')
    assert_equal 'Rupert deployment ready', GithubIssues.release_tracker.title
    Rails.cache.clear
    stub_request(:get, %r{#{API}/milestones}).to_return(status: 503)
    assert_nil GithubIssues.release_tracker
  end

  test 'admins see the page and a cached count in the header; staff see neither' do
    post login_path, params: { email: @admin.email, password: 'password' }
    get release_tracker_path
    assert_response :success
    assert_select 'h1', 'v0.2.1 release blockers'
    assert_select 'h2', text: 'Payroll'
    assert_select 'a[href=?]', 'https://github.com/x/426'
    assert_select "a[href='#{release_tracker_path}'][data-release-open='3']"
    delete logout_path

    cashier = User.create!(tenant: Current.tenant, email: 'release-cashier@example.com', role: 'cashier', password: 'password123')
    post login_path, params: { email: cashier.email, password: 'password123' }
    get release_tracker_path
    assert_includes [302, 303, 403], response.status
    get sales_path
    assert_select "a[href='#{release_tracker_path}']", count: 0
  end
end
