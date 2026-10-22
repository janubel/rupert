# frozen_string_literal: true

require 'test_helper'

class OpsEventTest < ActiveSupport::TestCase
  setup { OpsEvent.delete_all }

  def record(**overrides)
    OpsEvent.record!(**{ kind: 'request', category: 'server_error', level: 'error', summary: 'POST /x 500', fingerprint: 'fp1', tenant_id: 't', user_id: 1,
                         request_id: 'r1', data: { a: 1 } }.merge(overrides))
  end

  test 'a repeat within the window is counted on one row and keeps the worst level' do
    record(level: 'warn')
    record(request_id: 'r2')
    row = OpsEvent.sole
    assert_equal 2, row.occurrences
    assert_equal 'error', row.level
    assert_equal 'r2', row.request_id
  end

  test 'a repeat after the window starts a new row' do
    record
    OpsEvent.update_all(last_seen_at: 1.hour.ago)
    record
    assert_equal 2, OpsEvent.count
  end

  test 'old rows and rows beyond the cap are pruned' do
    record(fingerprint: 'old')
    OpsEvent.update_all(last_seen_at: 30.days.ago)
    record(fingerprint: 'new')
    OpsEvent.prune!
    assert_equal ['new'], OpsEvent.pluck(:fingerprint)
    stub_const = OpsLog::Activity::MAX_ROWS
    OpsLog::Activity.send(:remove_const, :MAX_ROWS)
    OpsLog::Activity.const_set(:MAX_ROWS, 1)
    record(fingerprint: 'newer')
    OpsEvent.prune!
    assert_equal ['newer'], OpsEvent.pluck(:fingerprint)
  ensure
    OpsLog::Activity.send(:remove_const, :MAX_ROWS)
    OpsLog::Activity.const_set(:MAX_ROWS, stub_const)
  end

  test 'a failed write never raises into the caller' do
    OpsEvent.stubs(:create!).raises(ActiveRecord::StatementInvalid)
    assert_nil record
  end

  test 'categories and summaries come from names and codes only' do
    fields = { method: 'POST', route: '/orders', status: 500, controller: 'orders', action: 'create', error_class: 'Boom' }
    assert_equal 'server_error', OpsLog::Activity.category('request', fields)
    assert_equal 'slow_request', OpsLog::Activity.category('request', fields.merge(status: 200, slow: true))
    assert_equal 'rejected_form', OpsLog::Activity.category('validation_failed', {})
    assert_equal 'POST /orders 500 (orders#create) Boom', OpsLog::Activity.summary('request', fields)
    assert_equal 'cashier refused ModulePolicy inventory_write? (locations#create)',
      OpsLog::Activity.summary('permission_denied', role: 'cashier', policy: 'ModulePolicy', query: 'inventory_write?', controller: 'locations', action: 'create')
  end

  test 'turning the store off with RUPERT_OPS_EVENTS=0 writes nothing' do
    ENV['RUPERT_OPS_EVENTS'] = '0'
    OpsLog.event('request', level: :error, status: 500)
    assert_equal 0, OpsEvent.count
  ensure
    ENV.delete('RUPERT_OPS_EVENTS')
  end

  test 'the snapshot counts by category and calls a recent server error urgent' do
    OpsLog.event('request', level: :error, status: 500, controller: 'a', action: 'b')
    OpsLog.event('permission_denied', level: :warn, controller: 'c', action: 'd')
    snapshot = OpsActivitySnapshot.build
    assert_equal 'error', snapshot[:state]
    assert_equal 1, snapshot[:counts]['server_error']
    assert_equal 1, snapshot[:counts]['permission_denied']
    assert_equal 2, snapshot[:recent].size
    OpsEvent.update_all(last_seen_at: 3.hours.ago)
    assert_equal 'warning', OpsActivitySnapshot.build[:state]
    OpsEvent.update_all(last_seen_at: 3.days.ago)
    assert_equal 'ok', OpsActivitySnapshot.build[:state]
  end
end
