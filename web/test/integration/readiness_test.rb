# frozen_string_literal: true

require 'test_helper'

class ReadinessTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    SyncRun.unscoped.delete_all
    SolidQueue::Process.delete_all
  end

  teardown { Current.reset }

  test '/up stays a plain database liveness check' do
    get '/up'
    assert_response :success
    assert_equal 'OK', response.body
  end

  test '/up/ready is not ready without a worker heartbeat and says which checks failed, nothing more' do
    SyncRun.create!(mode: 'scheduled', status: 'success', source: 'all', startedAt: 5.minutes.ago, finishedAt: 4.minutes.ago)
    get '/up/ready'
    assert_response :service_unavailable
    body = response.parsed_body
    assert_equal 'not_ready', body['status']
    assert_equal 'ok', body.dig('checks', 'database')
    assert_equal 'missing', body.dig('checks', 'worker')
    assert_equal 'ok', body.dig('checks', 'last_sync')
    assert_equal %w[database disk last_sync worker], body['checks'].keys.sort
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  test '/up/ready is ready with a fresh worker heartbeat, a recent sync and free disk' do
    SolidQueue::Process.create!(kind: 'Worker', last_heartbeat_at: 30.seconds.ago, pid: 1, hostname: 'test', name: 'worker-test')
    SyncRun.create!(mode: 'scheduled', status: 'success', source: 'all', startedAt: 5.minutes.ago, finishedAt: 4.minutes.ago)
    ReadinessCheck.stubs(:free_megabytes).returns(ReadinessCheck::MIN_FREE_DISK_MB + 1)
    get '/up/ready'
    assert_response :success
    assert_equal 'ready', response.parsed_body['status']
  end

  test 'a stale sync or low disk makes the instance not ready' do
    SolidQueue::Process.create!(kind: 'Worker', last_heartbeat_at: 30.seconds.ago, pid: 1, hostname: 'test', name: 'worker-test')
    SyncRun.create!(mode: 'scheduled', status: 'success', source: 'all', startedAt: 2.hours.ago, finishedAt: 2.hours.ago)
    ReadinessCheck.stubs(:free_megabytes).returns(10)
    get '/up/ready'
    assert_response :service_unavailable
    assert_equal 'stale', response.parsed_body.dig('checks', 'last_sync')
    assert_equal 'low', response.parsed_body.dig('checks', 'disk')
  end

  test 'a fresh install with no sync yet is unconfigured rather than failing' do
    SolidQueue::Process.create!(kind: 'Worker', last_heartbeat_at: 30.seconds.ago, pid: 1, hostname: 'test', name: 'worker-test')
    ReadinessCheck.stubs(:free_megabytes).returns(ReadinessCheck::MIN_FREE_DISK_MB + 1)
    get '/up/ready'
    assert_response :success
    assert_equal 'unconfigured', response.parsed_body.dig('checks', 'last_sync')
  end
end
