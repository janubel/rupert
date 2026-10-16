# frozen_string_literal: true

require 'test_helper'

class SyncQueueHealthTest < ActiveSupport::TestCase
  test 'queue receipts expose scheduling metadata without reading arguments or failed error payloads' do
    job = mock
    SolidQueue::Job.expects(:find_by).with(active_job_id: 'synthetic-job').returns(job)
    job.expects(:failed_execution).returns(nil)
    execution = Struct.new(:scheduled_at).new(5.minutes.from_now)
    job.expects(:scheduled_execution).twice.returns(execution)
    result = SyncQueueHealth.execution(Struct.new(:active_job_id).new('synthetic-job'))
    assert_equal 'Scheduled', result[:state]
    assert_equal execution.scheduled_at, result[:retry_at]
  end

  test 'unavailable queue is unknown rather than a zero or healthy worker count' do
    SolidQueue::Job.expects(:find_by).raises(ActiveRecord::StatementInvalid.new('private queue error'))
    result = SyncQueueHealth.execution(Struct.new(:active_job_id).new('synthetic-job'))
    assert_equal 'Unknown · queue database unavailable', result[:state]
    assert_nil result[:retry_at]
    refute_includes result.to_json, 'private queue error'
  end

  test 'heartbeat timestamps are local evidence and never expose process hostnames' do
    ActiveJob::Base.stubs(:queue_adapter).returns(ActiveJob::QueueAdapters::SolidQueueAdapter.new)
    query = mock
    SolidQueue::Process.expects(:where).with(kind: 'Worker').twice.returns(query)
    query.expects(:maximum).with(:last_heartbeat_at).twice.returns(1.minute.ago, 5.minutes.ago)
    assert_equal 'Recent worker heartbeat', SyncQueueHealth.worker[:state]
    assert_equal 'No recent worker heartbeat', SyncQueueHealth.worker[:state]
  end
end
