# frozen_string_literal: true

require 'test_helper'

class BuildVersionTest < ActionDispatch::IntegrationTest
  setup { BuildInfo.stubs(:current).returns(BuildInfo.new(revision: 'd' * 40)) }

  test 'signed-out pages always identify their build visibly and over HTTP' do
    get login_path
    assert_response :success
    assert_equal 'd' * 40, response.headers['X-Rupert-Build']
    assert_select '[aria-label="Rupert build version"][data-build-version=?]', 'd' * 40, count: 1
    assert_includes response.body, "Build #{'d' * 12}"
  end

  test 'health and redirect responses include build identity without needing a layout' do
    get '/up'
    assert_response :success
    assert_equal 'd' * 40, response.headers['X-Rupert-Build']
    get books_desk_path
    assert_response :redirect
    assert_equal 'd' * 40, response.headers['X-Rupert-Build']
  end

  test 'header shows scoped nightly and cumulative totals with disclosure and notes' do
    totals = {
      'schema_version' => 1, 'revision' => 'd' * 40, 'version' => '0.2.0', 'as_of' => '2026-10-21T12:00:00Z',
      'base_revision' => 'b' * 40, 'source_lines' => 120_000,
      'nightly' => { 'patch_commits' => 42, 'lines_added' => 1000, 'lines_deleted' => 200, 'confirmed_bugs_fixed' => 4 },
      'cumulative' => { 'patch_commits' => 500, 'lines_added' => 130_000, 'lines_deleted' => 10_000 }
    }
    BuildInfo.stubs(:current).returns(BuildInfo.new(revision: 'd' * 40, release_totals: totals))
    get login_path
    assert_response :success
    assert_select 'header details[data-build-totals] summary', text: /42 patches · 4 confirmed fixes · \+1,000 \/ −200 lines/
    assert_select 'header details dl', text: /500 patch commits/
    assert_select 'header details dl', text: /120,000 lines/
    assert_select 'header a[href="https://github.com/techmore/rupert/releases"]', text: 'Release notes'
    refute_includes response.body, 'data-build-totals-unavailable'
  end

  test 'health check reports OK when the database answers and 503 when it does not' do
    get '/up'
    assert_response :success
    assert_equal 'OK', response.body
    assert_equal 'no-store', response.headers['cache-control']

    HealthCheck.stubs(:database_reachable!).raises(ActiveRecord::ConnectionNotEstablished)
    get '/up'
    assert_response :service_unavailable
    assert_equal 'DATABASE UNAVAILABLE', response.body
  end
end
